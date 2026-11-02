import 'connection_string.dart';
import 'tds_base.dart' show TlsBackend;

/// How and where to connect to a SQL Server.
///
/// ```dart
/// const settings = MssqlConnectionSettings(
///   host: 'localhost',
///   database: 'app',
///   username: 'app_user',
///   password: 'secret',
/// );
///
/// // or from an ADO.NET, JDBC or URI connection string:
/// final fromString = MssqlConnectionSettings.parse(
///   'Server=tcp:db.example.com,1433;Database=app;User Id=app_user;Password=secret',
/// );
/// ```
///
/// TLS is on by default, and the server certificate is validated against
/// [caFile] or, without it, against the system CAs. For the self-signed
/// certificate SQL Server generates in Docker, use
/// `trustServerCertificate: true` (encrypted, but without authenticating the
/// server) or, better, point [caFile] at the certificate.
class MssqlConnectionSettings {
  const MssqlConnectionSettings({
    required this.host,
    this.port,
    this.instanceName,
    required this.username,
    required this.password,
    this.database = '',
    this.applicationName = 'mssql_dart',
    this.encrypt = true,
    this.trustServerCertificate = false,
    this.caFile,
    this.validateHostName = true,
    this.tlsBackend = TlsBackend.tlslite,
    this.connectTimeout = const Duration(seconds: 15),
    this.keepAlive = const Duration(seconds: 30),
    this.readOnlyIntent = false,
    this.commandTimeout,
  });

  /// Parses a connection string in one of these formats:
  ///
  /// - ADO.NET/ODBC: `Server=tcp:host,1433;Database=app;User Id=u;Password=p`
  ///   (case-insensitive keys with the usual synonyms, such as
  ///   `Data Source`, `Initial Catalog`, `UID`, `PWD`; values enclosed in
  ///   `"..."`, `'...'` or `{...}` may contain `;`);
  /// - URI: `mssql://user:pass@host:1433/app?encrypt=true` (or `sqlserver://`),
  ///   with percent-encoded user and password;
  /// - JDBC: `jdbc:sqlserver://host:1433;databaseName=app;user=u;password=p`.
  ///
  /// `host\instance` (or `instanceName=`) selects a named instance, resolved
  /// through the SQL Server Browser when no port is given.
  ///
  /// Unknown keys throw a [FormatException] that lists them. Keys from other
  /// drivers that have no effect here (`Pooling`, `Max Pool Size`,
  /// `Packet Size`, `MultiSubnetFailover`...) are ignored; unsupported
  /// features (`MultipleActiveResultSets=true`, `Integrated Security=true`,
  /// `Encrypt=Strict`) also throw a [FormatException].
  factory MssqlConnectionSettings.parse(String connectionString) =>
      parseConnectionString(connectionString);

  /// Server host name or IP address.
  final String host;

  /// TCP port.
  ///
  /// When `null`: 1433 or, with [instanceName], the port reported by the
  /// SQL Server Browser (UDP 1434).
  final int? port;

  /// Named instance (`SQLEXPRESS` in `host\SQLEXPRESS`).
  ///
  /// Without [port], the port is discovered through the SQL Server Browser.
  final String? instanceName;

  final String username;
  final String password;

  /// Initial database; empty uses the login's default database.
  final String database;

  /// Name shown in `sys.dm_exec_sessions.program_name`.
  final String applicationName;

  /// Encrypts the whole session with TLS.
  ///
  /// With `false`, nothing is encrypted, not even the login.
  final bool encrypt;

  /// Accepts any server certificate without validating its chain or name.
  final bool trustServerCertificate;

  /// PEM bundle with the CAs (or the certificate itself) accepted for the
  /// server.
  final String? caFile;

  /// Checks that the certificate was issued for [host] (or for the server
  /// named in an Azure SQL redirect).
  final bool validateHostName;

  /// TLS implementation.
  ///
  /// [TlsBackend.openSsl] requires [trustServerCertificate].
  final TlsBackend tlsBackend;

  /// Total time allowed for TCP, TLS, login and session setup combined.
  ///
  /// Includes the SQL Server Browser lookup and any redirect.
  final Duration connectTimeout;

  /// Idle time after which the operating system starts sending TCP
  /// keepalives, to detect dead connections behind NAT or a firewall.
  ///
  /// [Duration.zero] disables it. After the first probe, more follow every
  /// 10 s, and after 3 unanswered probes the connection is considered dead.
  /// Supported on Linux, Android, macOS, iOS and Windows (timings adjustable
  /// since Windows 10 1709); ignored on other platforms.
  final Duration keepAlive;

  /// Declares read-only intent (`ApplicationIntent=ReadOnly`).
  ///
  /// This lets an Always On availability group listener route the
  /// connection to a readable secondary replica.
  final bool readOnlyIntent;

  /// Default timeout for each command (copied to
  /// `MssqlConnection.commandTimeout`); `null` waits indefinitely.
  final Duration? commandTimeout;

  /// Default SQL Server port.
  static const int defaultPort = 1433;

  MssqlConnectionSettings copyWith({
    String? host,
    int? port,
    String? instanceName,
    String? username,
    String? password,
    String? database,
    String? applicationName,
    bool? encrypt,
    bool? trustServerCertificate,
    String? caFile,
    bool? validateHostName,
    TlsBackend? tlsBackend,
    Duration? connectTimeout,
    Duration? keepAlive,
    bool? readOnlyIntent,
    Duration? commandTimeout,
  }) {
    return MssqlConnectionSettings(
      host: host ?? this.host,
      port: port ?? this.port,
      instanceName: instanceName ?? this.instanceName,
      username: username ?? this.username,
      password: password ?? this.password,
      database: database ?? this.database,
      applicationName: applicationName ?? this.applicationName,
      encrypt: encrypt ?? this.encrypt,
      trustServerCertificate:
          trustServerCertificate ?? this.trustServerCertificate,
      caFile: caFile ?? this.caFile,
      validateHostName: validateHostName ?? this.validateHostName,
      tlsBackend: tlsBackend ?? this.tlsBackend,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      keepAlive: keepAlive ?? this.keepAlive,
      readOnlyIntent: readOnlyIntent ?? this.readOnlyIntent,
      commandTimeout: commandTimeout ?? this.commandTimeout,
    );
  }

  /// Describes the settings without exposing the password.
  @override
  String toString() {
    final instance = instanceName == null ? '' : '\\$instanceName';
    final portText = port == null ? '' : ':$port';
    return 'MssqlConnectionSettings($username@$host$instance$portText/'
        '$database, password: ***, encrypt: $encrypt'
        '${trustServerCertificate ? ', trustServerCertificate: true' : ''}'
        '${readOnlyIntent ? ', readOnlyIntent: true' : ''})';
  }
}
