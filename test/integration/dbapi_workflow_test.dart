import 'dart:math';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('DbConnection', () {
    late DbConnection conn;

    setUp(() {
      conn = dbConnectSync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        bytesToUnicode: true,
      );
    });

    tearDown(() {
      conn.close();
    });

    test('execute + fetchone', () {
      final cursor = conn.execute('SELECT 41 + 1');
      final row = cursor.fetchone() as List<dynamic>?;
      expect(row, equals([42]));
      expect(cursor.fetchone(), isNull);
    });

    test('cursor DDL/DML workflow', () {
      final seed = Random().nextInt(1 << 16);
      final tableName = '#dbapi_tmp_${seed.toRadixString(16)}';

      final cursor = conn.cursor();
      cursor.execute('CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(40));');
      cursor.fetchall();

      addTearDown(() {
        try {
          cursor.execute("IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          cursor.fetchall();
        } catch (_) {
          // Ignora erros de limpeza, o próprio teste já falhou.
        }
      });

      for (var i = 0; i < 2; i++) {
        cursor.execute("INSERT INTO $tableName (id, nome) VALUES ($i, N'Nome $i')");
        cursor.fetchall();
      }

      cursor.execute('SELECT COUNT(*) FROM $tableName');
      final countRow = cursor.fetchone() as List<dynamic>?;
      expect(countRow, equals([2]));

      cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = cursor.fetchall().cast<List<dynamic>>();
      expect(rows, equals([
        [0, 'Nome 0'],
        [1, 'Nome 1'],
      ]));

      cursor.execute('DROP TABLE $tableName');
      cursor.fetchall();
    });

    test('cursor respects nextset', () {
      final cursor = conn.cursor();
      cursor.execute('SELECT 1 AS primeira; SELECT 2 AS segunda;');
      expect(cursor.fetchall(), equals([
        [1],
      ]));
      expect(cursor.nextset(), isTrue);
      expect(cursor.fetchall(), equals([
        [2],
      ]));
      expect(cursor.nextset(), isFalse);
    });

    test('cursor executemany soma rowcount', () {
      final seed = Random().nextInt(1 << 16);
      final tableName = '#dbapi_many_${seed.toRadixString(16)}';

      final cursor = conn.cursor();
      cursor.execute('CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(40));');
      cursor.fetchall();

      addTearDown(() {
        try {
          cursor.execute("IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          cursor.fetchall();
        } catch (_) {}
      });

      cursor.executemany(
        'INSERT INTO $tableName (id, nome) VALUES (@p0, @p1)',
        [
          [0, 'Nome 0'],
          [1, 'Nome 1'],
        ],
      );
      cursor.fetchall();
      expect(cursor.rowcount, equals(2));

      cursor.executemany(
        'UPDATE $tableName SET nome = @nome WHERE id = @id',
        [
          {'id': 0, 'nome': 'Atualizado 0'},
          {'@id': 1, '@nome': 'Atualizado 1'},
        ],
      );
      cursor.fetchall();
      expect(cursor.rowcount, equals(2));

      cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = cursor.fetchall().cast<List<dynamic>>();
      expect(rows, equals([
        [0, 'Atualizado 0'],
        [1, 'Atualizado 1'],
      ]));
    });
  });
}
