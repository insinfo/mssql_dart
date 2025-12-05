import 'dart:math';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('TdsCursor workflows', () {
    late TdsSocket socket;
    late TdsCursor cursor;

    setUp(() {
      socket = connectSync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        bytesToUnicode: true,
      );
      cursor = socket.cursor();
    });

    tearDown(() {
      socket.close();
    });

    test('executa DDL e DML sequenciais', () {
      final seed = DateTime.now().microsecondsSinceEpoch + Random().nextInt(1000);
      final tableName = '#tmp_mssqldart_${seed.toRadixString(16)}';

      cursor.execute('CREATE TABLE $tableName (id INT PRIMARY KEY, nome NVARCHAR(50));');
      expect(cursor.fetchall(), isEmpty);

      // Limpeza automática caso o teste falhe antes do DROP.
      addTearDown(() {
        try {
          cursor.execute("IF OBJECT_ID('tempdb..$tableName') IS NOT NULL DROP TABLE $tableName");
          cursor.fetchall();
        } catch (_) {
          // Ignora erros de limpeza para não mascarar a falha original.
        }
      });

      for (var i = 0; i < 3; i++) {
        cursor.execute("INSERT INTO $tableName (id, nome) VALUES ($i, N'Nome $i')");
        expect(cursor.rowcount, equals(1));
        expect(cursor.fetchall(), isEmpty);
      }

      cursor.execute("UPDATE $tableName SET nome = N'Atualizado' WHERE id = 1");
      expect(cursor.rowcount, equals(1));
      cursor.fetchall();

      cursor.execute('DELETE FROM $tableName WHERE id = 2');
      expect(cursor.rowcount, equals(1));
      cursor.fetchall();

      cursor.execute('SELECT id, nome FROM $tableName ORDER BY id');
      final rows = cursor.fetchall().cast<List<dynamic>>();
      expect(rows, hasLength(2));
      expect(rows.first, equals([0, 'Nome 0']));
      expect(rows.last, equals([1, 'Atualizado']));

      cursor.execute('SELECT COUNT(*) FROM $tableName');
      final countRow = cursor.fetchone() as List<dynamic>?;
      expect(countRow, equals([2]));

      cursor.execute('DROP TABLE $tableName');
      cursor.fetchall();
    });

    test('nextset permite navegar múltiplos resultados', () {
      cursor.execute('SELECT 1 AS primeira; SELECT 2 AS segunda;');
      final primeiroSet = cursor.fetchall().cast<List<dynamic>>();
      expect(primeiroSet, equals([
        [1],
      ]));

      final possuiMais = cursor.nextset();
      expect(possuiMais, isTrue);

      final segundoSet = cursor.fetchall().cast<List<dynamic>>();
      expect(segundoSet, equals([
        [2],
      ]));

      expect(cursor.nextset(), isFalse);
    });
  });
}
