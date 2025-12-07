import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

import 'row_strategies.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'async_socket_transport.dart';
import 'async_tds_socket.dart';
import 'async_db_api.dart';
import 'tls/tls_base.dart' show TlsBackend;

/// Equivalente assíncrono, retornando [AsyncDbConnection].
/// 
/// Parâmetros de TLS:
/// - [encrypt]: Se true, usa TLS para criptografar a conexão.
/// - [cafile]: Caminho para arquivo de certificados CA em formato PEM.
/// - [securityContext]: SecurityContext customizado para TLS.
/// - [validateHost]: Se true (padrão), valida o hostname contra o certificado.
/// - [encLoginOnly]: Se true, criptografa apenas o login e reverte para plaintext.
///   **ATENÇÃO**: Isso é inseguro, pois queries SQL serão visíveis na rede.
/// - [tlsBackend]: Backend TLS a usar para upgrade mid-stream:
///   - [TlsBackend.dartSecureSocket]: SecureSocket nativo (TLS-first apenas)
///   - [TlsBackend.openSsl]: OpenSSL via FFI (permite upgrade mid-stream)
///   - [TlsBackend.tlslite]: tlslite puro Dart (permite upgrade mid-stream)
///   - [TlsBackend.auto]: escolhe automaticamente (padrão)
Future<AsyncDbConnection> dbConnectAsync({
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
  bool encLoginOnly = false,
  TlsBackend? tlsBackend,
}) async {
  final socket = await connectAsync(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    appName: appName,
    bytesToUnicode: bytesToUnicode,
    timeout: timeout,
    traceHook: traceHook,
    encrypt: encrypt,
    cafile: cafile,
    securityContext: securityContext,
    validateHost: validateHost,
    encLoginOnly: encLoginOnly,
    tlsBackend: tlsBackend,
  );
  return asyncDbConnectionFromSocket(socket);
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
  bool encLoginOnly = false,
  TlsBackend? tlsBackend,
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
  
  final tds.TlsBackend backendPref = tlsBackend ?? tds.TlsBackend.tlslite;
  
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
    ctx ??= SecurityContext(withTrustedRoots: true);
    // O caminho padrão agora usa o provider pure Dart, que suporta o
    // handshake encapsulado do TDS. O SecureSocket nativo permanece
    // disponível via backend explícito.
    login
      ..cafile = cafile
      ..tlsCtx = ctx
      ..validateHost = validateHost
      ..encLoginOnly = encLoginOnly
      ..tlsBackend = backendPref
      ..encFlag = encLoginOnly 
          ? tds.PreLoginEnc.ENCRYPT_OFF 
          : tds.PreLoginEnc.ENCRYPT_REQ;
  } else {
    login
      ..cafile = null
      ..tlsCtx = null
      ..validateHost = validateHost
      ..encLoginOnly = false
      ..tlsBackend = backendPref
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
  bool encLoginOnly = false,
  TlsBackend? tlsBackend,
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
      encLoginOnly: encLoginOnly,
      tlsBackend: tlsBackend,
    );
    
    // SQL Server SEMPRE usa TLS mid-stream (não suporta TLS-first)
    // O upgrade TLS acontece durante a negociação PRELOGIN
    // Portanto, sempre conectamos via socket plain primeiro
    transport = await AsyncSocketTransport.connect(
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
