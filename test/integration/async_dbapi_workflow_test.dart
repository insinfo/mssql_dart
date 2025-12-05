import 'dart:math';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('AsyncDbConnection', () {
    late AsyncDbConnection conn;

    setUp(() async {
      conn = await dbConnectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        bytesToUnicode: true,
      );
    });

    tearDown(() async {
      await conn.close();
    });

    test('execute + fetchone', () async {
      final cursor = await conn.execute('SELECT 41 + 1');
      final row = await cursor.fetchone() as List<dynamic>?;
      expect(row, equals([42]));
      expect(await cursor.fetchone(), isNull);
      await cursor.close();
    });

    test('cursor DDL/DML workflow', () async {
      final seed = Random().nextInt(1 << 16);
      final tableName = '#async_dbapi_${seed.toRadixString(16)}';

      final cursor = conn.cursor();
      await cursor.execute('CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(40));');
      await cursor.fetchall();

      addTearDown(() async {
        try {
          await cursor.execute("IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          await cursor.fetchall();
        } catch (_) {
          // Falha original do teste é mais importante.
        }
      });

      for (var i = 0; i < 2; i++) {
        await cursor.execute("INSERT INTO $tableName (id, nome) VALUES ($i, N'Nome $i')");
        await cursor.fetchall();
      }

      await cursor.execute('SELECT COUNT(*) FROM $tableName');
      final countRow = await cursor.fetchone() as List<dynamic>?;
      expect(countRow, equals([2]));

      await cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = (await cursor.fetchall()).cast<List<dynamic>>();
      expect(rows, equals([
        [0, 'Nome 0'],
        [1, 'Nome 1'],
      ]));

      await cursor.execute('DROP TABLE $tableName');
      await cursor.fetchall();
      await cursor.close();
    });

    test('cursor respects nextset', () async {
      final cursor = conn.cursor();
      await cursor.execute('SELECT 1 AS primeira; SELECT 2 AS segunda;');
      expect(await cursor.fetchall(), equals([
        [1],
      ]));
      expect(await cursor.nextset(), isTrue);
      expect(await cursor.fetchall(), equals([
        [2],
      ]));
      expect(await cursor.nextset(), isFalse);
      await cursor.close();
    });

    test('serializa execuções concorrentes', () async {
      Future<int> job(int value) async {
        final cursor = conn.cursor();
        await cursor.execute("WAITFOR DELAY '00:00:00.3'; SELECT $value");
        final rows = (await cursor.fetchall()).cast<List<dynamic>>();
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

    test('cursor executemany soma rowcount', () async {
      final seed = Random().nextInt(1 << 16);
      final tableName = '#async_many_${seed.toRadixString(16)}';

      final cursor = conn.cursor();
      await cursor.execute('CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(40));');
      await cursor.fetchall();

      addTearDown(() async {
        try {
          await cursor.execute("IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          await cursor.fetchall();
        } catch (_) {}
      });

      await cursor.executemany(
        'INSERT INTO $tableName (id, nome) VALUES (@p0, @p1)',
        [
          [0, 'Nome 0'],
          [1, 'Nome 1'],
        ],
      );
      await cursor.fetchall();
      expect(cursor.rowcount, equals(2));

      await cursor.executemany(
        'UPDATE $tableName SET nome = @nome WHERE id = @id',
        [
          {'id': 0, 'nome': 'Atualizado 0'},
          {'@id': 1, '@nome': 'Atualizado 1'},
        ],
      );
      await cursor.fetchall();
      expect(cursor.rowcount, equals(2));

      await cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = (await cursor.fetchall()).cast<List<dynamic>>();
      expect(rows, equals([
        [0, 'Atualizado 0'],
        [1, 'Atualizado 1'],
      ]));

      await cursor.close();
    });
  });
}
