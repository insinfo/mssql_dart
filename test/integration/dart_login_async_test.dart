import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  test('connectAsync realiza login básico', () async {
    final traces = <String>[];
    late AsyncTdsSocket socket;
    try {
      socket = await connectAsync(
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
}
