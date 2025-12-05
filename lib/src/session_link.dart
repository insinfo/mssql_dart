import 'collate.dart';
import 'row_strategies.dart';
import 'tds_base.dart' as tds;
import 'tds_reader.dart';
import 'tds_types.dart';

/// Abstração usada para construir sessões TDS reais quando o transporte é criado.
typedef SessionBuilder = SessionLink Function(SessionBuildContext context);
typedef AsyncSessionBuilder = AsyncSessionLink Function(
  AsyncSessionBuildContext context,
);

/// Função chamada para cada evento relevante da sessão (útil para depuração).
typedef SessionTraceHook = void Function(
  String event,
  Map<String, Object?> payload,
);

/// Contexto passado para um [SessionBuilder].
class SessionBuildContext {
  final tds.TransportProtocol transport;
  final int bufsize;
  final tds.TdsEnv env;
  final TzInfoFactory? tzinfoFactory;
  final RowStrategy rowStrategy;
  final SerializerFactory typeFactory;
  final Collation? collation;
  final bool bytesToUnicode;
  final void Function(Collation?)? onCollationChanged;
  final void Function(int newTransactionId)? onTransactionStateChange;
  final void Function(tds.Route route)? onRouteChange;
  final void Function(String flags)? onUnicodeSortFlags;
  final SessionTraceHook? traceHook;

  SessionBuildContext({
    required this.transport,
    required this.bufsize,
    required this.env,
    required this.typeFactory,
    this.collation,
    this.bytesToUnicode = true,
    this.tzinfoFactory,
    RowStrategy? rowStrategy,
    this.onCollationChanged,
    this.onTransactionStateChange,
    this.onRouteChange,
    this.onUnicodeSortFlags,
    this.traceHook,
  }) : rowStrategy = rowStrategy ?? defaultRowStrategy;
}

class AsyncSessionBuildContext {
  final tds.AsyncTransportProtocol transport;
  final int bufsize;
  final tds.TdsEnv env;
  final TzInfoFactory? tzinfoFactory;
  final RowStrategy rowStrategy;
  final SerializerFactory typeFactory;
  final Collation? collation;
  final bool bytesToUnicode;
  final void Function(Collation?)? onCollationChanged;
  final void Function(int newTransactionId)? onTransactionStateChange;
  final void Function(tds.Route route)? onRouteChange;
  final void Function(String flags)? onUnicodeSortFlags;
  final SessionTraceHook? traceHook;

  AsyncSessionBuildContext({
    required this.transport,
    required this.bufsize,
    required this.env,
    required this.typeFactory,
    this.collation,
    this.bytesToUnicode = true,
    this.tzinfoFactory,
    RowStrategy? rowStrategy,
    this.onCollationChanged,
    this.onTransactionStateChange,
    this.onRouteChange,
    this.onUnicodeSortFlags,
    this.traceHook,
  }) : rowStrategy = rowStrategy ?? defaultRowStrategy;
}

/// Interface mínima que o `_TdsSocket` precisa da sessão enquanto o restante do
/// port ainda não está disponível.
abstract class SessionLink extends tds.TdsSessionContract {
  tds.TransportProtocol get transport;
  int get writerBufferSize;
  int get readerBlockSize;
  void setReaderBlockSize(int size);
  void sendPrelogin(tds.TdsLogin login);
  void processPrelogin(tds.TdsLogin login);
  void sendLogin(tds.TdsLogin login);
  ResponseMetadata beginResponse();
  bool processLoginTokens();
  void raiseDbException();
  void submitPlainQuery(String sql);
  void processSimpleRequest();
  void updateTypeSystem(
    SerializerFactory factory, {
    Collation? collation,
    bool? bytesToUnicode,
  });
  void updateRowStrategy(RowStrategy strategy);
  tds.AuthProtocol? get authentication;
  set authentication(tds.AuthProtocol? value);
  int get state;
  set state(int value);
}

abstract class AsyncSessionLink extends tds.TdsSessionContract {
  tds.AsyncTransportProtocol get transport;
  int get writerBufferSize;
  int get readerBlockSize;
  void setReaderBlockSize(int size);
  Future<void> sendPrelogin(tds.TdsLogin login);
  Future<void> processPrelogin(tds.TdsLogin login);
  Future<void> sendLogin(tds.TdsLogin login);
  Future<ResponseMetadata> beginResponse();
  Future<bool> processLoginTokens();
  void raiseDbException();
  Future<void> submitPlainQuery(String sql);
  Future<void> processSimpleRequest();
  void updateTypeSystem(
    SerializerFactory factory, {
    Collation? collation,
    bool? bytesToUnicode,
  });
  void updateRowStrategy(RowStrategy strategy);
  tds.AuthProtocol? get authentication;
  set authentication(tds.AuthProtocol? value);
  int get state;
  set state(int value);
}
