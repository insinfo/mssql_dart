import 'dart:async';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

final settings = MssqlConnectionSettings(
  host: testHost,
  port: testPort,
  username: testUser,
  password: testPassword,
  database: testDatabase,
  caFile: testCa,
  trustServerCertificate: testTrustServerCertificate,
);

void main() {
  group('MssqlConnection', () {
    late MssqlConnection conn;
    setUp(() async => conn = await MssqlConnection.connect(settings));
    tearDown(() => conn.close());

    test('query returns rows accessible by index and name', () async {
      final result = await conn.query('SELECT @id AS Id, @name AS Name',
          parameters: {'id': 7, 'name': 'ana'});
      expect(result, hasLength(1));
      expect(result.columns.map((c) => c.name), ['Id', 'Name']);
      final row = result.single;
      expect(row[0], 7);
      expect(row['name'], 'ana'); // case-insensitive
      expect(row.toColumnMap(), {'Id': 7, 'Name': 'ana'});
      expect(() => row['nope'], throwsArgumentError);
    });

    test('execute returns the affected row count', () async {
      await conn.execute('CREATE TABLE #t (id int)');
      expect(await conn.execute('INSERT INTO #t VALUES (1), (2), (3)'), 3);
      expect(
          await conn.execute('DELETE FROM #t WHERE id > @p0', parameters: [1]),
          2);
    });

    test('stream delivers rows on demand and frees the connection on cancel',
        () async {
      final ids = await conn
          .stream(
              'SELECT TOP 50 object_id FROM sys.all_objects ORDER BY object_id')
          .take(5)
          .map((row) => row[0])
          .toList();
      expect(ids, hasLength(5));
      expect((await conn.query('SELECT 1')).single[0], 1);
    });

    test('transaction commits and rolls back', () async {
      await conn.execute('CREATE TABLE #tx (id int)');
      await conn.transaction((tx) => tx.execute('INSERT INTO #tx VALUES (1)'));
      await expectLater(
        conn.transaction((tx) async {
          await tx.execute('INSERT INTO #tx VALUES (2)');
          throw StateError('failed');
        }),
        throwsStateError,
      );
      expect((await conn.query('SELECT id FROM #tx')).map((r) => r[0]), [1]);
      expect(conn.hasOpenTransaction, isFalse);
    });

    test('outside commands wait for the transaction to finish', () async {
      await conn.execute('CREATE TABLE #order (step nvarchar(10))');
      final release = Completer<void>();
      final txn = conn.transaction((tx) async {
        await tx.execute("INSERT INTO #order VALUES ('txn')");
        await release.future;
        await tx.execute("INSERT INTO #order VALUES ('txn-end')");
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final outside = conn.execute("INSERT INTO #order VALUES ('outside')");
      await Future<void>.delayed(const Duration(milliseconds: 50));
      release.complete();
      await Future.wait([txn, outside]);
      expect((await conn.query('SELECT step FROM #order')).map((r) => r[0]),
          ['txn', 'txn-end', 'outside']);
    });

    test('server errors become typed DatabaseExceptions', () async {
      await expectLater(
          conn.query('SELECT * FROM tabela_inexistente'),
          throwsA(isA<ProgrammingException>()
              .having((e) => e.number, 'number', 208)));
      expect((await conn.query('SELECT 1')).single[0], 1);
    });
  });

  test('wrong password throws LoginException', () async {
    await expectLater(
      MssqlConnection.connect(settings.copyWith(password: 'wrong-password')),
      throwsA(isA<LoginException>().having((e) => e.number, 'number', 18456)),
    );
  });

  group('MssqlPool', () {
    test('limits connections and serves concurrent calls', () async {
      final pool = MssqlPool(settings, maxConnections: 3);
      addTearDown(pool.close);
      final results = await Future.wait([
        for (var i = 0; i < 20; i++)
          pool.query("WAITFOR DELAY '00:00:00.05'; SELECT @p0",
              parameters: [i]),
      ]);
      expect(results.map((r) => r.single[0]), List.generate(20, (i) => i));
      expect(pool.totalConnections, lessThanOrEqualTo(3));
      expect(pool.idleConnections, pool.totalConnections);
    });

    test('rolls back a forgotten transaction and discards a broken connection',
        () async {
      final pool = MssqlPool(settings, maxConnections: 1);
      addTearDown(pool.close);
      await pool.withConnection((conn) => conn.execute('BEGIN TRANSACTION'));
      expect((await pool.query('SELECT @@TRANCOUNT')).single[0], 0);
      await expectLater(
        pool.withConnection((conn) => conn.execute('KILL @@SPID')),
        throwsA(isA<MssqlException>()),
      );
      expect((await pool.query('SELECT 1')).single[0], 1);
    });

    test('acquireTimeout when the pool is exhausted', () async {
      final pool = MssqlPool(settings,
          maxConnections: 1, acquireTimeout: const Duration(milliseconds: 200));
      addTearDown(pool.close);
      final hold = Completer<void>();
      final busy = pool.withConnection((_) => hold.future);
      await expectLater(
          pool.query('SELECT 1'), throwsA(isA<OperationalException>()));
      hold.complete();
      await busy;
      expect((await pool.query('SELECT 2')).single[0], 2);
    });
  });
}
