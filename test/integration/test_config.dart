import 'dart:io';

/// Server used by the integration tests. The defaults match
/// `tools/mssql/mssql.sh` (SQL Server in Docker with login dart/dart).
final testHost = Platform.environment['MSSQL_HOST'] ?? 'localhost';
final testPort = int.parse(Platform.environment['MSSQL_PORT'] ?? '1433');
final testUser = Platform.environment['MSSQL_USER'] ?? 'dart';
final testPassword = Platform.environment['MSSQL_PASSWORD'] ?? 'dart';
final testDatabase = Platform.environment['MSSQL_DATABASE'] ?? 'dart';

/// CA that signs the test server's certificate (self-signed, CN=localhost).
final testCaFile = Platform.environment['MSSQL_CA_FILE'] ??
    '${Directory.current.path}/test/certificates/sqlserver.crt';

/// `MSSQL_TRUST_SERVER_CERTIFICATE=true` accepts the certificate the server
/// generated (e.g. SQL Server installed on the CI Windows runner); tests that
/// depend on the test certificate are skipped.
final testTrustServerCertificate =
    Platform.environment['MSSQL_TRUST_SERVER_CERTIFICATE'] == 'true';

/// [testCaFile], or null when [testTrustServerCertificate] is set.
final String? testCa = testTrustServerCertificate ? null : testCaFile;

/// Reason for skipping tests that need the test certificate on the server.
final String? skipWithoutTestCertificate = testTrustServerCertificate
    ? 'server does not use the certificate from test/certificates'
    : null;
