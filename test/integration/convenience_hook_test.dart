import 'dart:async';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

final _settings = MssqlConnectionSettings(
  host: testHost,
  port: testPort,
  username: testUser,
  password: testPassword,
  database: testDatabase,
  caFile: testCa,
  trustServerCertificate: testTrustServerCertificate,
);

void main() {
  late MssqlConnection conn;
  setUp(() async {
    conn = await MssqlConnection.connect(_settings);
    await conn.execute('CREATE TABLE #c (id int, nome nvarchar(20))');
    await conn.execute("INSERT INTO #c VALUES (1, 'a'), (2, 'b'), (3, NULL)");
  });
  tearDown(() => conn.close());

  group('convenience methods', () {
    test('queryFirst', () async {
      final row = await conn.queryFirst('SELECT id, nome FROM #c ORDER BY id');
      expect(row?.toColumnMap(), {'id': 1, 'nome': 'a'});
      expect(await conn.queryFirst('SELECT id FROM #c WHERE id > 10'), isNull);
      // The connection was released even with unread rows.
      expect(await conn.queryScalar<int>('SELECT 1'), 1);
    });

    test('querySingle', () async {
      final row = await conn
          .querySingle('SELECT nome FROM #c WHERE id = @id', parameters: {
        'id': 2,
      });
      expect(row['nome'], 'b');
      await expectLater(
          conn.querySingle('SELECT id FROM #c'), throwsStateError);
      await expectLater(
          conn.querySingle('SELECT id FROM #c WHERE id = 0'), throwsStateError);
      expect(await conn.queryScalar<int>('SELECT 1'), 1);
    });

    test('queryScalar', () async {
      expect(await conn.queryScalar<int>('SELECT COUNT(*) FROM #c'), 3);
      expect(await conn.queryScalar<String>('SELECT nome FROM #c WHERE id = 3'),
          isNull);
      expect(await conn.queryScalar<int>('SELECT id FROM #c WHERE id = 9'),
          isNull);
      expect(
          await conn.queryScalar<String>('SELECT nome FROM #c WHERE id = ?',
              parameters: [1],
              placeholder: PlaceholderIdentifier.onlyQuestionMark),
          'a');
    });

    test('queryMaps', () async {
      expect(await conn.queryMaps('SELECT id, nome FROM #c ORDER BY id'), [
        {'id': 1, 'nome': 'a'},
        {'id': 2, 'nome': 'b'},
        {'id': 3, 'nome': null},
      ]);
    });
  });

  group('onQuery', () {
    late List<MssqlQueryEvent> events;
    setUp(() {
      events = [];
      conn.onQuery = events.add;
    });

    test('query, execute, executeMany, stream, openCursor and callProcedure',
        () async {
      await conn.query('SELECT id FROM #c WHERE id = @p0', parameters: [1]);
      await conn.execute('UPDATE #c SET nome = nome');
      await conn.executeMany('INSERT INTO #c (id) VALUES (@p0)', [
        [4],
        [5]
      ]);
      await conn.stream('SELECT id FROM #c').toList();
      final cursor = await conn.openCursor('SELECT 1');
      await cursor.close();
      await conn.callProcedure('sp_executesql', parameters: ['SELECT 1']);
      await conn.queryScalar<int>('SELECT ?',
          parameters: [9], placeholder: PlaceholderIdentifier.onlyQuestionMark);

      expect(events.map((e) => e.sql), [
        'SELECT id FROM #c WHERE id = @p0',
        'UPDATE #c SET nome = nome',
        'INSERT INTO #c (id) VALUES (@p0)',
        'SELECT id FROM #c',
        'SELECT 1',
        'sp_executesql',
        'SELECT @p0', // already converted
      ]);
      expect(events[0].parameters, [1]);
      expect(events[0].affectedRows, 1);
      expect(events[1].parameters, isNull);
      expect(events[1].affectedRows, 3);
      expect(events[2].affectedRows, 2);
      expect(events[3].affectedRows, 5);
      expect(events.every((e) => e.error == null), isTrue);
      expect(events.every((e) => e.elapsed > Duration.zero), isTrue);
    });

    test('receives the command error', () async {
      await expectLater(conn.execute('SELECT * FROM tabela_que_nao_existe'),
          throwsA(isA<ProgrammingException>()));
      expect(events.single.error, isA<ProgrammingException>());
      expect(events.single.affectedRows, isNull);
    });

    test('batches without parameters also emit, including transaction ones',
        () async {
      await conn.transaction((tx) => tx.execute('SET NOCOUNT ON'));
      expect(events.map((e) => e.sql), [
        'BEGIN TRANSACTION',
        'SET NOCOUNT ON',
        'COMMIT TRANSACTION',
      ]);
      expect(events.every((e) => e.parameters == null), isTrue);
    });

    test('a throwing hook does not change the command result', () async {
      conn.onQuery = (_) => throw StateError('broken hook');
      final errors = <Object>[];
      final value = await runZonedGuarded(
          () => conn.queryScalar<int>('SELECT 5'),
          (error, _) => errors.add(error));
      expect(value, 5);
      expect(errors.single, isA<StateError>());
    });
  });
}
