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
    await conn.execute('''
      CREATE PROCEDURE #p
        @entrada int,
        @nome nvarchar(50),
        @dobro int OUTPUT,
        @saudacao nvarchar(100) OUTPUT,
        @preco decimal(10, 2) OUTPUT,
        @quando datetime2(3) OUTPUT,
        @codigo varchar(10) OUTPUT,
        @ativo bit OUTPUT,
        @nulo int OUTPUT
      AS
      BEGIN
        SET NOCOUNT ON;
        SET @dobro = @entrada * 2;
        SET @saudacao = N'Olá, ' + @nome;
        SET @preco = @preco * 2;
        SET @quando = DATEADD(day, 1, @quando);
        SET @codigo = 'C-' + CAST(@entrada AS varchar(5));
        SET @ativo = 1;
        SET @nulo = NULL;
        SELECT @entrada AS n, @nome AS nome;
        SELECT v FROM (VALUES (1), (2), (3)) t(v);
        RETURN 7;
      END''');
  });
  tearDown(() => conn.close());

  Map<String, Object?> parameters() => {
        'entrada': 21,
        'nome': 'Ana',
        'dobro': const SqlParameter.int(null).output(),
        'saudacao': const SqlParameter.nvarchar(null, length: 100).output(),
        'preco': SqlParameter.decimal(DecimalValue.parse('1.25'),
                precision: 10, scale: 2)
            .output(),
        'quando':
            SqlParameter.datetime2(DateTime.utc(2024, 2, 28, 10), scale: 3)
                .output(),
        'codigo': const SqlParameter.varchar(null, length: 10).output(),
        'ativo': const SqlParameter.bit(false).output(),
        'nulo': const SqlParameter.int(5).output(),
      };

  test('callProcedure returns result sets, OUTPUT and RETURN', () async {
    final result = await conn.callProcedure('#p', parameters: parameters());
    expect(result.returnStatus, 7);
    expect(result.resultSets, hasLength(2));
    expect(result.resultSets[0].single.toColumnMap(), {'n': 21, 'nome': 'Ana'});
    expect(result.resultSets[1].map((row) => row['v']), [1, 2, 3]);
    expect(result.firstResultSet.single['n'], 21);
    expect(result.outputParameters, {
      'dobro': 42,
      'saudacao': 'Olá, Ana',
      'preco': DecimalValue.parse('2.50'),
      'quando': DateTime.utc(2024, 2, 29, 10),
      'codigo': 'C-21',
      'ativo': true,
      'nulo': null,
    });
    expect(await conn.queryScalar<int>('SELECT 1'), 1);
  });

  test('positional parameters and names with @', () async {
    final positional = parameters().values.toList();
    final result = await conn.callProcedure('#p', parameters: positional);
    expect(result.returnStatus, 7);
    // Without a name the server returns no name: the key is the list position.
    expect(result.outputParameters['2'], 42);
    expect(result.outputParameters['3'], 'Olá, Ana');

    final withAt = {
      for (final entry in parameters().entries) '@${entry.key}': entry.value
    };
    final named = await conn.callProcedure('#p', parameters: withAt);
    expect(named.outputParameters['saudacao'], 'Olá, Ana');
  });

  test('procedure without parameters or RETURN', () async {
    await conn.execute(
        'CREATE PROCEDURE #simples AS SELECT 1 AS um; SELECT 2 AS dois');
    final result = await conn.callProcedure('#simples');
    expect(result.returnStatus, 0);
    expect(result.outputParameters, isEmpty);
    expect(result.resultSets.map((set) => set.single[0]), [1, 2]);
  });

  test('system procedure by name', () async {
    final result = await conn.callProcedure('sp_executesql', parameters: [
      'SELECT @a + 1 AS r',
      '@a int',
      5,
    ]);
    expect(result.firstResultSet.single['r'], 6);
  });

  test(
      'an error in the procedure becomes DatabaseException and the connection keeps working',
      () async {
    await conn.execute('CREATE PROCEDURE #falha @x int AS '
        "BEGIN RAISERROR('falhou %d', 16, 1, @x); RETURN 1; END");
    await expectLater(
      conn.callProcedure('#falha', parameters: {'x': 3}),
      throwsA(isA<DatabaseException>()
          .having((e) => e.message, 'message', contains('falhou 3'))),
    );
    await expectLater(conn.callProcedure('#nao_existe'),
        throwsA(isA<ProgrammingException>()));
    expect(await conn.queryScalar<int>('SELECT 1'), 1);
  });

  test('callProcedure accepts a timeout and emits onQuery', () async {
    await conn.execute(
        "CREATE PROCEDURE #lenta AS WAITFOR DELAY '00:00:05'; RETURN 1");
    final events = <MssqlQueryEvent>[];
    conn.onQuery = events.add;
    await expectLater(
        conn.callProcedure('#lenta',
            timeout: const Duration(milliseconds: 300)),
        throwsA(isA<MssqlTimeoutException>()));
    await conn.callProcedure('#p', parameters: parameters());
    expect(events.map((e) => e.sql), ['#lenta', '#p']);
    expect(events.first.error, isA<MssqlTimeoutException>());
    expect(events.last.error, isNull);
  });
}
