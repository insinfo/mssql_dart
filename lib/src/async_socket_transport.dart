import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'tds_base.dart' as tds;
import 'transport_tls.dart';
class AsyncSocketTransport implements tds.AsyncTransportProtocol, AsyncTlsTransport {
  AsyncSocketTransport._(
    this._socket, {
    required this.description,
    String? host,
    int? port,
    bool isSecure = false,
  })  : _host = host,
        _port = port,
        _secure = isSecure {
    _subscription = _socket.listen(
      _handleData,
      onDone: _handleDone,
      onError: _handleError,
      cancelOnError: true,
    );
  }

  static Future<AsyncSocketTransport> connect(
    String host,
    int port, {
    Duration? timeout,
    String? description,
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      return AsyncSocketTransport._(
        socket,
        description: description ?? '$host:$port',
        host: host,
        port: port,
      );
    } on SocketException catch (err) {
      throw tds.OperationalError('Falha ao conectar a $host:$port: ${err.message}');
    }
  }

  static Future<AsyncSocketTransport> connectSecure(
    String host,
    int port, {
    Duration? timeout,
    String? description,
    SecurityContext? context,
    bool validateHost = true,
  }) async {
    try {
      final socket = await SecureSocket.connect(
        host,
        port,
        timeout: timeout,
        context: context,
        supportedProtocols: const ['tls1.3', 'tls1.2'],
        onBadCertificate: validateHost ? null : (_) => true,
      );
      return AsyncSocketTransport._(
        socket,
        description: description ?? '$host:$port',
        host: host,
        port: port,
        isSecure: true,
      );
    } on HandshakeException catch (err) {
      throw tds.OperationalError('Falha no handshake TLS: ${err.message}');
    } on SocketException catch (err) {
      throw tds.OperationalError('Falha ao conectar a $host:$port: ${err.message}');
    }
  }

  final String description;
  Socket _socket;
  final String? _host;
  final int? _port;
  bool _connected = true;
  Duration? _timeout;
  StreamSubscription<List<int>>? _subscription;
  Object? _socketError;
  final Queue<_Chunk> _chunks = Queue<_Chunk>();
  int _available = 0;
  Completer<void>? _pendingRead;
  bool _secure = false;

  /// Expõe o Socket subjacente para cenários que ainda dependem do objeto real.
  Socket get socket => _socket;

  @override
  bool get isConnected => _connected;

  @override
  Duration? get timeout => _timeout;

  @override
  set timeout(Duration? value) {
    _timeout = value;
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  bool get isSecure => _secure;
  @override
  String? get remoteHost => _host;
  String? get host => _host;
  int? get port => _port;

  void _handleData(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    final chunk = _Chunk(Uint8List.fromList(data));
    _chunks.addLast(chunk);
    _available += chunk.remaining;
    _pendingRead?..complete();
    _pendingRead = null;
  }

  void _handleDone() {
    _connected = false;
    _pendingRead?..complete();
    _pendingRead = null;
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _socketError = error;
    _connected = false;
    final pending = _pendingRead;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stackTrace);
    }
    _pendingRead = null;
  }

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) async {
    if (!_connected) {
      throw tds.ClosedConnectionError();
    }
    if (data.isEmpty) {
      return;
    }
    _socket.add(data);
    await _socket.flush();
  }

  Future<void> _waitForData() async {
    if (_available > 0 || !_connected) {
      return;
    }
    _pendingRead = Completer<void>();
    await _pendingRead!.future;
  }

  @override
  Future<Uint8List> recv(int size) async {
    if (size <= 0) {
      return Uint8List(0);
    }
    while (_available < size && _connected) {
      await _waitForData();
    }
    if (_available == 0 && !_connected) {
      final error = _socketError;
      if (error != null) {
        throw error;
      }
      throw tds.ClosedConnectionError();
    }
    final toRead = size < _available ? size : _available;
    return _consumeBytes(toRead);
  }

  @override
  Future<Uint8List> recvAvailable(int maxSize) async {
    if (maxSize <= 0) {
      return Uint8List(0);
    }
    while (_available == 0 && _connected) {
      await _waitForData();
    }
    if (_available == 0 && !_connected) {
      final error = _socketError;
      if (error != null) {
        throw error;
      }
      throw tds.ClosedConnectionError();
    }
    final toRead = maxSize < _available ? maxSize : _available;
    return _consumeBytes(toRead);
  }

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) async {
    final target = buffer.asUint8List();
    final desired = size <= 0 || size > target.length ? target.length : size;
    if (desired == 0) {
      return 0;
    }
    final bytes = await recv(desired);
    target.setRange(0, bytes.length, bytes);
    return bytes.length;
  }

  Uint8List _consumeBytes(int size) {
    if (size <= 0) {
      return Uint8List(0);
    }
    final builder = BytesBuilder(copy: false);
    var remaining = size;
    while (remaining > 0 && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final take = chunk.remaining < remaining ? chunk.remaining : remaining;
      builder.add(chunk.take(take));
      remaining -= take;
      _available -= take;
      if (chunk.remaining == 0) {
        _chunks.removeFirst();
      }
    }
    return builder.takeBytes();
  }

  @override
  Future<void> close() async {
    if (!_connected) {
      return;
    }
    _connected = false;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket.flush();
    } catch (_) {
      // Ignore flush errors on close
    }
    await _socket.close();
    _chunks.clear();
    _available = 0;
    _pendingRead?..complete();
    _pendingRead = null;
  }

  @override
  Future<void> upgradeToSecureSocket({
    required SecurityContext context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    String? host,
    bool loginOnly = false,
  }) async {
    if (_secure) {
      return;
    }
    final socket = _socket;
    StreamSubscription<List<int>>? previousSub;
    try {
      previousSub = _subscription;
      await previousSub?.cancel();
      _subscription = null;
      final secureSocket = await SecureSocket.secure(
        socket,
        context: context,
        onBadCertificate: onBadCertificate,
        supportedProtocols: const ['tls1.3', 'tls1.2'],
        host: host ?? _host,
      );
      _socket = secureSocket;
      _chunks.clear();
      _available = 0;
      _socketError = null;
      _subscription = secureSocket.listen(
        _handleData,
        onDone: _handleDone,
        onError: _handleError,
        cancelOnError: true,
      );
      _secure = true;
    } on HandshakeException catch (error) {
      _connected = false;
      await socket.close();
      throw tds.OperationalError('Falha no handshake TLS: ${error.message}');
    }
  }
}

class _Chunk {
  _Chunk(this.data);
  final Uint8List data;
  int offset = 0;
  int get remaining => data.length - offset;
  Uint8List take(int length) {
    final view = Uint8List.sublistView(data, offset, offset + length);
    offset += length;
    return view;
  }
}
