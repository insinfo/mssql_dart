import 'tds_base.dart' as tds;
import 'tds_types.dart';

/// Abstração usada para construir sessões TDS reais quando o transporte é criado.
typedef SessionBuilder = SessionLink Function(SessionBuildContext context);

/// Contexto passado para um [SessionBuilder].
class SessionBuildContext {
  final tds.TransportProtocol transport;
  final int bufsize;
  final tds.TdsEnv env;
  final TzInfoFactory? tzinfoFactory;
  final dynamic rowStrategy;

  const SessionBuildContext({
    required this.transport,
    required this.bufsize,
    required this.env,
    this.tzinfoFactory,
    this.rowStrategy,
  });
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
  void beginResponse();
  bool processLoginTokens();
  void raiseDbException();
  void submitPlainQuery(String sql);
  void processSimpleRequest();
  tds.AuthProtocol? get authentication;
  set authentication(tds.AuthProtocol? value);
  int get state;
  set state(int value);
}
