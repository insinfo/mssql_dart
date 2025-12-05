import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

import 'row_strategies.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'tds_socket.dart';
import 'async_socket_transport.dart';
import 'async_tds_socket.dart';
import 'db_api.dart';

/// Estabelece uma conexão síncrona com SQL Server utilizando `TdsSocket`.
///
/// Essa função encapsula a criação de `SocketTransport`, prepara um
/// `_TdsLogin` coerente com os parâmetros fornecidos e executa o handshake
/// `PRELOGIN/LOGIN`. Em caso de falha o socket é fechado e a exceção propagada.
TdsSocket connectSync({
  required String host,
  int port = 1433,
  required String user,
  required String password,
  String database = '',
  String appName = 'mssql_dart',
  bool bytesToUnicode = true,
  Duration timeout = const Duration(seconds: 5),
  SessionTraceHook? traceHook,
  bool encrypt = false,
}) {
  if (encrypt) {
    throw tds.NotSupportedError(
      'connectSync ainda não suporta TLS. Utilize connectAsync para conexões criptografadas.',
    );
  }
  final transport = SocketTransport.connectSync(
    host,
    port,
    timeout: timeout,
    description: '$host:$port',
  );
  try {
    final login = _buildLogin(
      host: host,
      port: port,
      user: user,
      password: password,
      database: database,
      appName: appName,
      bytesToUnicode: bytesToUnicode,
      encrypt: false,
    );
    final socket = TdsSocket(
      transport: transport,
      login: login,
      rowStrategy: defaultRowStrategy,
      useTz: null,
      autocommit: true,
      isolationLevel: 0,
      traceHook: traceHook,
    );
    socket.login();
    return socket;
  } catch (error) {
    transport.close();
    rethrow;
  }
}

/// Versão DB-API-friendly do [connectSync], retornando um [DbConnection].
DbConnection dbConnectSync({
  required String host,
  int port = 1433,
  required String user,
  required String password,
  String database = '',
  String appName = 'mssql_dart',
  bool bytesToUnicode = true,
  Duration timeout = const Duration(seconds: 5),
  SessionTraceHook? traceHook,
}) {
  final socket = connectSync(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    appName: appName,
    bytesToUnicode: bytesToUnicode,
    timeout: timeout,
    traceHook: traceHook,
  );
  return dbConnectionFromSocket(socket);
}

tds.TdsLogin _buildLogin({
  required String host,
  required int port,
  required String user,
  required String password,
  required String database,
  required String appName,
  required bool bytesToUnicode,
  required bool encrypt,
  bool allowTls = false,
  String? cafile,
  SecurityContext? securityContext,
  bool validateHost = true,
}) {
  final login = tds.TdsLogin()
    ..serverName = host
    ..instanceName = ''
    ..port = port
    ..userName = user
    ..password = password
    ..database = database
    ..appName = appName
    ..library = 'mssql_dart'
    ..clientHostName = Platform.localHostname
    ..clientLcid = 0x0409
    ..blocksize = 4096
    ..bytesToUnicode = bytesToUnicode
    ..tdsVersion = tds.TDS74
    ..pid = pid
    ..clientId = _generateClientId()
    ..useMars = false;

  if (!allowTls && encrypt) {
    throw ArgumentError(
      'TLS não está disponível para este modo de conexão. Utilize connectAsync para criptografia.',
    );
  }
  if (!encrypt && (cafile != null || securityContext != null)) {
    throw ArgumentError(
      'Parâmetros TLS foram fornecidos, mas encrypt=false. Ajuste encrypt ou remova cafile/securityContext.',
    );
  }
  if (encrypt) {
    SecurityContext? ctx = securityContext;
    if (ctx == null && cafile != null && cafile.isNotEmpty) {
      ctx = SecurityContext();
      try {
        ctx.setTrustedCertificates(cafile);
      } on TlsException catch (error) {
        throw tds.OperationalError(
          'Falha ao carregar certificado de confiança ($cafile): ${error.message}',
        );
      } on IOException catch (error) {
        throw tds.OperationalError(
          'Não foi possível ler o arquivo de certificados ($cafile): $error',
        );
      }
    }
    login
      ..cafile = cafile
      ..tlsCtx = ctx
      ..validateHost = validateHost
      ..encLoginOnly = false
      ..encFlag = tds.PreLoginEnc.ENCRYPT_REQ;
  } else {
    login
      ..cafile = null
      ..tlsCtx = null
      ..validateHost = validateHost
      ..encLoginOnly = false
      ..encFlag = tds.PreLoginEnc.ENCRYPT_NOT_SUP;
  }
  return login;
}

@visibleForTesting
tds.TdsLogin buildLoginForTesting({
  required String host,
  int port = 1433,
  required String user,
  required String password,
  String database = '',
  String appName = 'mssql_dart',
  bool bytesToUnicode = true,
  bool encrypt = false,
  String? cafile,
  SecurityContext? securityContext,
  bool validateHost = true,
}) {
  return _buildLogin(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    appName: appName,
    bytesToUnicode: bytesToUnicode,
    allowTls: true,
    encrypt: encrypt,
    cafile: cafile,
    securityContext: securityContext,
    validateHost: validateHost,
  );
}

Future<AsyncTdsSocket> connectAsync({
  required String host,
  int port = 1433,
  required String user,
  required String password,
  String database = '',
  String appName = 'mssql_dart',
  bool bytesToUnicode = true,
  Duration timeout = const Duration(seconds: 5),
  SessionTraceHook? traceHook,
  bool encrypt = false,
  String? cafile,
  SecurityContext? securityContext,
  bool validateHost = true,
}) async {
  tds.AsyncTransportProtocol? transport;
  try {
    final login = _buildLogin(
      host: host,
      port: port,
      user: user,
      password: password,
      database: database,
      appName: appName,
      bytesToUnicode: bytesToUnicode,
      allowTls: true,
      encrypt: encrypt,
      cafile: cafile,
      securityContext: securityContext,
      validateHost: validateHost,
    );
    transport = encrypt
        ? await AsyncSocketTransport.connectSecure(
            host,
            port,
            timeout: timeout,
            description: '$host:$port',
            context: login.tlsCtx as SecurityContext?,
            validateHost: login.validateHost,
          )
        : await AsyncSocketTransport.connect(
            host,
            port,
            timeout: timeout,
            description: '$host:$port',
          );
    final socket = AsyncTdsSocket(
      transport: transport,
      login: login,
      rowStrategy: defaultRowStrategy,
      useTz: null,
      autocommit: true,
      isolationLevel: 0,
      traceHook: traceHook,
    );
    await socket.login();
    return socket;
  } catch (error) {
    if (transport != null) {
      await transport.close();
    }
    rethrow;
  }
}

int _generateClientId() {
  final rand = Random();
  final high = rand.nextInt(1 << 16);
  final mid = rand.nextInt(1 << 16);
  final low = rand.nextInt(1 << 16);
  return (high << 32) | (mid << 16) | low;
}
