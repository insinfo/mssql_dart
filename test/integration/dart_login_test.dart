import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  test('connectSync realiza login básico', () {
    final traces = <String>[];
    late TdsSocket socket;
    try {
      socket = connectSync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
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
    addTearDown(() => socket.close());
    expect(socket.isConnected, isTrue);
    expect(socket.env.database?.toLowerCase(), equals(database));
    expect(traces.any((entry) => entry.startsWith('login.ack')), isTrue);
  });

  test('takeRow/takeAllRows expõem resultados após processSimpleRequest', () {
    final socket = connectSync(
      host: host,
      port: port,
      user: user,
      password: password,
      database: database,
      bytesToUnicode: true,
    );
    addTearDown(() => socket.close());

    socket.mainSession.submitPlainQuery('SELECT 1 AS valor UNION ALL SELECT 2');
    socket.mainSession.processSimpleRequest();

    expect(socket.hasBufferedRows, isTrue);
    expect(socket.bufferedRowCount, equals(2));

    final firstRow = socket.takeRow() as List<dynamic>?;
    expect(firstRow, isNotNull);
    expect(firstRow, equals([1]));

    final remaining = socket.takeAllRows();
    expect(remaining, hasLength(1));
    expect(remaining.first, equals([2]));
    expect(socket.hasBufferedRows, isFalse);
    expect(socket.bufferedRowCount, isZero);
  });
}
