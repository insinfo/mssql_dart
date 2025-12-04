import 'tds_base.dart' as tds;
import 'tds_reader.dart';
import 'tds_writer.dart';
import 'session_link.dart';
import 'tds_types.dart';

/// Builder padrão usado enquanto o restante do port não disponibiliza uma
/// sessão completa.
final SessionBuilder defaultSessionBuilder =
    (context) => TdsSession.fromContext(context);

/// Stub inicial para `_TdsSession`. Neste estágio apenas define a estrutura e os
/// pontos de integração exigidos por `TdsSocket`.
class TdsSession implements SessionLink, tds.TdsSessionContract {
  TdsSession({
    required tds.TransportProtocol transport,
    required tds.TdsEnv env,
    required int bufsize,
    this.tzinfoFactory,
    this.rowStrategy,
  })  : _transport = transport,
        _env = env {
    _reader = TdsReader(
      transport: transport,
      session: this,
      bufsize: bufsize,
    );
    _writer = TdsWriter(
      transport: transport,
      session: this,
      bufsize: bufsize,
    );
  }

  factory TdsSession.fromContext(SessionBuildContext context) {
    return TdsSession(
      transport: context.transport,
      env: context.env,
      bufsize: context.bufsize,
      tzinfoFactory: context.tzinfoFactory,
      rowStrategy: context.rowStrategy,
    );
  }

  final tds.TransportProtocol _transport;
  final tds.TdsEnv _env;
  late final TdsReader _reader;
  late final TdsWriter _writer;
  final TzInfoFactory? tzinfoFactory;
  final dynamic rowStrategy;

  tds.AuthProtocol? _authentication;
  int _state = tds.TDS_IDLE;
  int _tdsVersion = tds.TDS74;
  String? _lastQuery;
  final List<String> _messages = [];
  String? get lastQuery => _lastQuery;

  /// Exposição temporária do ambiente até que a sessão completa seja portada.
  tds.TdsEnv get env => _env;

  @override
  tds.TransportProtocol get transport => _transport;

  @override
  int get writerBufferSize => _writer.bufsize;

  @override
  int get readerBlockSize => _reader.blockSize;

  @override
  void setReaderBlockSize(int size) {
    _reader.setBlockSize(size);
  }

  @override
  void sendPrelogin(tds.TdsLogin login) {
    _tdsVersion = login.tdsVersion;
    _state = tds.TDS_QUERYING;
    _record('PRELOGIN ${login.serverName}:${login.port ?? 1433}');
  }

  @override
  void processPrelogin(tds.TdsLogin login) {
    _state = tds.TDS_PENDING;
    _record('PRELOGIN tokens processados');
  }

  @override
  void sendLogin(tds.TdsLogin login) {
    _state = tds.TDS_QUERYING;
    _record('LOGIN para ${login.userName}@${login.serverName}');
  }

  @override
  void beginResponse() {
    _reader.beginResponse();
    _state = tds.TDS_READING;
  }

  @override
  bool processLoginTokens() {
    _state = tds.TDS_IDLE;
    _record('LOGINACK placeholder aceito');
    return true;
  }

  @override
  void raiseDbException() {
    final details = _messages.isNotEmpty
        ? _messages.join(' | ')
        : 'Sessão placeholder ainda não captura mensagens do servidor.';
    throw tds.InterfaceError(details);
  }

  @override
  void submitPlainQuery(String sql) {
    _lastQuery = sql;
    _state = tds.TDS_QUERYING;
    _writer.beginPacket(tds.PacketType.QUERY);
    _writer.writeUcs2(sql);
    _record('QUERY enviado (${sql.length} chars)');
  }

  @override
  void processSimpleRequest() {
    _writer.flush();
    _state = tds.TDS_IDLE;
    _record('DONE placeholder processado');
  }

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

  void _record(String message) {
    _messages.add(message);
  }
}
