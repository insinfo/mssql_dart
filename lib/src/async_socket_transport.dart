import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'tds_base.dart' as tds;
import 'transport_tls.dart';

/// TCP transport over a [RawSocket] that the driver controls directly.
///
/// With [Socket], `SecureSocket.secure` takes over the original socket, and a
/// server that never answers the handshake leaves the connection open with no
/// way for `close()` to release it; write errors also arrive through the
/// socket's `done` future and become unhandled errors when nobody listens to
/// it. Here the driver keeps the handle of the [RawSocket] (or of the
/// [RawSecureSocket] after the upgrade), reads only while the internal buffer
/// is below [_highWater], and [destroy] closes the connection at any point,
/// failing pending reads and writes.
class AsyncSocketTransport
    implements tds.AsyncTransportProtocol, AsyncTlsTransport {
  AsyncSocketTransport._(
    this._raw, {
    required this.description,
    String? host,
    int? port,
    bool isSecure = false,
  })  : _host = host,
        _port = port,
        _secure = isSecure {
    _attach();
  }

  /// Opens the TCP connection. [timeout] bounds only the connect. A non-zero
  /// [keepAlive] enables TCP keepalive (see [enableKeepAlive]).
  static Future<AsyncSocketTransport> connect(
    String host,
    int port, {
    Duration? timeout,
    String? description,
    Duration keepAlive = Duration.zero,
  }) async {
    try {
      final raw = await RawSocket.connect(host, port, timeout: timeout);
      if (keepAlive > Duration.zero) enableKeepAlive(raw, keepAlive);
      return AsyncSocketTransport._(
        raw,
        description: description ?? '$host:$port',
        host: host,
        port: port,
      );
    } on SocketException catch (err) {
      throw tds.OperationalException(
          'Failed to connect to $host:$port: ${err.message}');
    }
  }

  /// Enables SO_KEEPALIVE on [socket] and, where the options are known, sets
  /// the idle time before the first probe to [idle], the interval between
  /// probes to [interval], and the number of unanswered probes before the
  /// connection is considered dead to [probes].
  ///
  /// The `setsockopt` constants vary by OS: fine-tuning applies on Linux,
  /// Android, macOS, iOS and Windows 10 1709+ (older Windows versions enable
  /// SO_KEEPALIVE with the system timings, usually 2 h); on other systems
  /// nothing is changed. Returns `false` if SO_KEEPALIVE could not be
  /// enabled. Never throws.
  static bool enableKeepAlive(
    RawSocket socket,
    Duration idle, {
    Duration interval = const Duration(seconds: 10),
    int probes = 3,
  }) {
    final options = _KeepAliveOptions.current;
    if (options == null) return false;
    try {
      socket.setRawOption(RawSocketOption.fromBool(
          RawSocketOption.levelSocket, options.soKeepAlive, true));
    } catch (_) {
      return false;
    }
    void trySet(int option, int value) {
      try {
        socket.setRawOption(
            RawSocketOption.fromInt(RawSocketOption.levelTcp, option, value));
      } catch (_) {
        // Option missing in this OS version; the default applies.
      }
    }

    int seconds(Duration d) => d.inSeconds < 1 ? 1 : d.inSeconds;
    trySet(options.tcpKeepIdle, seconds(idle));
    trySet(options.tcpKeepInterval, seconds(interval));
    trySet(options.tcpKeepCount, probes);
    return true;
  }

  /// Number of read-but-unconsumed bytes above which socket reads are
  /// suspended until the consumer catches up (backpressure).
  static const int _highWater = 1 << 20;

  final String description;
  RawSocket _raw;
  final String? _host;
  final int? _port;
  bool _secure;
  Duration? _timeout;
  late StreamSubscription<RawSocketEvent> _subscription;

  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _chunkOffset = 0;
  int _available = 0;
  Completer<void>? _readWaiter;

  final Queue<Uint8List> _writes = Queue<Uint8List>();
  int _writeOffset = 0;
  final List<Completer<void>> _flushWaiters = [];

  bool _eof = false;
  bool _closed = false;
  Object? _error;
  StackTrace? _errorStack;

  /// Underlying socket ([RawSecureSocket] after [upgradeToSecureSocket]).
  RawSocket get rawSocket => _raw;

  @override
  bool get isConnected => !_closed && !_eof && _error == null;

  /// Maximum wait for data on each read; `null` waits indefinitely.
  @override
  Duration? get timeout => _timeout;

  @override
  set timeout(Duration? value) => _timeout = value;

  @override
  bool get isSecure => _secure;
  @override
  String? get remoteHost => _host;
  String? get host => _host;
  int? get port => _port;

  void _attach() {
    _raw.setOption(SocketOption.tcpNoDelay, true);
    _raw.writeEventsEnabled = _writes.isNotEmpty;
    _raw.readEventsEnabled = _available < _highWater;
    _subscription = _raw.listen(_onEvent, onError: _onError, onDone: _onDone);
  }

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        _readAvailable();
      case RawSocketEvent.write:
        _writePending();
      case RawSocketEvent.readClosed:
        // Data sent before the FIN arrives first.
        _readAvailable();
        _eof = true;
        _wakeReader();
      case RawSocketEvent.closed:
        _eof = true;
        _wakeReader();
        _failWrites(tds.ClosedConnectionException(), StackTrace.current);
    }
  }

  void _readAvailable() {
    while (_raw.available() > 0) {
      final data = _raw.read();
      if (data == null || data.isEmpty) break;
      _chunks.addLast(data);
      _available += data.length;
    }
    if (_available >= _highWater) {
      _raw.readEventsEnabled = false;
    }
    _wakeReader();
  }

  void _onError(Object error, StackTrace stackTrace) {
    _error ??= error;
    _errorStack ??= stackTrace;
    _wakeReader();
    _failWrites(error, stackTrace);
  }

  void _onDone() {
    _eof = true;
    _wakeReader();
    _failWrites(tds.ClosedConnectionException(), StackTrace.current);
  }

  void _wakeReader() {
    final waiter = _readWaiter;
    _readWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// Waits for more data, EOF, an error, or close.
  Future<void> _waitForData() {
    final waiter = _readWaiter = Completer<void>();
    final timeout = _timeout;
    if (timeout == null) return waiter.future;
    return waiter.future.timeout(timeout, onTimeout: () {
      if (identical(_readWaiter, waiter)) _readWaiter = null;
      throw tds.TimeoutError(
          'No data received from $description within $timeout');
    });
  }

  Never _throwReadFailure() {
    final error = _error;
    if (error != null)
      Error.throwWithStackTrace(error, _errorStack ?? StackTrace.current);
    throw tds.ClosedConnectionException();
  }

  bool get _canReceiveMore => !_eof && !_closed && _error == null;

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) {
    if (_closed || _error != null) {
      return Future.error(
          _error ?? tds.ClosedConnectionException(), _errorStack);
    }
    if (data.isEmpty) return Future.value();
    _writes.addLast(data is Uint8List ? data : Uint8List.fromList(data));
    _writePending();
    if (_writes.isEmpty) {
      final error = _error;
      return error == null ? Future.value() : Future.error(error, _errorStack);
    }
    final waiter = Completer<void>();
    _flushWaiters.add(waiter);
    return waiter.future;
  }

  void _writePending() {
    if (_closed) return;
    try {
      while (_writes.isNotEmpty) {
        final chunk = _writes.first;
        _writeOffset += _raw.write(chunk, _writeOffset);
        if (_writeOffset < chunk.length) {
          // Kernel buffer full; the next write event resumes from here.
          _raw.writeEventsEnabled = true;
          return;
        }
        _writes.removeFirst();
        _writeOffset = 0;
      }
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
      return;
    }
    final waiters = List.of(_flushWaiters);
    _flushWaiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
  }

  void _failWrites(Object error, StackTrace stackTrace) {
    _writes.clear();
    _writeOffset = 0;
    final waiters = List.of(_flushWaiters);
    _flushWaiters.clear();
    for (final waiter in waiters) {
      waiter.completeError(error, stackTrace);
    }
  }

  @override
  Future<Uint8List> recv(int size) async {
    if (size <= 0) return Uint8List(0);
    while (_available < size && _canReceiveMore) {
      await _waitForData();
    }
    if (_available == 0) _throwReadFailure();
    return _consume(size < _available ? size : _available);
  }

  @override
  Future<Uint8List> recvAvailable(int maxSize) async {
    if (maxSize <= 0) return Uint8List(0);
    while (_available == 0 && _canReceiveMore) {
      await _waitForData();
    }
    if (_available == 0) _throwReadFailure();
    return _consume(maxSize < _available ? maxSize : _available);
  }

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) async {
    final target = buffer.asUint8List();
    final desired = size <= 0 || size > target.length ? target.length : size;
    if (desired == 0) return 0;
    final bytes = await recv(desired);
    target.setRange(0, bytes.length, bytes);
    return bytes.length;
  }

  Uint8List _consume(int size) {
    final first = _chunks.first;
    Uint8List out;
    if (first.length - _chunkOffset >= size) {
      // Common case: the request fits in the first chunk, no copy.
      out = Uint8List.sublistView(first, _chunkOffset, _chunkOffset + size);
      _chunkOffset += size;
      if (_chunkOffset == first.length) {
        _chunks.removeFirst();
        _chunkOffset = 0;
      }
    } else {
      out = Uint8List(size);
      var written = 0;
      while (written < size) {
        final chunk = _chunks.first;
        final take = chunk.length - _chunkOffset < size - written
            ? chunk.length - _chunkOffset
            : size - written;
        out.setRange(written, written + take, chunk, _chunkOffset);
        written += take;
        _chunkOffset += take;
        if (_chunkOffset == chunk.length) {
          _chunks.removeFirst();
          _chunkOffset = 0;
        }
      }
    }
    final wasAboveHighWater = _available >= _highWater;
    _available -= size;
    if (wasAboveHighWater && _available < _highWater && _canReceiveMore) {
      _raw.readEventsEnabled = true;
    }
    return out;
  }

  /// Closes the connection immediately, without waiting for pending writes.
  ///
  /// Can be called at any time, including during a TLS handshake or to abort
  /// a connection that exceeded its deadline; pending reads and writes fail
  /// with [tds.ClosedConnectionException].
  void destroy() {
    if (_closed) return;
    _closed = true;
    _chunks.clear();
    _chunkOffset = 0;
    _available = 0;
    unawaited(_subscription.cancel());
    unawaited(_raw.close().then<void>((_) {}, onError: (Object _) {}));
    _wakeReader();
    _failWrites(tds.ClosedConnectionException(), StackTrace.current);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_writes.isNotEmpty && _error == null) {
      final waiter = Completer<void>();
      _flushWaiters.add(waiter);
      try {
        await waiter.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        // The connection is closed regardless.
      }
    }
    destroy();
  }

  /// Performs the TLS handshake directly over TCP (TLS-first).
  ///
  /// Not suitable for TDS 7.x, whose handshake travels inside PRELOGIN
  /// packets; see `tls_channel.dart`.
  @override
  Future<void> upgradeToSecureSocket({
    required SecurityContext context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    String? host,
    bool loginOnly = false,
    List<String>? alpnProtocols,
  }) async {
    if (_secure) return;
    if (_closed) throw tds.ClosedConnectionException();
    if (_writes.isNotEmpty || _available > 0) {
      throw StateError('The socket has pending data before the TLS upgrade');
    }
    final RawSecureSocket secure;
    try {
      // Passing the subscription hands the events to the handshake; the driver
      // keeps the _raw handle and destroy() aborts a stalled handshake.
      secure = await RawSecureSocket.secure(
        _raw,
        subscription: _subscription,
        host: host ?? _host,
        context: context,
        onBadCertificate: onBadCertificate,
        supportedProtocols: alpnProtocols,
      );
    } on HandshakeException catch (error) {
      destroy();
      throw tds.OperationalException('TLS handshake failed: ${error.message}');
    } catch (_) {
      destroy();
      rethrow;
    }
    if (_closed) {
      unawaited(secure.close().then<void>((_) {}, onError: (Object _) {}));
      throw tds.ClosedConnectionException();
    }
    _raw = secure;
    _secure = true;
    _attach();
  }
}

/// `setsockopt` keepalive option numbers for each OS.
class _KeepAliveOptions {
  const _KeepAliveOptions(this.soKeepAlive, this.tcpKeepIdle,
      this.tcpKeepInterval, this.tcpKeepCount);

  final int soKeepAlive;
  final int tcpKeepIdle;
  final int tcpKeepInterval;
  final int tcpKeepCount;

  static final _KeepAliveOptions? current = () {
    if (Platform.isLinux || Platform.isAndroid) {
      // SO_KEEPALIVE, TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT
      return const _KeepAliveOptions(9, 4, 5, 6);
    }
    if (Platform.isMacOS || Platform.isIOS) {
      // SO_KEEPALIVE, TCP_KEEPALIVE, TCP_KEEPINTVL, TCP_KEEPCNT
      return const _KeepAliveOptions(0x0008, 0x10, 0x101, 0x102);
    }
    if (Platform.isWindows) {
      // SO_KEEPALIVE, TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT (Win10 1709+)
      return const _KeepAliveOptions(0x0008, 3, 17, 16);
    }
    return null;
  }();
}
