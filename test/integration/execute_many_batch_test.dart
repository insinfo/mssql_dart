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
    await conn.execute(
        'CREATE TABLE #m (id int PRIMARY KEY, nome nvarchar(50), valor float)');
  });
  tearDown(() => conn.close());

  test('inserts thousands of rows in batches and sums the affected rows',
      () async {
    final rows = [
      for (var i = 0; i < 5000; i++) [i, 'nome $i', i / 2]
    ];
    final events = <MssqlQueryEvent>[];
    conn.onQuery = events.add;
    final count = await conn.executeMany(
        'INSERT INTO #m (id, nome, valor) VALUES (@p0, @p1, @p2)', rows);
    expect(count, 5000);
    expect(events.single.affectedRows, 5000);
    expect(events.single.parameters, same(rows));
    final check = await conn.querySingle(
        'SELECT COUNT(*) AS n, SUM(id) AS s, MAX(nome) AS m FROM #m');
    expect(check['n'], 5000);
    expect(check['s'], 4999 * 5000 ~/ 2);
    expect(check['m'], 'nome 999');
  });

  test('large parameters split the message into several batches', () async {
    final big = 'x' * 3000; // ~6 KB per item -> several 512 KB batches
    final rows = [
      for (var i = 0; i < 300; i++) {'id': i, 'nome': big.substring(0, 50)}
    ];
    expect(
        await conn.executeMany(
            'INSERT INTO #m (id, nome) VALUES (@id, @nome); '
            'DECLARE @lixo nvarchar(max) = @big',
            [
              for (final row in rows) {...row, 'big': big}
            ]),
        300);
    expect(await conn.queryScalar<int>('SELECT COUNT(*) FROM #m'), 300);
  });

  test('UPDATE with different counts per item', () async {
    await conn.executeMany(
        'INSERT INTO #m (id) VALUES (?)',
        [
          for (var i = 0; i < 10; i++) [i]
        ],
        placeholder: PlaceholderIdentifier.onlyQuestionMark);
    final count =
        await conn.executeMany('UPDATE #m SET valor = 1 WHERE id < @p0', [
      [0],
      [3],
      [10]
    ]);
    expect(count, 0 + 3 + 10);
  });

  test(
      'an error in one item is thrown after the batch; the other items in '
      'the batch are applied', () async {
    await expectLater(
      conn.executeMany('INSERT INTO #m (id) VALUES (@p0)', [
        [1],
        [2],
        [1], // duplicate key
        [3],
      ]),
      throwsA(isA<IntegrityException>()),
    );
    final ids = [
      for (final row in await conn.query('SELECT id FROM #m ORDER BY id'))
        row[0]
    ];
    expect(ids, [1, 2, 3]);
    expect(await conn.queryScalar<int>('SELECT 1'), 1);
  });

  test('inside a transaction, the error rolls everything back', () async {
    await expectLater(
      conn.transaction(
          (tx) => tx.executeMany('INSERT INTO #m (id) VALUES (@p0)', [
                [1],
                [1],
                [2]
              ])),
      throwsA(isA<IntegrityException>()),
    );
    expect(await conn.queryScalar<int>('SELECT COUNT(*) FROM #m'), 0);
  });

  test('empty list, null items and SqlParameter', () async {
    expect(await conn.executeMany('INSERT INTO #m (id) VALUES (@p0)', []), 0);
    await conn.execute('CREATE TABLE #n (x int DEFAULT 1)');
    expect(
        await conn.executeMany('INSERT INTO #n DEFAULT VALUES', [null, null]),
        2);
    expect(
        await conn.executeMany('INSERT INTO #m (id, nome) VALUES (@p0, @p1)', [
          [1, const SqlParameter.nvarchar(null, length: 50)],
          [2, const SqlParameter.nvarchar('b', length: 50)],
        ]),
        2);
  });

  test('cursor executeMany with SET NOCOUNT ON returns -1', () async {
    await conn.execute('SET NOCOUNT ON');
    final cursor = conn.cursor();
    await cursor.executeMany('INSERT INTO #m (id) VALUES (@p0)', [
      [1],
      [2]
    ]);
    expect(cursor.affectedRows, -1);
    expect(await cursor.fetchAll(), isEmpty);
    await cursor.close();
    await conn.execute('SET NOCOUNT OFF');
    expect(await conn.queryScalar<int>('SELECT COUNT(*) FROM #m'), 2);
  });
}
