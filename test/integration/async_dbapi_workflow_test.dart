import 'dart:math';

import 'package:mssql_dart/tds.dart';
import 'package:test/test.dart';
import 'test_config.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('MssqlConnection', () {
    late MssqlConnection conn;

    setUp(() async {
      conn = await MssqlConnection.connect(MssqlConnectionSettings(
        host: host,
        port: port,
        username: user,
        password: password,
        database: database,
        encrypt: false,
      ));
    });

    tearDown(() async {
      await conn.close();
    });

    test('execute + fetchOne', () async {
      final cursor = await conn.openCursor('SELECT 41 + 1');
      final row = await cursor.fetchOne() as List<dynamic>?;
      expect(row, equals([42]));
      expect(await cursor.fetchOne(), isNull);
      await cursor.close();
    });

    test('cursor DDL/DML workflow', () async {
      final seed = Random().nextInt(1 << 16);
      final tableName = '#async_dbapi_${seed.toRadixString(16)}';

      final cursor = conn.cursor();
      await cursor.execute(
          'CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(40));');
      await cursor.fetchAll();

      addTearDown(() async {
        try {
          await cursor.execute(
              "IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          await cursor.fetchAll();
        } catch (_) {
          // The original test failure matters more.
        }
      });

      for (var i = 0; i < 2; i++) {
        await cursor.execute(
            "INSERT INTO $tableName (id, nome) VALUES ($i, N'Nome $i')");
        await cursor.fetchAll();
      }

      await cursor.execute('SELECT COUNT(*) FROM $tableName');
      final countRow = await cursor.fetchOne() as List<dynamic>?;
      expect(countRow, equals([2]));

      await cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = (await cursor.fetchAll()).cast<List<dynamic>>();
      expect(
          rows,
          equals([
            [0, 'Nome 0'],
            [1, 'Nome 1'],
          ]));

      await cursor.execute('DROP TABLE $tableName');
      await cursor.fetchAll();
      await cursor.close();
    });

    test('cursor respects nextSet', () async {
      final cursor = conn.cursor();
      await cursor.execute('SELECT 1 AS primeira; SELECT 2 AS segunda;');
      expect(
          await cursor.fetchAll(),
          equals([
            [1],
          ]));
      expect(await cursor.nextSet(), isTrue);
      expect(
          await cursor.fetchAll(),
          equals([
            [2],
          ]));
      expect(await cursor.nextSet(), isFalse);
      await cursor.close();
    });

    test('serializes concurrent executions', () async {
      Future<int> job(int value) async {
        final cursor = conn.cursor();
        await cursor.execute("WAITFOR DELAY '00:00:00.3'; SELECT $value");
        final rows = (await cursor.fetchAll()).cast<List<dynamic>>();
        await cursor.close();
        return rows.first.first as int;
      }

      final sw = Stopwatch()..start();
      final results = await Future.wait([
        job(11),
        job(22),
      ]);
      sw.stop();

      expect(results..sort(), equals([11, 22]));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(550));
    });

    test('cursor executeMany sums rowcount', () async {
      final seed = Random().nextInt(1 << 16);
      final tableName = '#async_many_${seed.toRadixString(16)}';

      final cursor = conn.cursor();
      await cursor.execute(
          'CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(40));');
      await cursor.fetchAll();

      addTearDown(() async {
        try {
          await cursor.execute(
              "IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          await cursor.fetchAll();
        } catch (_) {}
      });

      await cursor.executeMany(
        'INSERT INTO $tableName (id, nome) VALUES (@p0, @p1)',
        [
          [0, 'Nome 0'],
          [1, 'Nome 1'],
        ],
      );
      await cursor.fetchAll();
      expect(cursor.affectedRows, equals(2));

      await cursor.executeMany(
        'UPDATE $tableName SET nome = @nome WHERE id = @id',
        [
          {'id': 0, 'nome': 'Atualizado 0'},
          {'@id': 1, '@nome': 'Atualizado 1'},
        ],
      );
      await cursor.fetchAll();
      expect(cursor.affectedRows, equals(2));

      await cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = (await cursor.fetchAll()).cast<List<dynamic>>();
      expect(
          rows,
          equals([
            [0, 'Atualizado 0'],
            [1, 'Atualizado 1'],
          ]));

      await cursor.close();
    });

    test('manages dozens of concurrent analytical queries', () async {
      const clients = 16;
      const iterationsPerClient = 12;
      const seriesSize = 1500;
      const baseSum = seriesSize * (seriesSize + 1) ~/ 2;

      Future<void> runClient(int clientIndex) async {
        final local = await MssqlConnection.connect(MssqlConnectionSettings(
          caFile: testCa,
          trustServerCertificate: testTrustServerCertificate,
          host: host,
          port: port,
          username: user,
          password: password,
          database: database,
          encrypt: true,
          tlsBackend: TlsBackend.tlslite,
        ));

        try {
          final cursor = local.cursor();
          try {
            for (var iteration = 0;
                iteration < iterationsPerClient;
                iteration++) {
              await cursor.execute('''
WITH numbers AS (
  SELECT TOP ($seriesSize) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
  FROM sys.all_columns
)
SELECT SUM(numbers.n) + $clientIndex + $iteration AS total
FROM numbers;
''');

              final rows = (await cursor.fetchAll()).cast<List<dynamic>>();
              expect(rows.length, equals(1));
              expect(rows.first.length, equals(1));
              expect(
                rows.first.first,
                equals(baseSum + clientIndex + iteration),
                reason:
                    'Unexpected total for client $clientIndex iteration $iteration',
              );
            }
          } finally {
            await cursor.close();
          }
        } finally {
          await local.close();
        }
      }

      await Future.wait(List.generate(clients, runClient));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
