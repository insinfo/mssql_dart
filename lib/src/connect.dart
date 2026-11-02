import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'async_socket_transport.dart';
import 'async_tds_socket.dart';
import 'row_strategies.dart';
import 'session_link.dart';
import 'settings.dart';
import 'sql_browser.dart';
import 'tds_base.dart' as tds;
import 'tls/tls_base.dart' show TlsBackend;

/// Opens a low-level connection ([AsyncTdsSocket]).
///
/// Prefer `MssqlConnection.connect`.
///
/// TLS: [encrypt] (default `true`) encrypts the whole session; the
/// certificate is validated against [cafile] or the system CAs, and
/// [validateHost] checks the name. [trustServerCertificate] accepts any
/// certificate. [timeout] bounds the SQL Browser lookup, TCP, TLS, login, any
/// redirect and session setup; when it expires, the socket is closed.
///
/// [instanceName] (or `host\instance` in [host]) selects a named instance;
/// without [port], the port is discovered through the SQL Server Browser on
/// [browserPort] (UDP). With neither [port] nor an instance, 1433 is used.
///
/// If the server answers the login with a redirect (routing ENVCHANGE, used
/// by the Azure SQL gateway and by Always On listeners with
/// `readOnlyIntent`), the connection is reopened once on the indicated
/// server, with the same credentials and with the certificate validated
/// against the target server name.
///
/// [keepAlive] enables TCP keepalive after that much idle time
/// ([Duration.zero] disables it).
Future<AsyncTdsSocket> connectAsync({
  required String host,
  int? port,
  String? instanceName,
  required String user,
  required String password,
  String database = '',
  String appName = 'mssql_dart',
  bool bytesToUnicode = true,
  Duration timeout = const Duration(seconds: 15),
  SessionTraceHook? traceHook,
  bool encrypt = true,
  bool trustServerCertificate = false,
  String? cafile,
  bool validateHost = true,
  bool encLoginOnly = false,
  TlsBackend? tlsBackend,
  Duration keepAlive = Duration.zero,
  bool readOnlyIntent = false,
  int browserPort = SqlBrowser.defaultPort,
}) async {
  final target = splitInstance(host, instanceName);
  tds.TdsLogin loginFor(String serverHost, int serverPort) => _buildLogin(
        host: serverHost,
        port: serverPort,
        instanceName: target.instance ?? '',
        user: user,
        password: password,
        database: database,
        appName: appName,
        bytesToUnicode: bytesToUnicode,
        encrypt: encrypt,
        trustServerCertificate: trustServerCertificate,
        cafile: cafile,
        validateHost: validateHost,
        encLoginOnly: encLoginOnly,
        tlsBackend: tlsBackend,
        readOnlyIntent: readOnlyIntent,
      );
  // Validate the options before touching the network.
  loginFor(target.host, port ?? MssqlConnectionSettings.defaultPort);

  final deadline = Stopwatch()..start();
  Duration remaining() {
    final left = timeout - deadline.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  AsyncSocketTransport? current;
  var abandoned = false; // timed out: nothing else may be opened
  var description =
      '${target.host}:${port ?? MssqlConnectionSettings.defaultPort}';
  var phase = 'connecting and authenticating to';

  Future<AsyncTdsSocket> open(String serverHost, int serverPort) async {
    description = '$serverHost:$serverPort';
    phase = 'connecting and authenticating to';
    final transport = current = await AsyncSocketTransport.connect(
      serverHost,
      serverPort,
      timeout: remaining(),
      description: description,
      keepAlive: keepAlive,
    );
    if (abandoned) {
      transport.destroy();
      throw tds.ClosedConnectionException();
    }
    final socket = AsyncTdsSocket(
      transport: transport,
      login: loginFor(serverHost, serverPort),
      rowStrategy: defaultRowStrategy,
      useTz: null,
      autocommit: true,
      isolationLevel: 0,
      traceHook: traceHook,
    );
    await socket.login();
    return socket;
  }

  Future<AsyncTdsSocket> establish() async {
    var serverPort = port;
    final instance = target.instance;
    if (serverPort == null &&
        instance != null &&
        instance.toUpperCase() != 'MSSQLSERVER') {
      final browserTimeout = remaining() < SqlBrowser.defaultTimeout
          ? remaining()
          : SqlBrowser.defaultTimeout;
      phase = 'querying the SQL Server Browser (UDP $browserPort) for '
          'instance "$instance" on';
      description = target.host;
      serverPort = await SqlBrowser.resolvePort(target.host, instance,
          port: browserPort, timeout: browserTimeout);
    }
    var socket = await open(
        target.host, serverPort ?? MssqlConnectionSettings.defaultPort);
    final first = RoutingTarget.fromRoute(socket.route);
    if (first != null) {
      // The server only accepts the session at the indicated target.
      await socket.close();
      socket = await open(first.host, first.port);
      if (socket.route != null) {
        await socket.close();
        throw tds.OperationalException(
          'The server redirected the connection more than once '
          '(${first.host}:${first.port} requested another redirect)',
        );
      }
    }
    await applySessionSetup(socket);
    return socket;
  }

  try {
    return await establish().timeout(remaining());
  } on TimeoutException {
    abandoned = true;
    current?.destroy();
    throw tds.OperationalException(
      'Timed out ($timeout) while $phase $description',
    );
  } catch (_) {
    current?.destroy();
    rethrow;
  }
}

/// Opens an authenticated socket from [settings].
///
/// Backs `MssqlConnection.connect`. [browserPort] exists for tests with a
/// fake SQL Browser.
Future<AsyncTdsSocket> connectWithSettings(
  MssqlConnectionSettings settings, {
  int browserPort = SqlBrowser.defaultPort,
}) {
  return connectAsync(
    host: settings.host,
    port: settings.port,
    instanceName: settings.instanceName,
    user: settings.username,
    password: settings.password,
    database: settings.database,
    appName: settings.applicationName,
    timeout: settings.connectTimeout,
    encrypt: settings.encrypt,
    trustServerCertificate: settings.trustServerCertificate,
    cafile: settings.caFile,
    validateHost: settings.validateHostName,
    tlsBackend: settings.tlsBackend,
    keepAlive: settings.keepAlive,
    readOnlyIntent: settings.readOnlyIntent,
    browserPort: browserPort,
  );
}

/// Splits `host\instance`; an explicit [instanceName] takes precedence.
({String host, String? instance}) splitInstance(
    String host, String? instanceName) {
  var server = host.trim();
  String? instance = instanceName?.trim();
  final backslash = server.indexOf('\\');
  if (backslash >= 0) {
    final fromHost = server.substring(backslash + 1).trim();
    server = server.substring(0, backslash).trim();
    if (instance == null || instance.isEmpty) instance = fromHost;
  }
  return (
    host: server,
    instance: instance == null || instance.isEmpty ? null : instance,
  );
}

/// Target of a redirect received during login (ENVCHANGE type 20).
class RoutingTarget {
  const RoutingTarget(this.host, this.port);

  final String host;
  final int port;

  /// Interprets the map stored in `AsyncTdsSocket.route`; `null` when there
  /// was no redirect.
  ///
  /// The name may come as `host\instance`: the port already identifies the
  /// instance, so only the host is used for TCP and TLS validation.
  static RoutingTarget? fromRoute(tds.Route? route) {
    if (route == null) return null;
    final protocol = route['protocol'] as int? ?? 0;
    if (protocol != 0) {
      throw tds.OperationalException(
          'Redirect to protocol $protocol is not supported (TCP only)');
    }
    final server = (route['server'] as String? ?? '').trim();
    final port = route['port'] as int? ?? 0;
    final host = splitInstance(server, null).host;
    if (host.isEmpty || port <= 0) {
      throw tds.OperationalException(
          'Invalid redirect received from the server: $server:$port');
    }
    return RoutingTarget(host, port);
  }

  @override
  String toString() => '$host:$port';
}

/// Runs the driver's session options (see [_sessionSetup]) on [socket].
///
/// Used after login and after a session reset.
Future<void> applySessionSetup(AsyncTdsSocket socket) {
  return socket.runSerial((session) async {
    await session.submitPlainQuery(_sessionSetup);
    await session.processSimpleRequest();
  });
}

/// Options applied right after login, the same ones ODBC/JDBC use.
///
/// Without TEXTSIZE, the server truncates `(max)`, text and image values to
/// 4096 bytes.
const String _sessionSetup = 'SET TEXTSIZE 2147483647; SET ANSI_NULLS ON; '
    'SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ANSI_NULL_DFLT_ON ON; '
    'SET CONCAT_NULL_YIELDS_NULL ON; SET QUOTED_IDENTIFIER ON; '
    'SET ARITHABORT ON; SET IMPLICIT_TRANSACTIONS OFF; '
    'SET CURSOR_CLOSE_ON_COMMIT OFF; '
    // sp_reset_connection does not restore the isolation level (SQL Server
    // 2022): without this, a connection returned to the pool would leak
    // SERIALIZABLE etc.
    'SET TRANSACTION ISOLATION LEVEL READ COMMITTED';

tds.TdsLogin _buildLogin({
  required String host,
  required int port,
  String instanceName = '',
  required String user,
  required String password,
  required String database,
  required String appName,
  required bool bytesToUnicode,
  required bool encrypt,
  bool trustServerCertificate = false,
  String? cafile,
  bool validateHost = true,
  bool encLoginOnly = false,
  TlsBackend? tlsBackend,
  bool readOnlyIntent = false,
}) {
  if (!encrypt && (cafile != null || trustServerCertificate || encLoginOnly)) {
    throw ArgumentError(
      'cafile, trustServerCertificate and encLoginOnly require encrypt: true.',
    );
  }
  if (cafile != null && !File(cafile).existsSync()) {
    throw ArgumentError.value(cafile, 'cafile', 'file not found');
  }
  final login = tds.TdsLogin()
    // Also the name validated against the TLS certificate: host only, no instance.
    ..serverName = host
    // Sent in PRELOGIN (INSTOPT); the server only flags a mismatch.
    ..instanceName = instanceName
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
    ..useMars = false
    ..readonly = readOnlyIntent
    ..cafile = cafile
    ..validateHost = validateHost
    ..trustServerCertificate = trustServerCertificate
    ..encLoginOnly = encrypt && encLoginOnly
    ..tlsBackend = tlsBackend ?? TlsBackend.tlslite;
  login.encFlag = !encrypt
      ? tds.PreLoginEnc.ENCRYPT_NOT_SUP
      : encLoginOnly
          ? tds.PreLoginEnc.ENCRYPT_OFF
          : tds.PreLoginEnc.ENCRYPT_REQ;
  return login;
}

/// Exposed for tests only.
tds.TdsLogin buildLoginForTesting({
  required String host,
  int port = 1433,
  String instanceName = '',
  required String user,
  required String password,
  String database = '',
  String appName = 'mssql_dart',
  bool bytesToUnicode = true,
  bool encrypt = true,
  bool trustServerCertificate = false,
  String? cafile,
  bool validateHost = true,
  bool readOnlyIntent = false,
}) {
  return _buildLogin(
    host: host,
    port: port,
    instanceName: instanceName,
    user: user,
    password: password,
    database: database,
    appName: appName,
    bytesToUnicode: bytesToUnicode,
    encrypt: encrypt,
    trustServerCertificate: trustServerCertificate,
    cafile: cafile,
    validateHost: validateHost,
    readOnlyIntent: readOnlyIntent,
  );
}

int _generateClientId() {
  final rand = Random();
  final high = rand.nextInt(1 << 16);
  final mid = rand.nextInt(1 << 16);
  final low = rand.nextInt(1 << 16);
  return (high << 32) | (mid << 16) | low;
}
