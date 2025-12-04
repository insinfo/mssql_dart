import 'dart:typed_data';

import 'collate.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'tds_session.dart';
import 'tds_types.dart';

/// Placeholder de transporte. A implementação real ainda precisa de um backend
/// síncrono para sockets/TLS em Dart.
class SocketTransport implements tds.TransportProtocol {
  SocketTransport({this.description = 'uninitialized'});

  final String description;
  bool _connected = false;
  double? _timeoutSeconds;

  static SocketTransport connectSync(String host, int port, {Duration? timeout}) {
    final transport = SocketTransport(description: '$host:$port');
    transport._connected = true;
    transport._timeoutSeconds = timeout?.inSeconds.toDouble();
    return transport;
  }

  @override
  bool isConnected() => _connected;

  @override
  void close() {
    _connected = false;
  }

  @override
  double? get timeout => _timeoutSeconds;

  @override
  set timeout(double? value) {
    _timeoutSeconds = value;
  }

  @override
  void sendall(List<int> buf, {int flags = 0}) =>
      _throwUnimplemented('sendall');

  @override
  List<int> recv(int size) => _throwUnimplemented('recv');

  @override
  int recvInto(ByteBuffer buf, {int size = 0, int flags = 0}) =>
      _throwUnimplemented('recvInto');

  Never _throwUnimplemented(String method) {
    throw UnimplementedError(
      'SocketTransport.$method ainda não foi portado para Dart (backend real pendente)',
    );
  }
}

/// Responsável por coordenar o login e manter o estado raiz da conexão.
class TdsSocket {
  TdsSocket({
    required tds.TransportProtocol transport,
    required tds.TdsLogin login,
    SessionBuilder? sessionBuilder,
    TzInfoFactory? tzinfoFactory,
    dynamic rowStrategy,
    Object? useTz,
    bool autocommit = false,
    int isolationLevel = 0,
    })  : _transport = transport,
      _login = login,
      _sessionBuilder = sessionBuilder ?? defaultSessionBuilder,
        _tzinfoFactory = tzinfoFactory,
        _rowStrategy = rowStrategy,
        useTz = useTz,
        env = tds.TdsEnv() {
    env.autocommit = autocommit;
    env.isolationLevel = isolationLevel;
    bufsize = login.blocksize;
    tdsVersion = login.tdsVersion;
    queryTimeout = login.queryTimeout;
    _marsEnabled = login.useMars;
    typeFactory = SerializerFactory(tdsVersion);
    typeInferrer = TdsTypeInferrer(
      typeFactory: typeFactory,
      collation: collation ?? raw_collation,
      bytesToUnicode: login.bytesToUnicode,
      allowTz: useTz == null,
    );
    _mainSession = _sessionBuilder(
      SessionBuildContext(
        transport: _transport,
        bufsize: 4096,
        env: env,
        tzinfoFactory: _tzinfoFactory,
        rowStrategy: _rowStrategy,
      ),
    );
  }

  final tds.TransportProtocol _transport;
  final tds.TdsLogin _login;
  final SessionBuilder _sessionBuilder;
  final TzInfoFactory? _tzinfoFactory;
  final dynamic _rowStrategy;

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
  double? queryTimeout;
  List<int> serverLibraryVersion = const [0, 0];
  String productName = '';
  int productVersion = 0;

  SessionLink get mainSession => _mainSession;
  bool get isConnected => _isConnected;
  bool get marsEnabled => _marsEnabled;

  tds.Route? login() {
    if (_isConnected) {
      return route;
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

  void _refreshTypes() {
    typeFactory = SerializerFactory(tdsVersion);
    typeInferrer = TdsTypeInferrer(
      typeFactory: typeFactory,
      collation: collation ?? raw_collation,
      bytesToUnicode: _login.bytesToUnicode,
      allowTz: useTz == null,
    );
  }
}
