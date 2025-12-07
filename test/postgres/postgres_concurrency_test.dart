import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  group('PostgreSQL heavy concurrency', () {
    const host = 'localhost';
    const port = 5432;
    const database = 'dart_test';
    const username = 'dart';
    const password = 'dart';

    test('handles intense concurrent analytical workload', () async {
      const clients = 24;
      const queriesPerClient = 20;
      const seriesSize = 500;
      const baseSum = seriesSize * (seriesSize + 1) ~/ 2;

      Future<void> runClient(int clientIndex) async {
        final connection = await Connection.open(
          Endpoint(
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
          ),
          settings: const ConnectionSettings(
            queryTimeout: Duration(seconds: 20),
          ),
        );

        try {
          for (var iteration = 0; iteration < queriesPerClient; iteration++) {
            final rows = await connection.execute(
              Sql.named('''
WITH data AS (
  SELECT generate_series(1, @seriesSize::int) AS value
)
SELECT sum(value) + @client::bigint + @iteration::bigint AS total
FROM data;
'''),
              parameters: {
                'seriesSize': seriesSize,
                'client': clientIndex,
                'iteration': iteration,
              },
            );

            expect(rows.length, equals(1));
            final row = rows.first;
            expect(row.length, equals(1));
            expect(
              row[0],
              equals(baseSum + clientIndex + iteration),
              reason:
                  'Unexpected total for client $clientIndex iteration $iteration',
            );
          }
        } finally {
          await connection.close();
        }
      }

      await Future.wait(List.generate(clients, runClient));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
