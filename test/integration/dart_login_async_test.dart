import 'package:mssql_dart/tds.dart';
import 'package:test/test.dart';
import 'test_config.dart';

import 'test_utils.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  test('connectAsync performs a basic login', () async {
    await withSqlServerLock(() async {
      final traces = <String>[];
      late AsyncTdsSocket socket;
      try {
        socket = await connectAsync(
          host: host,
          port: port,
          user: user,
          password: password,
          database: database,
          encrypt: true,
          cafile: testCa,
          trustServerCertificate: testTrustServerCertificate,
          bytesToUnicode: true,
          traceHook: (event, payload) {
            traces.add('$event ${payload.toString()}');
          },
        );
      } catch (error) {
        for (final trace in traces) {
          // Helps diagnose where the login failed.
          // ignore: avoid_print
          print('[TRACE] $trace');
        }
        rethrow;
      }
      try {
        expect(socket.isConnected, isTrue);
        expect(socket.env.database?.toLowerCase(), equals(database));
        expect(traces.any((entry) => entry.startsWith('login.ack')), isTrue);
      } finally {
        await socket.close();
      }
    });
  });

  test('AsyncTdsSocket exposes rows after processSimpleRequest', () async {
    await withSqlServerLock(() async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        cafile: testCa,
        trustServerCertificate: testTrustServerCertificate,
        bytesToUnicode: true,
      );
      try {
        await socket.runSerial((session) async {
          await session
              .submitPlainQuery('SELECT 10 AS valor UNION ALL SELECT 20');
          await session.processSimpleRequest();
        });

        expect(socket.hasBufferedRows, isTrue);
        expect(socket.bufferedRowCount, equals(2));

        final firstRow = socket.takeRow() as List<dynamic>?;
        expect(firstRow, equals([10]));

        final rest = socket.takeAllRows();
        expect(rest, hasLength(1));
        expect(rest.first, equals([20]));
        expect(socket.hasBufferedRows, isFalse);
      } finally {
        await socket.close();
      }
    });
  });
}
