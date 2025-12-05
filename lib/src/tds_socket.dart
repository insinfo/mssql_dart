import 'dart:io';
import 'dart:typed_data';

import 'collate.dart';
import 'row_strategies.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'tds_session.dart';
import 'tds_types.dart';

/// Transporte síncrono baseado em `RawSynchronousSocket`, com suporte a upgrade
/// futuro para TLS conforme `pytds.tls`.
class SocketTransport implements tds.TransportProtocol {
  SocketTransport._(this._socket, {required this.description})
      : _connected = true;

  factory SocketTransport.connectSync(
    String host,
    int port, {
    Duration? timeout,
    String? description,
  }) {
    try {
      final raw = RawSynchronousSocket.connectSync(host, port);
      final transport = SocketTransport._(
        raw,
        description: description ?? '$host:$port',
      );
      transport._timeoutSeconds = timeout?.inSeconds.toDouble();
      transport._host = host;
      transport._port = port;
      return transport;
    } on SocketException catch (err) {
      throw tds.OperationalError(
          'Falha ao conectar a $host:$port: ${err.message}');
    }
  }

  final String description;
  RawSynchronousSocket? _socket;
  bool _connected;
  double? _timeoutSeconds;
  String? _host;
  int? _port;

  RawSynchronousSocket get _rawSocket {
    final socket = _socket;
    if (!_connected || socket == null) {
      throw tds.ClosedConnectionError();
    }
    return socket;
  }

  @override
  bool isConnected() => _connected;

  @override
  void close() {
    _connected = false;
    final socket = _socket;
    _socket = null;
    try {
      socket?.closeSync();
    } on SocketException {
      // Ignorado: já estamos fechando.
    }
  }

  @override
  double? get timeout => _timeoutSeconds;

  @override
  set timeout(double? value) {
    _timeoutSeconds = value;
  }

  /// Expõe o host remoto associado (útil para validação de TLS).
  String? get host => _host;
  int? get port => _port;

  @override
  void sendall(List<int> buf, {int flags = 0}) {
    if (buf.isEmpty) {
      return;
    }
    final socket = _rawSocket;
    final data = buf is Uint8List ? buf : Uint8List.fromList(buf);
    var offset = 0;
    while (offset < data.length) {
      final end = data.length;
      try {
        socket.writeFromSync(data, offset, end);
      } on SocketException catch (err) {
        _connected = false;
        throw tds.OperationalError('Erro ao enviar dados: ${err.message}');
      }
      offset = end;
    }
  }

  @override
  List<int> recv(int size) {
    if (size <= 0) {
      return const <int>[];
    }
    final socket = _rawSocket;
    try {
      final chunk = socket.readSync(size);
      if (chunk == null || chunk.isEmpty) {
        _connected = false;
        return const <int>[];
      }
      return Uint8List.fromList(chunk);
    } on SocketException {
      _connected = false;
      throw tds.ClosedConnectionError();
    }
  }

  @override
  int recvInto(ByteBuffer buf, {int size = 0, int flags = 0}) {
    final target = buf.asUint8List();
    final toFill = (size <= 0 || size > target.length) ? target.length : size;
    if (toFill == 0) {
      return 0;
    }
    final socket = _rawSocket;
    try {
      final read = socket.readIntoSync(target, 0, toFill);
      if (read == 0) {
        _connected = false;
      }
      return read;
    } on SocketException {
      _connected = false;
      throw tds.ClosedConnectionError();
    }
  }

  /// Permite substituir o socket bruto (por exemplo, após handshake TLS).
  void replaceSocket(RawSynchronousSocket socket, {bool markSecure = false}) {
    _socket = socket;
    _connected = true;
    _secure = markSecure;
  }

  bool get isSecure => _secure;
  bool _secure = false;
}

/// Responsável por coordenar o login e manter o estado raiz da conexão.
class TdsSocket {
  TdsSocket({
    required tds.TransportProtocol transport,
    required tds.TdsLogin login,
    SessionBuilder? sessionBuilder,
    TzInfoFactory? tzinfoFactory,
    RowStrategy? rowStrategy,
    Object? useTz,
    bool autocommit = false,
    int isolationLevel = 0,
    SessionTraceHook? traceHook,
  })  : _transport = transport,
        _login = login,
        _sessionBuilder = sessionBuilder ?? defaultSessionBuilder,
        _tzinfoFactory = tzinfoFactory,
        _rowStrategy = rowStrategy ?? defaultRowStrategy,
        useTz = useTz,
        env = tds.TdsEnv() {
    env.autocommit = autocommit;
    env.isolationLevel = isolationLevel;
    bufsize = login.blocksize;
    tdsVersion = login.tdsVersion;
    queryTimeout = login.queryTimeout;
    _marsEnabled = login.useMars;
    typeFactory = SerializerFactory(tdsVersion);
    _rebuildTypeInferrer();
    _mainSession = _sessionBuilder(
      SessionBuildContext(
        transport: _transport,
        bufsize: 4096,
        env: env,
        typeFactory: typeFactory,
        collation: collation,
        bytesToUnicode: login.bytesToUnicode,
        tzinfoFactory: _tzinfoFactory,
        rowStrategy: _rowStrategy,
        onCollationChanged: _handleCollationChange,
        onTransactionStateChange: _handleTransactionStateChange,
        onRouteChange: _handleRouteChange,
        onUnicodeSortFlags: _handleUnicodeSortFlags,
        traceHook: traceHook,
      ),
    );
    _mainSession.updateTypeSystem(
      typeFactory,
      collation: collation,
      bytesToUnicode: login.bytesToUnicode,
    );
    _mainSession.updateRowStrategy(_rowStrategy);
  }

  final tds.TransportProtocol _transport;
  final tds.TdsLogin _login;
  final SessionBuilder _sessionBuilder;
  final TzInfoFactory? _tzinfoFactory;
  RowStrategy _rowStrategy;

  late SessionLink _mainSession;

  final tds.TdsEnv env;
  Collation? collation;
  late SerializerFactory typeFactory;
  late TdsTypeInferrer typeInferrer;
  TzInfoFactory? get tzinfoFactory => _tzinfoFactory;
  Object? useTz;
  int bufsize = 4096;
  int tds72Transaction = 0;
  late int tdsVersion;
  bool _isConnected = false;
  bool _marsEnabled = false;
  Object? _marsManager;
  tds.Route? route;
  String? unicodeSortFlags;
  double? queryTimeout;
  List<int> serverLibraryVersion = const [0, 0];
  String productName = '';
  int productVersion = 0;

  RowStrategy get rowStrategy => _rowStrategy;
  set rowStrategy(RowStrategy strategy) {
    _rowStrategy = strategy;
    _mainSession.updateRowStrategy(strategy);
  }

  bool get hasBufferedRows => _mainSession.hasBufferedRows;
  int get bufferedRowCount => _mainSession.bufferedRowCount;
  dynamic takeRow() => _mainSession.takeRow();
  List<dynamic> takeAllRows() => _mainSession.takeAllRows();
  void clearRowBuffer() => _mainSession.clearRowBuffer();

  SessionLink get mainSession => _mainSession;
  bool get isConnected => _isConnected;
  bool get marsEnabled => _marsEnabled;

  tds.Route? login() {
    if (_isConnected) {
      return route;
    }
    if (_login.encFlag != tds.PreLoginEnc.ENCRYPT_NOT_SUP) {
      throw tds.NotSupportedError(
        'Conexões síncronas ainda não suportam TLS/Encrypt opções. Use connectAsync para servidores que exigem criptografia.',
      );
    }
    if (tds.isTds71Plus(_mainSession)) {
      _mainSession.sendPrelogin(_login);
      _mainSession.processPrelogin(_login);
    }
    _mainSession.sendLogin(_login);
    _mainSession.beginResponse();
    final ok = _mainSession.processLoginTokens();
    if (!ok) {
      _mainSession.raiseDbException();
    }
    _syncSessionBuffers();
    _refreshTypes();
    if (_marsEnabled) {
      throw UnimplementedError('MARS ainda não foi portado para Dart');
    }
    _isConnected = true;
    if (_login.database.isNotEmpty && env.database != _login.database) {
      final sql = 'use ' + tds.tdsQuoteId(_login.database);
      _mainSession.submitPlainQuery(sql);
      _mainSession.processSimpleRequest();
    }
    return route;
  }

  void close() {
    _isConnected = false;
    _transport.close();
    _marsManager = null;
    _mainSession.state = tds.TDS_DEAD;
    final auth = _mainSession.authentication;
    auth?.close();
    _mainSession.authentication = null;
  }

  void cancel() {
    _mainSession.cancel();
  }

  void closeAllMarsSessions() {
    if (_marsManager != null) {
      // TODO: implementar quando o SmpManager for portado
      throw UnimplementedError('SmpManager ainda não foi portado');
    }
  }

  void _syncSessionBuffers() {
    final writerSize = _mainSession.writerBufferSize;
    final readerSize = _mainSession.readerBlockSize;
    if (writerSize != readerSize) {
      _mainSession.setReaderBlockSize(writerSize);
    }
  }

  void _rebuildTypeInferrer({Collation? overrideCollation}) {
    if (overrideCollation != null) {
      collation = overrideCollation;
    }
    final effectiveCollation =
        (overrideCollation ?? collation) ?? raw_collation;
    typeInferrer = TdsTypeInferrer(
      typeFactory: typeFactory,
      collation: effectiveCollation,
      bytesToUnicode: _login.bytesToUnicode,
      allowTz: useTz == null,
    );
  }

  void _handleCollationChange(Collation? newCollation) {
    _rebuildTypeInferrer(overrideCollation: newCollation);
  }

  void _handleTransactionStateChange(int newTransactionId) {
    tds72Transaction = newTransactionId;
  }

  void _handleRouteChange(tds.Route routeInfo) {
    route = routeInfo;
  }

  void _handleUnicodeSortFlags(String flags) {
    unicodeSortFlags = flags;
  }

  void _refreshTypes() {
    typeFactory = SerializerFactory(tdsVersion);
    _rebuildTypeInferrer();
    _mainSession.updateTypeSystem(
      typeFactory,
      collation: collation,
      bytesToUnicode: _login.bytesToUnicode,
    );
  }
}
