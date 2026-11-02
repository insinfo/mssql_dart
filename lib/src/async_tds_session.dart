import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'async_operation_lock.dart';
import 'collate.dart';
import 'row_strategies.dart';
import 'session_link.dart';
import 'session_reset.dart';
import 'async_socket_transport.dart';
import 'row_decoder.dart';
import 'tls/encrypted_socket.dart';
import 'rpc_params.dart';
import 'tds_base.dart' as tds;
import 'tds_reader.dart';
import 'tds_writer.dart';
import 'tds_types.dart';
import 'transport_tls.dart';
import 'tls/tls_channel.dart' as tls_channel;

const int _clientLibraryVersion = 0x01000000;
const String _defaultInstanceName = 'MSSQLServer';
const int _tmBeginXact = 5;
const int _tmCommitXact = 7;
const int _tmRollbackXact = 8;
const int _tmFlagChain = 1;

final AsyncSessionBuilder defaultAsyncSessionBuilder =
    (context) => AsyncTdsSession.fromContext(context);

class AsyncTdsSession
    implements AsyncSessionLink, tds.TdsSessionContract, ResettableSession {
  AsyncTdsSession({
    required tds.AsyncTransportProtocol transport,
    required tds.TdsEnv env,
    required int bufsize,
    this.tzinfoFactory,
    RowStrategy? rowStrategy,
    SerializerFactory? typeFactory,
    Collation? initialCollation,
    bool bytesToUnicode = true,
    void Function(Collation?)? onCollationChanged,
    void Function(int newTransactionId)? onTransactionStateChange,
    void Function(tds.Route route)? onRouteChange,
    void Function(String flags)? onUnicodeSortFlags,
    SessionTraceHook? traceHook,
  })  : _transport = transport,
        _env = env,
        _typeFactory = typeFactory ?? SerializerFactory(tds.TDS74),
        _connectionCollation = initialCollation,
        _bytesToUnicode = bytesToUnicode,
        _onCollationChanged = onCollationChanged,
        _onTransactionStateChange = onTransactionStateChange,
        _onRouteChange = onRouteChange,
        _onUnicodeSortFlags = onUnicodeSortFlags,
        _traceHook = traceHook {
    _setRowStrategy(rowStrategy ?? defaultRowStrategy);
    _collation = initialCollation;
    _reader = AsyncTdsReader(
      transport: transport,
      session: this,
      bufsize: bufsize,
    );
    _writer = AsyncTdsWriter(
      transport: transport,
      session: this,
      bufsize: bufsize,
    );
  }

  factory AsyncTdsSession.fromContext(AsyncSessionBuildContext context) {
    return AsyncTdsSession(
      transport: context.transport,
      env: context.env,
      bufsize: context.bufsize,
      tzinfoFactory: context.tzinfoFactory,
      rowStrategy: context.rowStrategy,
      typeFactory: context.typeFactory,
      initialCollation: context.collation,
      bytesToUnicode: context.bytesToUnicode,
      onCollationChanged: context.onCollationChanged,
      onTransactionStateChange: context.onTransactionStateChange,
      onRouteChange: context.onRouteChange,
      onUnicodeSortFlags: context.onUnicodeSortFlags,
      traceHook: context.traceHook,
    );
  }

  final tds.AsyncTransportProtocol _transport;
  final tds.TdsEnv _env;
  late final AsyncTdsReader _reader;
  late final AsyncTdsWriter _writer;
  final TzInfoFactory? tzinfoFactory;
  late RowStrategy _rowStrategy;
  late RowGenerator _rowConvertor;
  late SerializerFactory _typeFactory;
  Collation? _connectionCollation;
  bool _bytesToUnicode;
  final void Function(Collation?)? _onCollationChanged;
  final void Function(int)? _onTransactionStateChange;
  final void Function(tds.Route)? _onRouteChange;
  final void Function(String)? _onUnicodeSortFlags;
  final SessionTraceHook? _traceHook;
  final Queue<dynamic> _rowBuffer = ListQueue<dynamic>();

  final List<tds.Message> _messages = [];
  tds.AuthProtocol? _authentication;
  int _state = tds.TDS_IDLE;
  int _tdsVersion = tds.TDS74;
  String? _lastQuery;
  int _doneFlags = 0;
  int _rowsAffected = tds.TDS_NO_COUNT;
  int? _returnStatus;
  bool _hasStatus = false;
  bool _inCancel = false;
  bool _moreRows = false;
  int _transactionId = 0;
  Collation? _collation;
  tds.Results? _results;
  List<dynamic> _currentRow = const <dynamic>[];
  bool _skippedToStatus = false;
  final AsyncOperationLock _operationLock = AsyncOperationLock();
  Map<String, Object?> _outputParameters = {};

  /// Error to throw once the server acknowledges the ATTENTION; non-null
  /// while a cancellation is pending.
  tds.MssqlException? _cancelError;
  bool _attentionSent = false;
  bool _absorbingAttention = false;
  bool _sending = false;
  Timer? _attentionTimer;

  /// Tokens read so far; shows that the server is still responding.
  int _progress = 0;
  int _progressAtLastCheck = 0;

  // Deadline of the running command, checked on every token: when data is
  // always available on the socket, reading can go a long time without
  // yielding to the event loop, and a Timer alone would fire late.
  final Stopwatch _clock = Stopwatch()..start();
  int _deadlineMicros = 0;
  void Function()? _onDeadline;
  Object? _deadlineOwner;

  /// Cancellation acknowledged while nobody was reading the response (idle
  /// cursor); delivered on the next read.
  tds.MssqlException? _orphanCancel;

  /// Error of a command whose connection was closed because the server did
  /// not acknowledge the cancellation; delivered to whoever was awaiting the
  /// response.
  tds.MssqlException? _attentionAbortError;

  /// How long to wait for an ATTENTION acknowledgement before closing the
  /// connection.
  Duration attentionGracePeriod = const Duration(seconds: 5);

  /// Calls [onExpired] (once) after [remaining] elapses, checked on every
  /// token read. Replaces any previous deadline; [owner] identifies who set
  /// it, for [clearDeadline].
  void setDeadline(
      Object owner, Duration remaining, void Function() onExpired) {
    _deadlineOwner = owner;
    _deadlineMicros = _clock.elapsedMicroseconds + remaining.inMicroseconds;
    _onDeadline = onExpired;
  }

  /// Removes the deadline set by [owner].
  void clearDeadline(Object owner) {
    if (!identical(_deadlineOwner, owner)) return;
    _deadlineOwner = null;
    _onDeadline = null;
  }

  void _checkDeadline() {
    final onExpired = _onDeadline;
    if (onExpired == null || _clock.elapsedMicroseconds < _deadlineMicros) {
      return;
    }
    _onDeadline = null;
    _deadlineOwner = null;
    onExpired();
  }

  /// Error thrown by the next request instead of sending it. Used when the
  /// deadline of a multi-request command expires between two requests.
  tds.MssqlException? cancelBeforeNextRequest;

  void _trace(String event, [Map<String, Object?>? data]) {
    final hook = _traceHook;
    if (hook == null) {
      return;
    }
    hook(event, data == null ? const {} : Map.unmodifiable(data));
  }

  SerializerFactory get typeFactory => _typeFactory;
  Collation? get connectionCollation => _connectionCollation;
  bool get bytesToUnicode => _bytesToUnicode;
  int get rowsAffected => _rowsAffected;
  int? get returnStatus => _returnStatus;

  /// Values of the OUTPUT parameters (RETURNVALUE tokens) of the last
  /// request, keyed by name without `@` (or by zero-based position, for
  /// parameters sent without a name).
  Map<String, Object?> get outputParameters => _outputParameters;

  /// Whether a cancellation (ATTENTION) is awaiting server acknowledgement.
  bool get cancelPending => _cancelError != null;

  /// Whether the server reported an open transaction (transaction
  /// ENVCHANGE).
  bool get transactionActive => _transactionId != 0;
  bool get hasReturnStatus => _hasStatus;
  bool get moreResults => _moreRows;
  Collation? get collation => _collation;
  RowStrategy get rowStrategy => _rowStrategy;
  tds.Results? get results => _results;
  List<dynamic> get currentRow => _currentRow;
  bool get skippedToStatus => _skippedToStatus;
  bool get hasBufferedRows => _rowBuffer.isNotEmpty;
  int get bufferedRowCount => _rowBuffer.length;
  String? get lastQuery => _lastQuery;
  tds.TdsEnv get env => _env;
  List<tds.Message> get messages => _messages;

  /// Runs [action] with exclusive access to the TDS channel.
  ///
  /// Like the `_operationLock` in `postgresql-dart`, it prevents two
  /// asynchronous operations from using the same socket at once. Useful for
  /// wrapping `submitPlainQuery` + `processSimpleRequest` sequences under a
  /// single lock.
  ///
  /// If [action] fails mid-response, a server error is drained and the
  /// session stays usable; any other error (protocol, decoding, timeout)
  /// leaves the TDS stream out of sync, so the connection is closed and
  /// subsequent calls fail with [tds.ClosedConnectionException] instead of
  /// waiting for bytes that will never arrive.
  Future<T> runSerial<T>(Future<T> Function() action) {
    return _operationLock.synchronized(() async {
      if (_state == tds.TDS_DEAD) throw tds.ClosedConnectionException();
      try {
        return await action();
      } catch (error) {
        await _recoverAfterError(error);
        final abort = _attentionAbortError;
        if (abort != null) {
          _attentionAbortError = null;
          throw abort;
        }
        rethrow;
      }
    });
  }

  /// Asks the server to interrupt the running request (ATTENTION).
  ///
  /// The response keeps being read until the acknowledgement (DONE with
  /// DONE_ATTN); the active reader receives [error] and the session becomes
  /// free again. Without an active reader (an idle cursor), the
  /// acknowledgement is consumed in the background and [error] is delivered
  /// on the next read. If the acknowledgement does not arrive within
  /// [attentionGracePeriod], the connection is closed.
  ///
  /// Returns `false` if no request was running, unless [force] is true, in
  /// which case the ATTENTION is sent anyway.
  Future<bool> requestCancel(tds.MssqlException error,
      {bool force = false}) async {
    if (_state == tds.TDS_DEAD) return false;
    if (_cancelError != null) return true;
    final busy =
        _sending || _state == tds.TDS_PENDING || _state == tds.TDS_READING;
    if (!busy && !force) return false;
    _cancelError = error;
    _inCancel = true;
    _progressAtLastCheck = _progress;
    _attentionTimer = Timer.periodic(attentionGracePeriod, (_) {
      // Only give up if nothing arrived from the server since the last check.
      if (_progress != _progressAtLastCheck) {
        _progressAtLastCheck = _progress;
        return;
      }
      _attentionTimedOut();
    });
    _trace('attention.request', {'error': error.toString()});
    // Without an active reader, consume the acknowledgement in the
    // background. Run outside the current zone so the caller's lock is not
    // inherited.
    Zone.root.run(() {
      runSerial(() async {
        if (_cancelError == null || _state == tds.TDS_DEAD) return;
        if (_state == tds.TDS_IDLE && !_attentionSent && !force) return;
        try {
          await _absorbAttention();
        } on tds.MssqlCancelledException catch (cancelled) {
          if (identical(cancelled, error)) {
            _orphanCancel = cancelled;
          } else {
            rethrow;
          }
        }
      }).then<void>((_) {}, onError: (Object _) {});
    });
    if (!_sending) await _sendAttention();
    return true;
  }

  Future<void> _sendAttention() async {
    if (_attentionSent || _cancelError == null) return;
    _attentionSent = true;
    try {
      _writer.beginPacket(tds.PacketType.CANCEL);
      await _writer.flush();
      _trace('attention.sent');
    } catch (_) {
      _abortConnection();
    }
  }

  void _attentionTimedOut() {
    final error = _cancelError;
    if (error == null || _state == tds.TDS_DEAD) return;
    _trace('attention.timeout');
    _attentionAbortError = error is tds.MssqlTimeoutException
        ? tds.MssqlTimeoutException(error.timeout, connectionClosed: true)
        : tds.MssqlCancelledException(
            'Command cancelled; the server did not acknowledge the '
            'cancellation and the connection was closed');
    _abortConnection();
  }

  void _abortConnection() {
    _attentionTimer?.cancel();
    _attentionTimer = null;
    _cancelError = null;
    _state = tds.TDS_DEAD;
    final transport = _transport;
    if (transport is AsyncSocketTransport) {
      transport.destroy();
    } else {
      unawaited(transport.close().catchError((Object _) {}));
    }
  }

  /// Discards the response up to the ATTENTION acknowledgement and throws the
  /// cancellation error, with the session already free.
  Future<Never> _absorbAttention() async {
    final error = _cancelError!;
    _absorbingAttention = true;
    try {
      while (true) {
        if (_reader.streamFinished()) {
          await _reader.beginResponse();
        }
        _state = tds.TDS_READING;
        final marker = await _reader.getByte();
        _progress++;
        if (_isDoneToken(marker)) {
          final status = await _reader.getUSmallInt();
          await _reader.getUSmallInt();
          tds.isTds72Plus(this)
              ? await _reader.getInt8()
              : await _reader.getInt();
          if ((status & tds.TDS_DONE_ATTN) != 0) break;
          continue;
        }
        switch (marker) {
          case tds.TDS_ROW_TOKEN:
            await _processRowToken();
            _rowBuffer.clear();
          case tds.TDS_NBC_ROW_TOKEN:
            await _processNbcRowToken();
            _rowBuffer.clear();
          case tds.TDS_PARAM_TOKEN:
            await _processReturnValue();
          default:
            if (!await _handleCommonToken(marker)) await _skipToken(marker);
        }
      }
    } finally {
      _absorbingAttention = false;
    }
    _finishAttention();
    throw error;
  }

  void _finishAttention() {
    _trace('attention.ack');
    _attentionTimer?.cancel();
    _attentionTimer = null;
    _cancelError = null;
    _attentionSent = false;
    _inCancel = false;
    _resetResultsState(clearRowBuffer: true);
    _messages.clear();
    _state = tds.TDS_IDLE;
  }

  void _throwOrphanCancel() {
    final orphan = _orphanCancel;
    if (orphan != null) {
      _orphanCancel = null;
      throw orphan;
    }
  }

  Future<void> _recoverAfterError(Object error) async {
    if (_state == tds.TDS_IDLE || _state == tds.TDS_DEAD) return;
    // A cancellation or server error leaves the stream in sync: discarding
    // the rest of the response is enough.
    if (error is tds.MssqlCancelledException ||
        (error is tds.DatabaseException && error.number != 0)) {
      try {
        await drainPending();
        return;
      } catch (_) {
        // Fall through to closing below.
      }
    }
    _state = tds.TDS_DEAD;
    final transport = _transport;
    if (transport is AsyncSocketTransport) {
      transport.destroy();
    } else {
      await transport.close().catchError((Object _) {});
    }
  }

  @override
  tds.AsyncTransportProtocol get transport => _transport;

  @override
  int get writerBufferSize => _writer.bufsize;

  @override
  int get readerBlockSize => _reader.blockSize;

  @override
  void setReaderBlockSize(int size) => _reader.setBlockSize(size);

  @override
  Future<void> sendPrelogin(tds.TdsLogin login) async {
    _tdsVersion = login.tdsVersion;
    final instance =
        login.instanceName.isEmpty ? _defaultInstanceName : login.instanceName;
    final instanceBytes = ascii.encode(instance);
    final startPos = tds.isTds72Plus(this) ? 26 : 21;
    final header = Uint8List(startPos);
    final view = ByteData.sublistView(header);
    var cursor = 0;
    var payloadOffset = startPos;

    void writeEntry(int token, int length) {
      view.setUint8(cursor, token);
      view.setUint16(cursor + 1, payloadOffset, Endian.big);
      view.setUint16(cursor + 3, length, Endian.big);
      cursor += 5;
      payloadOffset += length;
    }

    writeEntry(tds.PreLoginToken.VERSION, 6);
    writeEntry(tds.PreLoginToken.ENCRYPTION, 1);
    writeEntry(tds.PreLoginToken.INSTOPT, instanceBytes.length + 1);
    writeEntry(tds.PreLoginToken.THREADID, 4);
    if (tds.isTds72Plus(this)) {
      writeEntry(tds.PreLoginToken.MARS, 1);
    }
    view.setUint8(cursor, tds.PreLoginToken.TERMINATOR);

    _writer.beginPacket(tds.PacketType.PRELOGIN);
    await _writer.write(header);
    await _writer.putUIntBe(_clientLibraryVersion);
    await _writer.putUSmallIntBe(0);
    await _writer.putByte(login.encFlag);
    await _writer.write(instanceBytes);
    await _writer.putByte(0);
    await _writer.putInt(0);
    if (tds.isTds72Plus(this)) {
      await _writer.putByte(login.useMars ? 1 : 0);
    }
    _trace('prelogin.send', {
      'tds_version': '0x${login.tdsVersion.toRadixString(16)}',
      'enc_flag': login.encFlag,
      'instance': instance,
      'mars': login.useMars,
    });
    await _writer.flush();
    _state = tds.TDS_PENDING;
  }

  @override
  Future<void> processPrelogin(tds.TdsLogin login) async {
    final resp = await beginResponse();
    final payload = await _reader.readWholePacket();
    if (resp.type != tds.PacketType.REPLY) {
      _badStream(
        'Unexpected packet type during PRELOGIN: ${resp.type}',
      );
    }
    await _parsePrelogin(payload, login);
  }

  Future<void> _parsePrelogin(List<int> octets, tds.TdsLogin login) async {
    if (octets.isEmpty) {
      _badStream('Empty PRELOGIN response');
    }
    final data = Uint8List.fromList(octets);
    final size = data.length;
    final byteView = ByteData.sublistView(data);
    var offset = 0;
    var cryptFlag = tds.PreLoginEnc.ENCRYPT_NOT_SUP;
    while (offset < size) {
      final token = data[offset];
      if (token == tds.PreLoginToken.TERMINATOR) {
        break;
      }
      if (offset + 5 > size) {
        _badStream('Truncated PRELOGIN structure');
      }
      final payloadOffset = byteView.getUint16(offset + 1, Endian.big);
      final payloadLength = byteView.getUint16(offset + 3, Endian.big);
      if (payloadOffset + payloadLength > size) {
        _badStream('Invalid offset in PRELOGIN');
      }
      switch (token) {
        case tds.PreLoginToken.VERSION:
          break;
        case tds.PreLoginToken.ENCRYPTION:
          cryptFlag = data[payloadOffset];
          break;
        default:
          break;
      }
      offset += 5;
    }
    login.serverEncFlag = cryptFlag;
    await _handleEncryptionNegotiation(login, cryptFlag);
    _trace('prelogin.response', {
      'crypt_flag': cryptFlag,
      'mars_requested': login.useMars,
    });
  }

  /// Exposed for tests only.
  Future<void> debugHandleEncryptionNegotiation(
    tds.TdsLogin login,
    int cryptFlag,
  ) {
    return _handleEncryptionNegotiation(login, cryptFlag);
  }

  Future<void> _handleEncryptionNegotiation(
    tds.TdsLogin login,
    int cryptFlag,
  ) async {
    final transport = _transport;
    final tlsTransport =
        transport is AsyncTlsTransport ? transport as AsyncTlsTransport : null;
    final alreadySecure = tlsTransport?.isSecure ?? false;
    if (alreadySecure) {
      _trace('tls.already_secure', {
        'crypt_flag': cryptFlag,
        'client_flag': login.encFlag,
      });
      return;
    }

    final clientWantsTls = login.encFlag == tds.PreLoginEnc.ENCRYPT_ON ||
        login.encFlag == tds.PreLoginEnc.ENCRYPT_REQ;
    final clientEncOff = login.encFlag == tds.PreLoginEnc.ENCRYPT_OFF;

    switch (cryptFlag) {
      case tds.PreLoginEnc.ENCRYPT_OFF:
        if (clientWantsTls && !login.encLoginOnly) {
          throw tds.OperationalException(
            'The server returned ENCRYPT_OFF but the client requires full encryption. '
            'Use encLoginOnly=true to encrypt only the login.',
          );
        }
        // Server wants ENCRYPT_OFF; if the client asked for it, encrypt only
        // the login.
        if (clientEncOff && login.encLoginOnly) {
          // Client asked for ENCRYPT_OFF: encrypt only the login.
          await _performTlsUpgrade(login);
        }
        return;

      case tds.PreLoginEnc.ENCRYPT_NOT_SUP:
        if (clientWantsTls) {
          throw tds.OperationalException(
            'The server does not support encryption for this login. '
            'Set encrypt=false to continue in plaintext mode.',
          );
        }
        return;

      case tds.PreLoginEnc.ENCRYPT_ON:
      case tds.PreLoginEnc.ENCRYPT_REQ:
        // Server requires TLS: upgrade the connection.
        if (clientEncOff && !login.encLoginOnly) {
          throw tds.OperationalException(
            'The server requires TLS encryption, but the connection was configured with encrypt=false. '
            'Enable encrypt=true, or set encLoginOnly=true only if you accept staying on TLS.',
          );
        }
        if (login.encFlag == tds.PreLoginEnc.ENCRYPT_NOT_SUP) {
          throw tds.OperationalException(
            'The server requires TLS encryption, but the connection was configured with encrypt=false. '
            'Enable encrypt=true or choose a compatible TLS backend.',
          );
        }
        await _performTlsUpgrade(login);
        return;

      default:
        _badStream(
            'Unexpected encrypt_flag value returned by the server: $cryptFlag');
    }
  }

  /// Upgrades the connection to TLS mid-stream.
  Future<void> _performTlsUpgrade(tds.TdsLogin login) async {
    final backend = _resolveMidstreamBackend(login);

    _trace('tls.upgrade.start', {
      'backend': backend.name,
      'server': login.serverName,
      'enc_login_only': login.encLoginOnly,
    });

    try {
      await tls_channel.establishChannel(
        session: _createTlsSessionAdapter(),
        login: login,
        backend: backend,
      );

      final encrypted = _reader.transport;
      _trace('tls.upgrade.complete', {
        'backend': backend.name,
        if (encrypted is PureDartEncryptedSocket) ...encrypted.negotiated,
      });
    } catch (error) {
      _trace('tls.upgrade.failed', {
        'error': error.toString(),
      });
      rethrow;
    }
  }

  tds.TlsBackend _resolveMidstreamBackend(tds.TdsLogin login) {
    switch (login.tlsBackend) {
      case tds.TlsBackend.tlslite:
        return tds.TlsBackend.tlslite;
      case tds.TlsBackend.openSsl:
        return tds.TlsBackend.openSsl;
    }
  }

  /// Creates an adapter for the `TdsSessionForTls` interface.
  tls_channel.TdsSessionForTls _createTlsSessionAdapter() {
    return _AsyncTdsSessionTlsAdapter(this);
  }

  @override
  Future<void> sendLogin(tds.TdsLogin login) async {
    final isTds72Plus = tds.isTds72Plus(this);
    final userName = login.userName;
    if (userName.length > 128) {
      throw ArgumentError('User name must be at most 128 characters');
    }
    _authentication = login.auth;
    Uint8List authPacket = Uint8List(0);
    if (_authentication != null) {
      authPacket = Uint8List.fromList(_authentication!.createPacket());
    }
    final headerBase = isTds72Plus ? 94 : 86;
    var currentPos = headerBase;
    final baseChars = login.clientHostName.length +
        login.appName.length +
        login.serverName.length +
        login.library.length +
        login.language.length +
        login.database.length +
        login.attachDbFile.length;
    final extraChars = isTds72Plus ? login.changePassword.length : 0;
    var packetSize = headerBase + 2 * (baseChars + extraChars);
    if (_authentication != null) {
      packetSize += authPacket.length;
    } else {
      packetSize += 2 * (userName.length + login.password.length);
    }
    final writer = _writer;
    writer.beginPacket(tds.PacketType.LOGIN);
    await writer.putInt(packetSize);
    await writer.putUInt(login.tdsVersion);
    await writer.putInt(login.blocksize);
    await writer.putUInt(_clientLibraryVersion);
    await writer.putInt(login.pid);
    await writer.putUInt(0);
    var optionFlag1 =
        tds.TDS_SET_LANG_ON | tds.TDS_USE_DB_NOTIFY | tds.TDS_INIT_DB_FATAL;
    if (!login.bulkCopy) {
      optionFlag1 |= tds.TDS_DUMPLOAD_OFF;
    }
    await writer.putByte(optionFlag1);
    var optionFlag2 = login.optionFlag2;
    if (_authentication != null) {
      optionFlag2 |= tds.TDS_INTEGRATED_SECURITY_ON;
    }
    await writer.putByte(optionFlag2);
    var typeFlags = 0;
    if (login.readonly) {
      typeFlags |= tds.TDS_FREADONLY_INTENT;
    }
    await writer.putByte(typeFlags);
    await writer.putByte(
        tds.isTds73Plus(this) ? tds.TDS_UNKNOWN_COLLATION_HANDLING : 0);
    final offsetMinutes = login.clientTz.timeZoneOffset.inMinutes;
    await writer.putInt(offsetMinutes);
    await writer.putInt(login.clientLcid);

    Future<void> writeOffsetLen(String value) async {
      await writer.putSmallInt(currentPos);
      await writer.putSmallInt(value.length);
      currentPos += value.length * 2;
    }

    await writeOffsetLen(login.clientHostName);
    if (_authentication != null) {
      await writer.putSmallInt(0);
      await writer.putSmallInt(0);
      await writer.putSmallInt(0);
      await writer.putSmallInt(0);
    } else {
      await writeOffsetLen(userName);
      await writeOffsetLen(login.password);
    }
    await writeOffsetLen(login.appName);
    await writeOffsetLen(login.serverName);
    await writer.putSmallInt(0);
    await writer.putSmallInt(0);
    await writeOffsetLen(login.library);
    await writeOffsetLen(login.language);
    await writeOffsetLen(login.database);
    final clientIdBytes = ByteData(8)..setUint64(0, login.clientId, Endian.big);
    await writer.write(clientIdBytes.buffer.asUint8List(2));
    await writer.putSmallInt(currentPos);
    await writer.putSmallInt(authPacket.length);
    currentPos += authPacket.length;
    await writeOffsetLen(login.attachDbFile);
    if (isTds72Plus) {
      await writeOffsetLen(login.changePassword);
      await writer.putInt(0);
    }
    await writer.writeUcs2(login.clientHostName);
    if (_authentication == null) {
      await writer.writeUcs2(userName);
      await writer.write(tds.tds7CryptPass(login.password));
    }
    await writer.writeUcs2(login.appName);
    await writer.writeUcs2(login.serverName);
    await writer.writeUcs2(login.library);
    await writer.writeUcs2(login.language);
    await writer.writeUcs2(login.database);
    if (_authentication != null) {
      await writer.write(authPacket);
    }
    await writer.writeUcs2(login.attachDbFile);
    await writer.writeUcs2(login.changePassword);
    _trace('login.send', {
      'user': userName,
      'database': login.database,
      'app': login.appName,
      'tds_version': '0x${login.tdsVersion.toRadixString(16)}',
      'packet_size': packetSize,
      'auth': _authentication != null,
    });
    await writer.flush();
    _state = tds.TDS_PENDING;
  }

  @override
  Future<ResponseMetadata> beginResponse() async {
    try {
      final meta = await _reader.beginResponse();
      _state = tds.TDS_READING;
      return meta;
    } on tds.TimeoutError {
      await requestCancel(tds.MssqlCancelledException(), force: true);
      rethrow;
    }
  }

  @override
  Future<bool> processLoginTokens() async {
    var succeed = false;
    while (true) {
      if (_reader.streamFinished()) {
        await beginResponse();
      }
      final marker = await _nextTokenId();
      if (marker == tds.TDS_LOGINACK_TOKEN) {
        succeed = true;
        await _processLoginAck();
      } else if (await _handleCommonToken(marker)) {
        if (marker == tds.TDS_DONE_TOKEN &&
            (_doneFlags & tds.TDS_DONE_MORE_RESULTS) == 0) {
          break;
        }
      } else {
        await _skipToken(marker);
      }
      if (marker == tds.TDS_DONE_TOKEN &&
          (_doneFlags & tds.TDS_DONE_MORE_RESULTS) == 0) {
        break;
      }
    }
    return succeed;
  }

  Future<void> _processLoginAck() async {
    var size = await _reader.getSmallInt();
    await _reader.getByte();
    final version = await _reader.getUIntBe();
    _tdsVersion = _serverToClientMapping[version] ?? version;
    if (!tds.isTds7Plus(this)) {
      _badStream('Minimum supported TDS version is 7.0');
    }
    await _reader.getByte();
    size -= 10;
    final nameChars = math.max(0, size ~/ 2);
    await _reader.readUcs2(nameChars);
    await _reader.getUIntBe();
    if (_authentication != null) {
      _authentication!.close();
      _authentication = null;
    }
    _trace('login.ack', {
      'tds_version': '0x${_tdsVersion.toRadixString(16)}',
      'server_version': '0x${version.toRadixString(16)}',
    });
  }

  static const Map<int, int> _serverToClientMapping = {
    0x07000000: tds.TDS70,
    0x07010000: tds.TDS71,
    0x71000001: tds.TDS71rev1,
    tds.TDS72: tds.TDS72,
    tds.TDS73A: tds.TDS73A,
    tds.TDS73B: tds.TDS73B,
    tds.TDS74: tds.TDS74,
  };

  @override
  void raiseDbException() {
    if (_messages.isEmpty) {
      throw tds.MssqlException(
        'Request failed and the server returned no details.',
      );
    }
    while (_messages.isNotEmpty &&
        _messages.last['msgno'] == 3621 &&
        _messages.length > 1) {
      _messages.removeLast();
    }
    final msg = _messages.last;
    final errorMsg = _messages.map((m) => m['message']).join(' ');
    final ex = tds.createExceptionByMessage(msg, customErrorMsg: errorMsg);
    _messages.clear();
    throw ex;
  }

  @override
  Future<void> submitPlainQuery(String sql) async {
    _beginRequest(sql);
    _writer.beginPacket(tds.PacketType.QUERY);
    _trace('query.submit', {
      'sql': sql,
      'length': sql.length,
    });
    await _sendRequest(() async {
      if (tds.isTds72Plus(this)) {
        await _startQuery();
      }
      await _writer.writeUcs2(sql);
    });
  }

  /// Sends [sql] with [params] as a binary RPC call to `sp_executesql`.
  Future<void> submitExecSql(String sql, Map<String, dynamic> params) async {
    if (params.isEmpty) {
      await submitPlainQuery(sql);
      return;
    }
    _checkCanSubmit();
    final payload = TdsBufferWriter(64 + sql.length * 2);
    encodeExecuteSql(payload, sql, params, _rpcCollation());
    _beginRequest(sql);
    _trace('rpc.submit', {'sql': sql, 'params': params.length});
    await _submitRpcPayload(payload.takeBytes());
  }

  /// Sends an RPC call to the procedure [name], by name. [params] with an
  /// empty name are positional.
  Future<void> submitProcedureCall(
      String name, List<(String, Object?)> params) async {
    _checkCanSubmit();
    final payload = TdsBufferWriter(64 + name.length * 2);
    encodeProcedureCall(payload, name, params, _rpcCollation());
    _beginRequest(name);
    _trace('rpc.procedure', {'name': name, 'params': params.length});
    await _submitRpcPayload(payload.takeBytes());
  }

  /// Runs [sql] once for each item of [items] in RPC batches (several
  /// `sp_executesql` calls in a single TDS message, separated by the
  /// BatchFlag) and returns the total rows affected, or `null` if any item
  /// reported no count.
  ///
  /// Each message carries up to [maxBatchBytes] (at least one item). A
  /// server error in one item is thrown after the whole message has been
  /// consumed; SQL Server runs the calls independently, so the remaining
  /// calls in that message still run, and subsequent messages are not
  /// sent.
  Future<int?> executeRpcBatch(
    String sql,
    List<Map<String, dynamic>> items, {
    int maxBatchBytes = 512 * 1024,
  }) async {
    var total = 0;
    var counted = true;
    var index = 0;
    final collation = _rpcCollation();
    while (index < items.length) {
      _checkCanSubmit();
      final payload = TdsBufferWriter(64 * 1024);
      var inBatch = 0;
      while (index < items.length &&
          (inBatch == 0 || payload.length < maxBatchBytes)) {
        if (inBatch > 0) writeRpcBatchSeparator(payload);
        encodeExecuteSql(payload, sql, items[index], collation);
        index++;
        inBatch++;
      }
      _beginRequest(sql);
      _trace('rpc.batch', {'sql': sql, 'items': inBatch});
      await _submitRpcPayload(payload.takeBytes());
      final count = await _readBatchResponse();
      if (count == null) {
        counted = false;
      } else {
        total += count;
      }
    }
    return counted ? total : null;
  }

  /// Reads the response of an RPC batch up to the end of the message,
  /// summing the rows affected by each call (the last count before each
  /// DONEPROC).
  Future<int?> _readBatchResponse() async {
    await beginResponse();
    var total = 0;
    var counted = true;
    var itemCount = tds.TDS_NO_COUNT;
    tds.DatabaseException? firstError;
    while (true) {
      final marker = await _nextTokenId();
      if (_isDoneToken(marker)) {
        final status = await _reader.getUSmallInt();
        await _reader.getUSmallInt();
        final rows = tds.isTds72Plus(this)
            ? await _reader.getInt8()
            : await _reader.getInt();
        _doneFlags = status;
        if ((status & tds.TDS_DONE_ATTN) != 0 && _cancelError != null) {
          final error = _cancelError!;
          _finishAttention();
          throw error;
        }
        if ((status & tds.TDS_DONE_COUNT) != 0) itemCount = rows;
        if ((status & tds.TDS_DONE_ERROR) != 0 && _messages.isNotEmpty) {
          try {
            raiseDbException();
          } on tds.DatabaseException catch (error) {
            firstError ??= error;
          }
        }
        if (marker == tds.TDS_DONEPROC_TOKEN) {
          if (itemCount == tds.TDS_NO_COUNT) {
            counted = false;
          } else {
            total += itemCount;
          }
          itemCount = tds.TDS_NO_COUNT;
        }
        if (_reader.streamFinished()) break;
        continue;
      }
      switch (marker) {
        case tds.TDS_ROW_TOKEN:
          await _processRowToken();
          _rowBuffer.clear();
        case tds.TDS_NBC_ROW_TOKEN:
          await _processNbcRowToken();
          _rowBuffer.clear();
        default:
          if (!await _handleCommonToken(marker)) await _skipToken(marker);
      }
    }
    if (_inCancel) {
      // The ATTENTION arrived after the end of the response; the
      // acknowledgement comes in another message.
      await _absorbAttention();
    }
    _resetResultsState(clearRowBuffer: true);
    _state = tds.TDS_IDLE;
    _rowsAffected = counted ? total : tds.TDS_NO_COUNT;
    final error = firstError;
    if (error != null) {
      _messages.clear();
      throw error;
    }
    return counted ? total : null;
  }

  void _checkCanSubmit() {
    if (_state == tds.TDS_DEAD) throw tds.ClosedConnectionException();
    if (_state != tds.TDS_IDLE) {
      throw tds.InterfaceException(
        'An operation is already pending on the current session.',
      );
    }
    final pending = cancelBeforeNextRequest;
    if (pending != null) {
      cancelBeforeNextRequest = null;
      throw pending;
    }
  }

  /// Prepares the session state for a new request.
  void _beginRequest(String sql) {
    _checkCanSubmit();
    _rowBuffer.clear();
    _messages.clear();
    _rowsAffected = tds.TDS_NO_COUNT;
    _returnStatus = null;
    _hasStatus = false;
    _outputParameters = {};
    _orphanCancel = null;
    _lastQuery = sql;
  }

  Future<void> _submitRpcPayload(Uint8List payload) async {
    _writer.beginPacket(tds.PacketType.RPC);
    await _sendRequest(() async {
      if (tds.isTds72Plus(this)) {
        await _startQuery();
      }
      await _writer.write(payload);
    });
  }

  /// Writes and sends the request; a cancellation requested while sending
  /// goes out right after the last packet.
  Future<void> _sendRequest(Future<void> Function() write) async {
    _sending = true;
    _writer.resetConnection = _resetOnNextRequest;
    _resetOnNextRequest = false;
    try {
      await write();
      await _writer.flush();
    } finally {
      _sending = false;
    }
    _state = tds.TDS_PENDING;
    if (_cancelError != null) await _sendAttention();
  }

  bool _resetOnNextRequest = false;

  @override
  void resetConnectionOnNextRequest() => _resetOnNextRequest = true;

  RpcCollation? _cachedRpcCollation;

  RpcCollation _rpcCollation() {
    final collation = _connectionCollation;
    final cached = _cachedRpcCollation;
    if (cached != null && identical(cached.collation, collation)) {
      return cached;
    }
    return _cachedRpcCollation = RpcCollation(collation);
  }

  @override
  Future<void> processSimpleRequest() async {
    await beginResponse();
    await _drainUntilDone();
  }

  @override
  Future<void> cancel() =>
      requestCancel(tds.MssqlCancelledException(), force: true);

  @override
  Future<void> beginTransaction({int? isolationLevel}) async {
    final level = isolationLevel ?? _env.isolationLevel;
    await _submitBeginTransaction(level);
    await processSimpleRequest();
  }

  @override
  Future<void> commitTransaction({bool startNew = false}) async {
    if (_env.autocommit || _transactionId == 0) {
      return;
    }
    await _submitCommitTransaction(
      startNew: startNew,
      isolationLevel: _env.isolationLevel,
    );
    await processSimpleRequest();
  }

  @override
  Future<void> rollbackTransaction({bool startNew = false}) async {
    if (_env.autocommit || _transactionId == 0) {
      return;
    }
    await _submitRollbackTransaction(
      startNew: startNew,
      isolationLevel: _env.isolationLevel,
    );
    await processSimpleRequest();
  }

  Future<void> _drainUntilDone() async {
    while (true) {
      final marker = await _nextTokenId();
      if (await _handleCommonToken(marker)) {
        if ((marker == tds.TDS_DONE_TOKEN ||
                marker == tds.TDS_DONEPROC_TOKEN ||
                marker == tds.TDS_DONEINPROC_TOKEN) &&
            (_doneFlags & tds.TDS_DONE_MORE_RESULTS) == 0) {
          return;
        }
        continue;
      }
      await _skipToken(marker);
    }
  }

  Future<bool> _handleCommonToken(int marker) async {
    switch (marker) {
      case tds.TDS_DONE_TOKEN:
      case tds.TDS_DONEPROC_TOKEN:
      case tds.TDS_DONEINPROC_TOKEN:
        await _processDone(marker);
        return true;
      case tds.TDS_ENVCHANGE_TOKEN:
        await _processEnvChange();
        return true;
      case tds.TDS_INFO_TOKEN:
      case tds.TDS_ERROR_TOKEN:
        _messages.add(await _processMessage(marker));
        return true;
      case tds.TDS_RETURNSTATUS_TOKEN:
        await _processReturnStatus();
        return true;
      case tds.TDS_PARAM_TOKEN:
        await _processReturnValue();
        return true;
      case tds.TDS7_RESULT_TOKEN:
        await _processResultToken();
        return true;
      case tds.TDS_ROW_TOKEN:
        await _processRowToken();
        return true;
      case tds.TDS_NBC_ROW_TOKEN:
        await _processNbcRowToken();
        return true;
      default:
        return false;
    }
  }

  Future<void> _processReturnStatus() async {
    _returnStatus = await _reader.getInt();
    _hasStatus = true;
    _trace('returnstatus', {'value': _returnStatus});
  }

  /// RETURNVALUE: the value of an OUTPUT parameter (or a UDF return value).
  Future<void> _processReturnValue() async {
    final ordinal = await _reader.getUSmallInt();
    final nameLength = await _reader.getByte();
    var name = nameLength > 0 ? await _reader.readUcs2(nameLength) : '';
    await _reader.getByte(); // status: 0x01 OUTPUT, 0x02 UDF return value
    tds.isTds72Plus(this)
        ? await _reader.getUInt()
        : await _reader.getUSmallInt(); // user type
    await _reader.getUSmallInt(); // flags
    final typeId = await _reader.getByte();
    final info = await _readTypeInfoPayload(typeId);
    final decoder = _decoder;
    final value = await _decodeSync((cursor) => decoder.decode(cursor, info));
    if (name.startsWith('@')) name = name.substring(1);
    _outputParameters[name.isEmpty ? '$ordinal' : name] = value;
    _trace('returnvalue', {'name': name, 'ordinal': ordinal});
  }

  Future<void> _processDone(int marker) async {
    final status = await _reader.getUSmallInt();
    await _reader.getUSmallInt();
    final hasMore = (status & tds.TDS_DONE_MORE_RESULTS) != 0;
    final wasCancelled = (status & tds.TDS_DONE_CANCELLED) != 0;
    final countValid = (status & tds.TDS_DONE_COUNT) != 0;
    final rows = tds.isTds72Plus(this)
        ? await _reader.getInt8()
        : await _reader.getInt();
    _doneFlags = status;
    if (countValid) {
      _rowsAffected = rows;
    } else if (_rowsAffected == tds.TDS_NO_COUNT) {
      _rowsAffected = tds.TDS_NO_COUNT;
    }
    _moreRows = false;
    if (wasCancelled && _cancelError != null && !_absorbingAttention) {
      final error = _cancelError!;
      _finishAttention();
      throw error;
    }
    _trace('done', {
      'marker': marker,
      'status': status,
      'rows': _rowsAffected,
      'more': hasMore,
      'cancelled': wasCancelled,
      'count_valid': countValid,
    });
    // The state is updated before throwing: the stream stays in sync and
    // the rest of the response can be drained.
    if (!_inCancel) {
      _state = hasMore ? tds.TDS_PENDING : tds.TDS_IDLE;
    }
    if ((status & tds.TDS_DONE_ERROR) != 0 && !wasCancelled && !_inCancel) {
      raiseDbException();
    }
  }

  Future<tds.Message> _processMessage(int marker) async {
    final size = await _reader.getSmallInt();
    final message = <String, dynamic>{
      'marker': marker,
      'msgno': await _reader.getInt(),
      'state': await _reader.getByte(),
      'severity': await _reader.getByte(),
      'sql_state': null,
      'priv_msg_type': marker == tds.TDS_INFO_TOKEN ? 0 : 1,
      'message': '',
      'server': '',
      'proc_name': '',
      'line_number': 0,
    };
    final textLen = await _reader.getSmallInt();
    message['message'] = await _reader.readUcs2(textLen);
    final serverNameLen = await _reader.getByte();
    message['server'] = await _reader.readUcs2(serverNameLen);
    final procNameLen = await _reader.getByte();
    message['proc_name'] = await _reader.readUcs2(procNameLen);
    final hasLongLineNumber = tds.isTds72Plus(this);
    final lineByteCount = hasLongLineNumber ? 4 : 2;
    message['line_number'] = hasLongLineNumber
        ? await _reader.getInt()
        : await _reader.getSmallInt();
    final consumed = 4 +
        1 +
        1 +
        2 +
        textLen * 2 +
        1 +
        serverNameLen * 2 +
        1 +
        procNameLen * 2 +
        lineByteCount;
    final remaining = size - consumed;
    if (remaining > 0) {
      await _reader.readBytes(remaining);
    }
    _trace('message', {
      'marker': marker,
      'msgno': message['msgno'],
      'severity': message['severity'],
      'state': message['state'],
      'line': message['line_number'],
      'text': message['message'],
    });
    return message;
  }

  Future<void> _processEnvChange() async {
    final size = await _reader.getSmallInt();
    final typeId = await _reader.getByte();
    final traceData = <String, Object?>{'type': typeId};
    switch (typeId) {
      case tds.TDS_ENV_SQLCOLLATION:
        final payload = await _reader.getByte();
        if (payload >= Collation.wire_size) {
          final bytes = await _reader.readBytes(Collation.wire_size);
          _collation = Collation.unpack(bytes);
          _connectionCollation = _collation;
          _onCollationChanged?.call(_collation);
          traceData['new'] = _collation?.toString();
          final extra = payload - Collation.wire_size;
          if (extra > 0) {
            await _reader.readBytes(extra);
          }
        } else {
          await _reader.readBytes(payload);
        }
        final oldLen = await _reader.getByte();
        if (oldLen > 0) {
          await _reader.readBytes(oldLen);
        }
        break;
      case tds.TDS_ENV_PACKSIZE:
        final newVal = await _reader.readUcs2(await _reader.getByte());
        await _reader.readUcs2(await _reader.getByte());
        final block = int.tryParse(newVal);
        if (block != null && block >= 512) {
          _writer.bufsize = block;
        }
        traceData['new'] = block ?? newVal;
        break;
      case tds.TDS_ENV_CHARSET:
        final newCharset = await _reader.readUcs2(await _reader.getByte());
        await _reader.readUcs2(await _reader.getByte());
        _env.charset = newCharset;
        traceData['new'] = newCharset;
        break;
      case tds.TDS_ENV_DB_MIRRORING_PARTNER:
        final partner = await _reader.readUcs2(await _reader.getByte());
        await _reader.readUcs2(await _reader.getByte());
        _env.mirroringPartner = partner;
        traceData['new'] = partner;
        break;
      case tds.TDS_ENV_LCID:
        final lcidStr = await _reader.readUcs2(await _reader.getByte());
        final lcid = int.tryParse(lcidStr);
        if (lcid != null) {
          _env.charset = lcid2charset(lcid);
        }
        traceData['new'] = lcid ?? lcidStr;
        final oldLcidLen = await _reader.getByte();
        if (oldLcidLen > 0) {
          await _reader.readUcs2(oldLcidLen);
        }
        break;
      case tds.TDS_ENV_UNICODE_DATA_SORT_COMP_FLAGS:
        final newFlags = await _reader.readUcs2(await _reader.getByte());
        final oldFlagsLen = await _reader.getByte();
        if (oldFlagsLen > 0) {
          await _reader.readUcs2(oldFlagsLen);
        }
        _onUnicodeSortFlags?.call(newFlags);
        traceData['new'] = newFlags;
        break;
      case tds.TDS_ENV_BEGINTRANS:
        final newSize = await _reader.getByte();
        int? txnValue;
        if (newSize == 8) {
          txnValue = await _reader.getUInt8();
        } else if (newSize > 0) {
          txnValue = _decodeLittleEndianInt(await _reader.readBytes(newSize));
        }
        final oldSize = await _reader.getByte();
        if (oldSize > 0) {
          await _reader.readBytes(oldSize);
        }
        if (txnValue != null) {
          _transactionId = txnValue;
          _onTransactionStateChange?.call(txnValue);
          traceData['new'] = txnValue;
        }
        break;
      case tds.TDS_ENV_COMMITTRANS:
      case tds.TDS_ENV_ROLLBACKTRANS:
        final newTxSize = await _reader.getByte();
        if (newTxSize > 0) {
          await _reader.readBytes(newTxSize);
        }
        final oldTxSize = await _reader.getByte();
        if (oldTxSize > 0) {
          await _reader.readBytes(oldTxSize);
        }
        _transactionId = 0;
        _onTransactionStateChange?.call(0);
        traceData['new'] = 0;
        break;
      case tds.TDS_ENV_DATABASE:
        final newDb = await _reader.readUcs2(await _reader.getByte());
        await _reader.readUcs2(await _reader.getByte());
        _env.database = newDb;
        traceData['new'] = newDb;
        break;
      case tds.TDS_ENV_LANG:
        final newLang = await _reader.readUcs2(await _reader.getByte());
        await _reader.readUcs2(await _reader.getByte());
        _env.language = newLang;
        traceData['new'] = newLang;
        break;
      case tds.TDS_ENV_ROUTING:
        await _reader.getUSmallInt();
        final protocol = await _reader.getByte();
        final protocolProperty = await _reader.getUSmallInt();
        final serverLen = await _reader.getUSmallInt();
        final serverName =
            serverLen > 0 ? await _reader.readUcs2(serverLen) : '';
        final routeInfo = <String, dynamic>{
          'protocol': protocol,
          'port': protocolProperty,
          'server': serverName,
        };
        _onRouteChange?.call(routeInfo);
        traceData
          ..['protocol'] = protocol
          ..['port'] = protocolProperty
          ..['server'] = serverName;
        final oldValueLen = await _reader.getUSmallInt();
        if (oldValueLen > 0) {
          await _reader.readBytes(oldValueLen);
        }
        break;
      case tds.TDS_ENV_RESET_COMPLETION_ACK:
        // RESETCONNECTION acknowledgement; carries no useful values.
        if (size > 1) await _reader.readBytes(size - 1);
        traceData['reset'] = true;
        break;
      default:
        final toSkip = size - 1;
        if (toSkip > 0) {
          await _reader.readBytes(toSkip);
        }
        traceData['unknown'] = true;
    }
    _trace('envchange', traceData);
  }

  Future<void> _skipToken(int marker) async {
    switch (marker) {
      case tds.TDS5_PARAMFMT2_TOKEN:
      case tds.TDS_LANGUAGE_TOKEN:
      case tds.TDS_ORDERBY2_TOKEN:
        final len32 = await _reader.getSmallInt();
        if (len32 > 0) {
          await _reader.readBytes(len32);
        }
        break;
      case tds.TDS_TABNAME_TOKEN:
      case tds.TDS_COLINFO_TOKEN:
      case tds.TDS_CAPABILITY_TOKEN:
      case tds.TDS_ORDERBY_TOKEN:
        final len = await _reader.getSmallInt();
        if (len > 0) {
          await _reader.readBytes(len);
        }
        break;
      default:
        throw tds.InterfaceException(
          'Unknown TDS token: $marker (0x${marker.toRadixString(16)})',
        );
    }
  }

  Future<void> _processResultToken() async {
    final columnCount = await _reader.getSmallInt();
    if (columnCount == -1) {
      return;
    }
    final results = tds.Results();
    results.columns = List.generate(columnCount, (_) => tds.Column());
    results.description = [];
    _results = results;
    _currentRow = List<dynamic>.filled(columnCount, null, growable: false);
    _rowsAffected = tds.TDS_NO_COUNT;
    _skippedToStatus = false;
    _hasStatus = false;
    _returnStatus = null;
    _moreRows = true;
    for (var i = 0; i < columnCount; i++) {
      await _readColumnMetadata(results.columns[i], results.description);
    }
    final columnNames =
        results.columns.map((col) => col.columnName).toList(growable: false);
    _rebuildRowFactory(columnNames: columnNames);
  }

  Future<void> _processRowToken() => _decodeRow(nullBitmap: false);

  Future<void> _processNbcRowToken() => _decodeRow(nullBitmap: true);

  ValueDecoder? _decoderCache;

  ValueDecoder get _decoder {
    final decoder =
        _decoderCache ??= ValueDecoder(bytesToUnicode: _bytesToUnicode);
    decoder.connectionCollation = _connectionCollation;
    return decoder;
  }

  /// Runs [body] synchronously over the current packet buffer. If the data
  /// runs out midway, rewinds, appends the next packet and retries.
  Future<T> _decodeSync<T>(T Function(ByteCursor cursor) body) async {
    while (true) {
      final cursor =
          ByteCursor(_reader.rawBuffer, _reader.position, _reader.limit);
      try {
        final value = body(cursor);
        _reader.position = cursor.pos;
        return value;
      } on NeedMoreData catch (missing) {
        final target = _reader.limit - _reader.position + missing.bytes;
        while (_reader.limit - _reader.position < target) {
          await _reader.appendNextPacket();
        }
      }
    }
  }

  Future<void> _decodeRow({required bool nullBitmap}) async {
    final metadata = _results;
    if (metadata == null) {
      _badStream(
          '${nullBitmap ? 'NBCROW' : 'ROW'} received before COLMETADATA');
    }
    final columns = metadata!.columns;
    final infos = _columnInfos(columns);
    final decoder = _decoder;
    final row = _currentRow;
    await _decodeSync((cursor) {
      Uint8List? bitmap;
      if (nullBitmap) bitmap = cursor.view((columns.length + 7) >> 3);
      for (var i = 0; i < infos.length; i++) {
        row[i] = bitmap != null && (bitmap[i >> 3] & (1 << (i & 7))) != 0
            ? null
            : decoder.decode(cursor, infos[i]);
      }
    });
    metadata.rowCount += 1;
    if (_traceHook != null) {
      _trace(
          nullBitmap ? 'nbcrow' : 'row', {'values': List<dynamic>.from(row)});
    }
    _bufferRowSnapshot();
  }

  List<TdsTypeInfo>? _cachedInfos;
  List<tds.Column>? _cachedInfosFor;

  List<TdsTypeInfo> _columnInfos(List<tds.Column> columns) {
    if (identical(columns, _cachedInfosFor)) return _cachedInfos!;
    final infos = <TdsTypeInfo>[];
    for (final column in columns) {
      final info = column.serializer;
      if (info is! TdsTypeInfo) {
        throw tds.InterfaceException(
            'Missing column metadata for ${column.columnName}');
      }
      infos.add(info);
    }
    _cachedInfosFor = columns;
    return _cachedInfos = infos;
  }

  /// Removes and returns the next ready row (after applying the
  /// [RowStrategy]).
  dynamic takeRow() {
    if (_rowBuffer.isEmpty) {
      return null;
    }
    return _rowBuffer.removeFirst();
  }

  /// Returns all available rows and clears the buffer.
  List<dynamic> takeAllRows() {
    if (_rowBuffer.isEmpty) {
      return const <dynamic>[];
    }
    final rows = List<dynamic>.from(_rowBuffer, growable: false);
    _rowBuffer.clear();
    return rows;
  }

  /// Clears the row buffer without returning the rows.
  void clearRowBuffer() => _rowBuffer.clear();

  void _resetResultsState({bool clearRowBuffer = false}) {
    if (clearRowBuffer) {
      _rowBuffer.clear();
    }
    _results = null;
    _currentRow = const <dynamic>[];
    _rowsAffected = tds.TDS_NO_COUNT;
    _moreRows = false;
    _skippedToStatus = false;
    _hasStatus = false;
    _returnStatus = null;
  }

  /// Consumes the rest of the pending response (rows, result sets and the
  /// final DONE), leaving the session ready for another command. Needed when
  /// a cursor is closed or replaced before reading everything.
  ///
  /// Server errors contained in that response belong to the abandoned
  /// command and are not rethrown here.
  Future<void> drainPending() async {
    while (_state != tds.TDS_IDLE && _state != tds.TDS_DEAD) {
      try {
        if (_reader.streamFinished()) {
          await beginResponse();
        }
        if (_results != null && _moreRows) {
          while (await nextRow()) {}
          continue;
        }
        await findResultOrDone();
      } on tds.MssqlCancelledException {
        // Cancellation of a response that is being discarded.
      } on tds.DatabaseException catch (error) {
        if (error.number == 0) rethrow;
      }
    }
    _rowBuffer.clear();
    _messages.clear();
    _orphanCancel = null;
  }

  Future<bool?> nextSet() async {
    _throwOrphanCancel();
    while (_moreRows && await nextRow()) {
      // Keep draining the current result set until DONE arrives.
    }
    if (_state == tds.TDS_IDLE) {
      return false;
    }
    if (await findResultOrDone()) {
      return true;
    }
    return null;
  }

  Future<bool> findResultOrDone() async {
    _throwOrphanCancel();
    _doneFlags = 0;
    while (true) {
      final marker = await _nextTokenId();
      if (marker == tds.TDS7_RESULT_TOKEN) {
        await _processResultToken();
        return true;
      }
      if (_isDoneToken(marker)) {
        await _processDone(marker);
        final hasMore = (_doneFlags & tds.TDS_DONE_MORE_RESULTS) != 0;
        if (!hasMore) {
          return false;
        }
        continue;
      }
      if (await _handleCommonToken(marker)) {
        continue;
      }
      await _skipToken(marker);
    }
  }

  Future<bool> nextRow() async {
    _throwOrphanCancel();
    if (_results == null) {
      throw tds.ProgrammingException(
        'The previous operation returned no results.',
      );
    }
    if (!_moreRows) {
      return false;
    }
    while (true) {
      final marker = await _nextTokenId();
      if (marker == tds.TDS_ROW_TOKEN) {
        await _processRowToken();
        return true;
      }
      if (marker == tds.TDS_NBC_ROW_TOKEN) {
        await _processNbcRowToken();
        return true;
      }
      if (_isDoneToken(marker)) {
        await _processDone(marker);
        return false;
      }
      if (await _handleCommonToken(marker)) {
        continue;
      }
      await _skipToken(marker);
    }
  }

  void _bufferRowSnapshot() {
    final hasResults = _results != null && _currentRow.isNotEmpty;
    if (!hasResults) {
      return;
    }
    final snapshot = List<dynamic>.from(_currentRow, growable: false);
    final materialized = _rowConvertor(snapshot);
    _rowBuffer.add(materialized);
  }

  Future<void> _readColumnMetadata(
    tds.Column column,
    List<List<dynamic>> description,
  ) async {
    column.columnUserType = tds.isTds72Plus(this)
        ? await _reader.getUInt()
        : await _reader.getUSmallInt();
    column.flags = await _reader.getUSmallInt();
    final typeId = await _reader.getByte();
    final typeInfo = await _readTypeInfoPayload(typeId);
    column.serializer = typeInfo;
    column.type = typeId;
    final nameLength = await _reader.getByte();
    column.columnName =
        nameLength > 0 ? await _reader.readUcs2(nameLength) : '';
    final nullable = (column.flags & tds.Column.fNullable) != 0;
    description.add([
      column.columnName,
      typeId,
      null,
      typeInfo.maxLength,
      typeInfo.precision,
      typeInfo.scale,
      nullable,
    ]);
  }

  Future<TdsTypeInfo> _readTypeInfoPayload(int typeId) async {
    switch (typeId) {
      case tds.BITTYPE:
        return const TdsTypeInfo(typeId: tds.BITTYPE, maxLength: 1);
      case tds.INT1TYPE:
        return const TdsTypeInfo(typeId: tds.INT1TYPE, maxLength: 1);
      case tds.INT2TYPE:
        return const TdsTypeInfo(typeId: tds.INT2TYPE, maxLength: 2);
      case tds.INT4TYPE:
        return const TdsTypeInfo(typeId: tds.INT4TYPE, maxLength: 4);
      case tds.INT8TYPE:
        return const TdsTypeInfo(typeId: tds.INT8TYPE, maxLength: 8);
      case tds.FLT4TYPE:
        return const TdsTypeInfo(typeId: tds.FLT4TYPE, maxLength: 4);
      case tds.FLT8TYPE:
        return const TdsTypeInfo(typeId: tds.FLT8TYPE, maxLength: 8);
      case tds.MONEYTYPE:
        return const TdsTypeInfo(typeId: tds.MONEYTYPE, maxLength: 8);
      case tds.MONEY4TYPE:
        return const TdsTypeInfo(typeId: tds.MONEY4TYPE, maxLength: 4);
      case tds.DATETIMETYPE:
        return const TdsTypeInfo(typeId: tds.DATETIMETYPE, maxLength: 8);
      case tds.DATETIM4TYPE:
        return const TdsTypeInfo(typeId: tds.DATETIM4TYPE, maxLength: 4);
      case tds.GUIDTYPE:
        return TdsTypeInfo(
            typeId: tds.GUIDTYPE, maxLength: await _reader.getByte());
      case tds.SSVARIANTTYPE:
        return TdsTypeInfo(
            typeId: tds.SSVARIANTTYPE, maxLength: await _reader.getInt());
      case tds.IMAGETYPE:
        final imageSize = await _reader.getInt();
        return TdsTypeInfo(
          typeId: tds.IMAGETYPE,
          maxLength: imageSize,
          schema: await _readMultipartIdentifier(),
        );
      case tds.DATENTYPE:
        return const TdsTypeInfo(typeId: tds.DATENTYPE, maxLength: 3);
      case tds.INTNTYPE:
      case tds.BITNTYPE:
      case tds.MONEYNTYPE:
      case tds.DATETIMNTYPE:
      case tds.FLTNTYPE:
        final length = await _reader.getByte();
        return TdsTypeInfo(typeId: typeId, maxLength: length);
      case tds.DECIMALNTYPE:
      case tds.NUMERICNTYPE:
        final storage = await _reader.getByte();
        final precision = await _reader.getByte();
        final scale = await _reader.getByte();
        return TdsTypeInfo(
          typeId: typeId,
          maxLength: storage,
          precision: precision,
          scale: scale,
        );
      case tds.BIGVARBINTYPE:
      case tds.BIGBINARYTYPE:
        final length = await _reader.getUSmallInt();
        return TdsTypeInfo(typeId: typeId, maxLength: length);
      case tds.SYBVARBINARY:
      case tds.BINARYTYPE:
        final byteLen = await _reader.getByte();
        return TdsTypeInfo(typeId: typeId, maxLength: byteLen);
      case tds.BIGVARCHRTYPE:
      case tds.BIGCHARTYPE:
        final length = await _reader.getUSmallInt();
        final collation = await _reader.getCollation();
        return TdsTypeInfo(
          typeId: typeId,
          maxLength: length,
          collation: collation,
        );
      case tds.SYBVARCHAR:
      case tds.SYBCHAR:
        final lenByte = await _reader.getByte();
        final collation = await _reader.getCollation();
        return TdsTypeInfo(
          typeId: typeId,
          maxLength: lenByte,
          collation: collation,
        );
      case tds.NVARCHARTYPE:
      case tds.NCHARTYPE:
        final length = await _reader.getUSmallInt();
        final collation = await _reader.getCollation();
        return TdsTypeInfo(
          typeId: typeId,
          maxLength: length,
          collation: collation,
        );
      case tds.TEXTTYPE:
      case tds.NTEXTTYPE:
        final sizeVal = await _reader.getInt();
        final collation = await _reader.getCollation();
        final parts = await _readMultipartIdentifier();
        return TdsTypeInfo(
          typeId: typeId,
          maxLength: sizeVal,
          collation: collation,
          schema: parts,
        );
      case tds.XMLTYPE:
        final hasSchema = await _reader.getByte();
        if (hasSchema == 0) {
          return const TdsTypeInfo(typeId: tds.XMLTYPE);
        }
        final dbName = await _reader.readUcs2(await _reader.getByte());
        final owner = await _reader.readUcs2(await _reader.getByte());
        final collection = await _reader.readUcs2(await _reader.getSmallInt());
        return TdsTypeInfo(
          typeId: typeId,
          schema: [dbName, owner, collection],
        );
      case tds.UDTTYPE:
        final maxByteSize = await _reader.getUSmallInt();
        final dbName = await _reader.readUcs2(await _reader.getByte());
        final schemaName = await _reader.readUcs2(await _reader.getByte());
        final typeName = await _reader.readUcs2(await _reader.getByte());
        final asmName = await _reader.readUcs2(await _reader.getSmallInt());
        return TdsTypeInfo(
          typeId: typeId,
          maxLength: maxByteSize,
          schema: [dbName, schemaName, typeName, asmName],
        );
      case tds.TIMENTYPE:
      case tds.DATETIME2NTYPE:
      case tds.DATETIMEOFFSETNTYPE:
        final precision = await _reader.getByte();
        return TdsTypeInfo(typeId: typeId, precision: precision);
      default:
        throw tds.NotSupportedException(
          'TYPE_INFO for type $typeId is not supported yet',
        );
    }
  }

  Future<List<String>> _readMultipartIdentifier() async {
    if (!tds.isTds72Plus(this)) {
      final len = await _reader.getSmallInt();
      if (len <= 0) {
        return const <String>[];
      }
      return <String>[await _reader.readUcs2(len)];
    }
    final parts = <String>[];
    final count = await _reader.getByte();
    for (var i = 0; i < count; i++) {
      final len = await _reader.getSmallInt();
      parts.add(len > 0 ? await _reader.readUcs2(len) : '');
    }
    return parts;
  }

  @override
  void updateTypeSystem(
    SerializerFactory factory, {
    Collation? collation,
    bool? bytesToUnicode,
  }) {
    _typeFactory = factory;
    if (collation != null) {
      _connectionCollation = collation;
      _collation ??= collation;
    }
    if (bytesToUnicode != null) {
      _bytesToUnicode = bytesToUnicode;
    }
  }

  @override
  void updateRowStrategy(RowStrategy strategy) {
    _setRowStrategy(strategy);
  }

  Future<void> _submitBeginTransaction(int isolationLevel) async {
    if (_state != tds.TDS_IDLE) {
      throw tds.InterfaceException(
        'An operation is already pending on the current session.',
      );
    }
    if (!tds.isTds72Plus(this)) {
      await submitPlainQuery('BEGIN TRANSACTION');
      _transactionId = 1;
      _onTransactionStateChange?.call(_transactionId);
      return;
    }
    _resetResultsState(clearRowBuffer: true);
    _messages.clear();
    _writer.beginPacket(tds.PacketType.TRANS);
    await _startQuery();
    final payload = ByteData(4)
      ..setUint16(0, _tmBeginXact, Endian.little)
      ..setUint8(2, isolationLevel)
      ..setUint8(3, 0);
    await _writer.write(payload.buffer.asUint8List());
    await _writer.flush();
    _state = tds.TDS_PENDING;
    _trace('tran.begin', {'isolation': isolationLevel});
  }

  Future<void> _submitCommitTransaction({
    required bool startNew,
    required int isolationLevel,
  }) async {
    if (_state != tds.TDS_IDLE) {
      throw tds.InterfaceException(
        'An operation is already pending on the current session.',
      );
    }
    if (!tds.isTds72Plus(this)) {
      final sql = startNew
          ? 'IF @@TRANCOUNT > 0 COMMIT BEGIN TRANSACTION'
          : 'IF @@TRANCOUNT > 0 COMMIT';
      await submitPlainQuery(sql);
      _transactionId = startNew ? 1 : 0;
      _onTransactionStateChange?.call(_transactionId);
      return;
    }
    _resetResultsState(clearRowBuffer: true);
    _messages.clear();
    _writer.beginPacket(tds.PacketType.TRANS);
    await _startQuery();
    final flags = startNew ? _tmFlagChain : 0;
    final payload = ByteData(4)
      ..setUint16(0, _tmCommitXact, Endian.little)
      ..setUint8(2, 0)
      ..setUint8(3, flags);
    await _writer.write(payload.buffer.asUint8List());
    if (startNew) {
      final continuation = ByteData(2)
        ..setUint8(0, isolationLevel)
        ..setUint8(1, 0);
      await _writer.write(continuation.buffer.asUint8List());
    }
    await _writer.flush();
    _state = tds.TDS_PENDING;
    _trace('tran.commit', {'chain': startNew, 'flags': flags});
  }

  Future<void> _submitRollbackTransaction({
    required bool startNew,
    required int isolationLevel,
  }) async {
    if (_state != tds.TDS_IDLE) {
      throw tds.InterfaceException(
        'An operation is already pending on the current session.',
      );
    }
    if (!tds.isTds72Plus(this)) {
      final sql = startNew
          ? 'IF @@TRANCOUNT > 0 ROLLBACK BEGIN TRANSACTION'
          : 'IF @@TRANCOUNT > 0 ROLLBACK';
      await submitPlainQuery(sql);
      _transactionId = startNew ? 1 : 0;
      _onTransactionStateChange?.call(_transactionId);
      return;
    }
    _resetResultsState(clearRowBuffer: true);
    _messages.clear();
    _writer.beginPacket(tds.PacketType.TRANS);
    await _startQuery();
    final flags = startNew ? _tmFlagChain : 0;
    final payload = ByteData(4)
      ..setUint16(0, _tmRollbackXact, Endian.little)
      ..setUint8(2, 0)
      ..setUint8(3, flags);
    await _writer.write(payload.buffer.asUint8List());
    if (startNew) {
      final continuation = ByteData(2)
        ..setUint8(0, isolationLevel)
        ..setUint8(1, 0);
      await _writer.write(continuation.buffer.asUint8List());
    }
    await _writer.flush();
    _state = tds.TDS_PENDING;
    _trace('tran.rollback', {'chain': startNew, 'flags': flags});
  }

  Future<void> _startQuery() async {
    final data = ByteData(22)
      ..setUint32(0, 0x16, Endian.little)
      ..setUint32(4, 0x12, Endian.little)
      ..setUint16(8, 2, Endian.little)
      ..setUint64(10, _transactionId, Endian.little)
      ..setUint32(18, 1, Endian.little);
    await _writer.write(data.buffer.asUint8List());
    _trace('query.start', {'tran': _env.isolationLevel});
  }

  int _decodeLittleEndianInt(List<int> bytes) {
    var result = 0;
    for (var i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | (bytes[i] & 0xFF);
    }
    return result;
  }

  void _setRowStrategy(RowStrategy strategy, [List<String>? columnNames]) {
    _rowStrategy = strategy;
    _rebuildRowFactory(columnNames: columnNames);
  }

  void _rebuildRowFactory({List<String>? columnNames}) {
    final names = columnNames ??
        (_results?.columns.map((c) => c.columnName).toList() ??
            const <String>[]);
    _rowConvertor = _rowStrategy(names);
    _rowConvertor(const <dynamic>[]);
  }

  bool _isDoneToken(int marker) {
    return marker == tds.TDS_DONE_TOKEN ||
        marker == tds.TDS_DONEPROC_TOKEN ||
        marker == tds.TDS_DONEINPROC_TOKEN;
  }

  Future<int> _nextTokenId() async {
    _progress++;
    if (_onDeadline != null) _checkDeadline();
    if (_cancelError != null && _attentionSent && !_absorbingAttention) {
      await _absorbAttention();
    }
    _state = tds.TDS_READING;
    try {
      final marker = await _reader.getByte();
      _trace('token', {
        'marker': marker,
        'name': _tokenNames[marker] ?? '0x${marker.toRadixString(16)}',
      });
      return marker;
    } on tds.TimeoutError {
      _state = tds.TDS_PENDING;
      rethrow;
    }
  }

  void _badStream(String message) {
    close();
    throw tds.InterfaceException(message);
  }

  void close() => _transport.close();

  @override
  tds.AuthProtocol? get authentication => _authentication;

  @override
  set authentication(tds.AuthProtocol? value) {
    _authentication = value;
  }

  @override
  int get state => _state;

  @override
  set state(int value) {
    _state = value;
  }

  @override
  int get tdsVersion => _tdsVersion;

  set tdsVersion(int value) {
    _tdsVersion = value;
  }
}

const Map<int, String> _tokenNames = {
  tds.TDS_DONE_TOKEN: 'DONE',
  tds.TDS_DONEPROC_TOKEN: 'DONEPROC',
  tds.TDS_DONEINPROC_TOKEN: 'DONEINPROC',
  tds.TDS_ENVCHANGE_TOKEN: 'ENVCHANGE',
  tds.TDS_ERROR_TOKEN: 'ERROR',
  tds.TDS_INFO_TOKEN: 'INFO',
  tds.TDS_RETURNSTATUS_TOKEN: 'RETURNSTATUS',
  tds.TDS_ROW_TOKEN: 'ROW',
  tds.TDS_NBC_ROW_TOKEN: 'NBCROW',
  tds.TDS_ORDERBY_TOKEN: 'ORDERBY',
  tds.TDS_PARAM_TOKEN: 'RETURNVALUE',
  tds.TDS_TABNAME_TOKEN: 'TABNAME',
  tds.TDS_COLINFO_TOKEN: 'COLINFO',
  tds.TDS_AUTH_TOKEN: 'AUTH',
  tds.TDS_CAPABILITY_TOKEN: 'CAPABILITY',
  tds.TDS7_RESULT_TOKEN: 'COLMETADATA',
};

// -----------------------------------------------------------------------------
// Mid-stream TLS adapter
// -----------------------------------------------------------------------------

/// Adapter that implements [tls_channel.TdsSessionForTls] for
/// [AsyncTdsSession].
///
/// Gives the TLS module access to the session's transport, reader and writer
/// to perform the mid-stream TLS handshake.
class _AsyncTdsSessionTlsAdapter implements tls_channel.TdsSessionForTls {
  _AsyncTdsSessionTlsAdapter(this._session);

  final AsyncTdsSession _session;

  @override
  tds.AsyncTransportProtocol get currentTransport => _session._transport;

  @override
  tls_channel.TdsWriterForTls get writer =>
      _AsyncTdsWriterTlsAdapter(_session._writer);

  @override
  tls_channel.TdsReaderForTls get reader =>
      _AsyncTdsReaderTlsAdapter(_session._reader);

  @override
  void replaceTransport(tds.AsyncTransportProtocol newTransport) {
    // Update the transport on the reader and writer.
    _session._reader.setTransport(newTransport);
    _session._writer.setTransport(newTransport);
  }
}

/// Writer adapter for TLS.
class _AsyncTdsWriterTlsAdapter implements tls_channel.TdsWriterForTls {
  _AsyncTdsWriterTlsAdapter(this._writer);

  final AsyncTdsWriter _writer;

  @override
  void beginPacket(int packetType) => _writer.beginPacket(packetType);

  @override
  Future<void> write(List<int> data) => _writer.write(Uint8List.fromList(data));

  @override
  Future<void> flush() => _writer.flush();

  @override
  tds.AsyncTransportProtocol get transport => _writer.transport;

  @override
  set transport(tds.AsyncTransportProtocol value) =>
      _writer.setTransport(value);
}

/// Reader adapter for TLS.
class _AsyncTdsReaderTlsAdapter implements tls_channel.TdsReaderForTls {
  _AsyncTdsReaderTlsAdapter(this._reader);

  final AsyncTdsReader _reader;

  @override
  Future<ResponseMetadata> beginResponse() => _reader.beginResponse();

  @override
  Future<Uint8List> recv(int size) => _reader.recv(size);

  @override
  bool streamFinished() => _reader.streamFinished();

  @override
  tds.AsyncTransportProtocol get transport => _reader.transport;

  @override
  set transport(tds.AsyncTransportProtocol value) =>
      _reader.setTransport(value);
}
