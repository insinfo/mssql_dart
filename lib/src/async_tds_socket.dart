import 'async_tds_session.dart';
import 'collate.dart';
import 'row_strategies.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'tds_types.dart';

class AsyncTdsSocket {
  AsyncTdsSocket({
    required tds.AsyncTransportProtocol transport,
    required tds.TdsLogin login,
    AsyncSessionBuilder? sessionBuilder,
    TzInfoFactory? tzinfoFactory,
    RowStrategy? rowStrategy,
    Object? useTz,
    bool autocommit = false,
    int isolationLevel = 0,
    SessionTraceHook? traceHook,
  })  : _transport = transport,
        _login = login,
        _sessionBuilder = sessionBuilder ?? defaultAsyncSessionBuilder,
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
      AsyncSessionBuildContext(
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

  final tds.AsyncTransportProtocol _transport;
  final tds.TdsLogin _login;
  final AsyncSessionBuilder _sessionBuilder;
  final TzInfoFactory? _tzinfoFactory;
  RowStrategy _rowStrategy;

  late AsyncSessionLink _mainSession;

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

  AsyncSessionLink get mainSession => _mainSession;
  bool get isConnected => _isConnected;
  bool get marsEnabled => _marsEnabled;

  Future<tds.Route?> login() async {
    if (_isConnected) {
      return route;
    }
    if (tds.isTds71Plus(_mainSession)) {
      await _mainSession.sendPrelogin(_login);
      await _mainSession.processPrelogin(_login);
    }
    await _mainSession.sendLogin(_login);
    await _mainSession.beginResponse();
    final ok = await _mainSession.processLoginTokens();
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
      await _mainSession.submitPlainQuery(sql);
      await _mainSession.processSimpleRequest();
    }
    return route;
  }

  Future<void> close() async {
    _isConnected = false;
    await _transport.close();
    _marsManager = null;
    _mainSession.state = tds.TDS_DEAD;
    final auth = _mainSession.authentication;
    auth?.close();
    _mainSession.authentication = null;
  }

  Future<void> cancel() {
    return _mainSession.cancel();
  }

  void closeAllMarsSessions() {
    if (_marsManager != null) {
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
