import 'dart:async';

/// Integration tests for the TLS encrypted socket.
///
/// These tests require a SQL Server running locally.
/// Expected configuration:
/// - Host: localhost
/// - Port: 1433
/// - Database: dart
/// - User: dart
/// - Password: dart
///
/// To run the TLS tests, SQL Server must be configured with:
/// - A valid TLS certificate
/// - Force Encryption = Yes (or accept encrypted connections)
///
/// The TLS and non-TLS scenarios are split into independent groups so they
/// can be run selectively depending on the available environment.

import 'dart:io';

import 'package:mssql_dart/tds.dart';
import 'package:test/test.dart';
import 'test_config.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('TLS Connection Tests', () {
    test('connectAsync with TLS using the native SecureSocket (TLS-first)',
        () async {
      // This test uses Dart's native SecureSocket.
      // Requires the server to support TLS.
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        cafile: testCa,
        trustServerCertificate: testTrustServerCertificate,
      );
      addTearDown(() => socket.close());

      expect(socket.isConnected, isTrue);
      expect(socket.env.database?.toLowerCase(), equals(database));

      // Runs a query to check that TLS works
      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT @@VERSION AS sql_version');
        await session.processSimpleRequest();
      });

      expect(socket.hasBufferedRows, isTrue);
      final row = socket.takeRow() as List<dynamic>?;
      expect(row, isNotNull);
      expect(row!.first.toString(), contains('Microsoft SQL Server'));
    });

    test('dbConnectAsync with TLS', () async {
      // Test using the high-level dbConnectAsync API
      final conn = await MssqlConnection.connect(MssqlConnectionSettings(
        host: host,
        port: port,
        username: user,
        password: password,
        database: database,
        encrypt: true,
        caFile: testCa,
        trustServerCertificate: testTrustServerCertificate,
      ));
      addTearDown(() => conn.close());

      // Runs a query using the cursor API
      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      await cursor.execute('SELECT 42 AS answer');
      final rows = await cursor.fetchAll();

      expect(rows, hasLength(1));
      final firstRow = rows.first;
      final answer = firstRow is Map<String, dynamic>
          ? firstRow['answer']
          : (firstRow as List)[0];
      expect(answer, equals(42));
    });
  });

  group('TLS Error Handling', () {
    test('connectAsync with an invalid host fails gracefully', () async {
      expect(
        () => connectAsync(
          cafile: testCa,
          trustServerCertificate: testTrustServerCertificate,
          host: 'host-que-nao-existe.invalid',
          port: port,
          user: user,
          password: password,
          database: database,
          encrypt: true,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(
          predicate((e) =>
              e is Exception &&
              e.toString().contains(
                  'Failed to connect to host-que-nao-existe.invalid')),
        ),
      );
    });

    test('connectAsync with a wrong port fails gracefully', () async {
      expect(
        () => connectAsync(
          cafile: testCa,
          trustServerCertificate: testTrustServerCertificate,
          host: host,
          port: 9999, // Wrong port
          user: user,
          password: password,
          database: database,
          encrypt: true,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(
          predicate((e) =>
              e is Exception &&
              e.toString().contains('Failed to connect to localhost:9999')),
        ),
      );
    });
  });

  group('Certificate validation', skip: skipWithoutTestCertificate, () {
    test('rejects a self-signed certificate outside the system bundle',
        () async {
      await expectLater(
        connectAsync(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database),
        throwsA(isA<OperationalException>().having((e) => e.message, 'message',
            contains('Server certificate rejected'))),
      );
    });

    test('accepts with trustServerCertificate', () async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        trustServerCertificate: true,
      );
      await socket.close();
    });

    test('validates by the SAN IP address', () async {
      final socket = await connectAsync(
        host: '127.0.0.1',
        port: port,
        user: user,
        password: password,
        database: database,
        cafile: testCa,
        trustServerCertificate: testTrustServerCertificate,
      );
      await socket.close();
    });
  });

  group('Connection timeout', () {
    test('a server that accepts TCP and never answers is abandoned on time',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closed = Completer<void>();
      server.listen((client) {
        client.listen((_) {}, onDone: () {
          if (!closed.isCompleted) closed.complete();
          client.destroy();
        });
      });
      addTearDown(server.close);
      final sw = Stopwatch()..start();
      await expectLater(
        connectAsync(
          host: '127.0.0.1',
          port: server.port,
          user: user,
          password: password,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<OperationalException>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      // The driver closes the socket: the server receives the FIN.
      await closed.future.timeout(const Duration(seconds: 5));
    });
  });

  group('Multiple TLS Queries', () {
    test('multiple queries over a TLS connection', () async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        cafile: testCa,
        trustServerCertificate: testTrustServerCertificate,
      );
      addTearDown(() => socket.close());

      // Query 1
      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT 1 AS q1');
        await session.processSimpleRequest();
      });
      expect(socket.takeRow(), equals([1]));

      // Query 2
      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT 2 AS q2');
        await session.processSimpleRequest();
      });
      expect(socket.takeRow(), equals([2]));

      // Query 3 - with multiple rows
      await socket.runSerial((session) async {
        await session.submitPlainQuery(
          'SELECT n FROM (VALUES (1), (2), (3)) AS t(n)',
        );
        await session.processSimpleRequest();
      });
      final rows = socket.takeAllRows();
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.first), containsAll([1, 2, 3]));
    });

    test('transaction over a TLS connection', () async {
      final conn = await MssqlConnection.connect(MssqlConnectionSettings(
        host: host,
        port: port,
        username: user,
        password: password,
        database: database,
        encrypt: true,
        caFile: testCa,
        trustServerCertificate: testTrustServerCertificate,
      ));
      addTearDown(() => conn.close());

      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      // Creates a temporary table
      await cursor.execute('''
        CREATE TABLE #tls_test (
          id INT PRIMARY KEY,
          value NVARCHAR(100)
        )
      ''');

      // Insert inside a transaction
      await cursor.execute('BEGIN TRANSACTION');
      await cursor.execute("INSERT INTO #tls_test VALUES (1, 'test TLS')");
      await cursor.execute('COMMIT');

      // Checks
      await cursor.execute('SELECT * FROM #tls_test');
      final rows = await cursor.fetchAll();

      expect(rows, hasLength(1));
      final firstRow = rows.first;
      final id = firstRow is Map<String, dynamic>
          ? firstRow['id']
          : (firstRow as List)[0];
      final value = firstRow is Map<String, dynamic>
          ? firstRow['value']
          : (firstRow as List)[1];
      expect(id, equals(1));
      expect(value, equals('test TLS'));
    });
  });
}
