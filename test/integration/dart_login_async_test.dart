import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  test('connectAsync realiza login básico', () async {
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
          validateHost: false,
          bytesToUnicode: true,
          traceHook: (event, payload) {
            traces.add('$event ${payload.toString()}');
          },
        );
      } catch (error) {
        for (final trace in traces) {
          // Ajuda a diagnosticar onde o login falhou.
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

  test('AsyncTdsSocket expõe linhas após processSimpleRequest', () async {
    await withSqlServerLock(() async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
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
