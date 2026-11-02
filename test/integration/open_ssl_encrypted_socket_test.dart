/// Tests focused on the `OpenSslEncryptedSocket` backend.
///
/// Kept in a separate file so they can run in isolation when the
/// environment has OpenSSL configured for the mid-stream handshake.
import 'package:mssql_dart/tds.dart';
import 'package:mssql_dart/src/tls/open_ssl_encrypted_socket.dart';
import 'package:test/test.dart';

dynamic _field(dynamic row, {String? name, int? index}) {
  if (row is Map<String, dynamic>) {
    if (name == null) {
      throw ArgumentError('name is required for Map-based rows');
    }
    return row[name];
  }
  final listRow = row as List;
  final resolvedIndex = index ?? 0;
  return listRow[resolvedIndex];
}

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('OpenSSL TLS mid-stream', () {
    setUpAll(() async {
      final available = await OpenSslEncryptedSocket.isAvailable();
      if (!available) {
        fail('OpenSSL FFI bindings are not available in this environment.');
      }
    });

    test('connectAsync performs the handshake and a simple SELECT', () async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        trustServerCertificate: true,
        tlsBackend: TlsBackend.openSsl,
      );
      addTearDown(() => socket.close());

      expect(socket.isConnected, isTrue);
      expect(socket.env.database?.toLowerCase(), equals(database));

      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT @@VERSION AS sql_version');
        await session.processSimpleRequest();
      });

      expect(socket.hasBufferedRows, isTrue);
      final row = socket.takeRow();
      expect(row, isNotNull);
    });

    test('dbConnectAsync with the OpenSSL backend', () async {
      final conn = await MssqlConnection.connect(MssqlConnectionSettings(
        host: host,
        port: port,
        username: user,
        password: password,
        database: database,
        encrypt: true,
        trustServerCertificate: true,
        tlsBackend: TlsBackend.openSsl,
      ));
      addTearDown(() => conn.close());

      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      await cursor.execute('SELECT 1 AS value');
      final rows = await cursor.fetchAll();

      expect(rows, hasLength(1));
      final value = _field(rows.first, name: 'value', index: 0);
      expect(value, equals(1));
    });
  });
}
