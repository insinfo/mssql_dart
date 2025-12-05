import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

import 'row_strategies.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'tds_socket.dart';
import 'async_socket_transport.dart';
import 'async_tds_socket.dart';

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
}) {
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

tds.TdsLogin _buildLogin({
  required String host,
  required int port,
  required String user,
  required String password,
  required String database,
  required String appName,
  required bool bytesToUnicode,
  bool allowTls = false,
  String? cafile,
  SecurityContext? securityContext,
  bool validateHost = true,
  bool encLoginOnly = false,
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

  final wantsTls = cafile != null || securityContext != null;
  if (!allowTls && wantsTls) {
    throw ArgumentError(
      'TLS não está disponível para este modo de conexão. Utilize connectAsync para criptografia.',
    );
  }
  if (encLoginOnly && !wantsTls) {
    throw ArgumentError(
      'encLoginOnly exige um cafile ou SecurityContext configurado.',
    );
  }
  if (wantsTls) {
    login
      ..cafile = cafile
      ..tlsCtx = securityContext
      ..validateHost = validateHost
      ..encLoginOnly = encLoginOnly
      ..encFlag = encLoginOnly
          ? tds.PreLoginEnc.ENCRYPT_OFF
          : tds.PreLoginEnc.ENCRYPT_ON;
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
  String? cafile,
  SecurityContext? securityContext,
  bool validateHost = true,
  bool encLoginOnly = false,
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
    cafile: cafile,
    securityContext: securityContext,
    validateHost: validateHost,
    encLoginOnly: encLoginOnly,
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
  String? cafile,
  SecurityContext? securityContext,
  bool validateHost = true,
  bool loginEncryptionOnly = false,
}) async {
  final transport = await AsyncSocketTransport.connect(
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
      allowTls: true,
      cafile: cafile,
      securityContext: securityContext,
      validateHost: validateHost,
      encLoginOnly: loginEncryptionOnly,
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
    await transport.close();
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
