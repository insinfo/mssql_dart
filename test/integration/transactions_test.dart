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

const _levelSql = 'SELECT transaction_isolation_level FROM '
    'sys.dm_exec_sessions WHERE session_id = @@SPID';

void main() {
  late MssqlConnection conn;
  setUp(() async {
    conn = await MssqlConnection.connect(_settings);
    await conn.execute('CREATE TABLE #t (id int)');
  });
  tearDown(() => conn.close());

  Future<List<int>> ids() async => [
        for (final row in await conn.query('SELECT id FROM #t ORDER BY id'))
          row[0] as int
      ];

  group('isolationLevel', () {
    const expected = {
      IsolationLevel.readUncommitted: 1,
      IsolationLevel.readCommitted: 2,
      IsolationLevel.repeatableRead: 3,
      IsolationLevel.serializable: 4,
    };
    for (final MapEntry(key: level, value: code) in expected.entries) {
      test('${level.name} applies inside the transaction and is restored',
          () async {
        final inside = await conn.transaction(
            (tx) => tx.queryScalar<int>(_levelSql),
            isolationLevel: level);
        expect(inside, code);
        expect(await conn.queryScalar<int>(_levelSql), 2);
      });
    }

    test('snapshot', () async {
      await conn
          .execute('ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON');
      final inside = await conn.transaction((tx) async {
        await tx.execute('INSERT INTO #t VALUES (1)');
        return tx.queryScalar<int>(_levelSql);
      }, isolationLevel: IsolationLevel.snapshot);
      expect(inside, 5);
      expect(await conn.queryScalar<int>(_levelSql), 2);
      expect(await ids(), [1]);
    });

    test('restores the session\'s previous level, not just read committed',
        () async {
      await conn.execute('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
      await conn.transaction((tx) async {
        expect(await tx.queryScalar<int>(_levelSql), 1);
      }, isolationLevel: IsolationLevel.readUncommitted);
      expect(await conn.queryScalar<int>(_levelSql), 4);
      await conn.execute('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
    });

    test('also restores after a rollback', () async {
      await expectLater(
          conn.transaction((tx) async {
            await tx.execute('INSERT INTO #t VALUES (1)');
            throw StateError('failure');
          }, isolationLevel: IsolationLevel.serializable),
          throwsStateError);
      expect(await conn.queryScalar<int>(_levelSql), 2);
      expect(await ids(), isEmpty);
      expect(await conn.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
    });

    test('cannot be changed in a nested transaction', () async {
      await conn.transaction((tx) async {
        expect(
            () => tx.transaction((_) async {},
                isolationLevel: IsolationLevel.serializable),
            throwsArgumentError);
      });
    });
  });

  group('savepoints', () {
    test('rollbackToSavepoint undoes only the work after the savepoint',
        () async {
      await conn.transaction((tx) async {
        await tx.execute('INSERT INTO #t VALUES (1)');
        await tx.savepoint('antes_do_2');
        await tx.execute('INSERT INTO #t VALUES (2)');
        await tx.rollbackToSavepoint('antes_do_2');
        await tx.execute('INSERT INTO #t VALUES (3)');
        expect(await tx.queryScalar<int>('SELECT @@TRANCOUNT'), 1);
      });
      expect(await ids(), [1, 3]);
    });

    test('nested transaction uses a savepoint', () async {
      await conn.transaction((tx) async {
        await tx.execute('INSERT INTO #t VALUES (1)');
        await expectLater(
          tx.transaction((inner) async {
            await inner.execute('INSERT INTO #t VALUES (2)');
            throw StateError('undo only 2');
          }),
          throwsStateError,
        );
        final value = await tx.transaction((inner) async {
          await inner.execute('INSERT INTO #t VALUES (3)');
          return 'ok';
        });
        expect(value, 'ok');
        expect(await tx.queryScalar<int>('SELECT @@TRANCOUNT'), 1);
      });
      expect(await ids(), [1, 3]);
    });

    test('an error escaping the nested one rolls back the outer one', () async {
      await expectLater(
        conn.transaction((tx) async {
          await tx.execute('INSERT INTO #t VALUES (1)');
          await tx.transaction((inner) async {
            await inner.execute('INSERT INTO #t VALUES (2)');
            throw StateError('propagates');
          });
        }),
        throwsStateError,
      );
      expect(await ids(), isEmpty);
      expect(await conn.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
    });

    test('savepoint outside a transaction and invalid name', () async {
      expect(() => conn.savepoint('sp'), throwsA(isA<InterfaceException>()));
      await conn.transaction((tx) async {
        expect(() => tx.savepoint('drop table x'), throwsArgumentError);
        expect(() => tx.savepoint('a' * 33), throwsArgumentError);
      });
    });
  });
}
