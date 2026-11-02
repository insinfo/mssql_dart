import 'dart:typed_data';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

MssqlConnectionSettings _settings([String? database]) =>
    MssqlConnectionSettings(
      host: testHost,
      port: testPort,
      username: testUser,
      password: testPassword,
      database: database ?? testDatabase,
      caFile: testCa,
      trustServerCertificate: testTrustServerCertificate,
    );

void main() {
  late MssqlConnection conn;
  setUpAll(() async => conn = await MssqlConnection.connect(_settings()));
  tearDownAll(() => conn.close());

  /// Value returned by `SELECT @p0` and the type the parameter arrived with
  /// (read from a table created from it, which also works for nulls).
  Future<(Object?, String)> roundTrip(SqlParameter parameter) async {
    // A temporary table created inside sp_executesql disappears at the end
    // of the call, so everything goes in a single batch.
    final row = await conn.querySingle('''
      SELECT @p0 AS v INTO #tp;
      SELECT (SELECT v FROM #tp) AS v, TYPE_NAME(c.system_type_id) +
        CASE WHEN TYPE_NAME(c.system_type_id) IN ('varchar', 'char', 'varbinary', 'binary')
               THEN '(' + IIF(c.max_length = -1, 'max', CAST(c.max_length AS varchar)) + ')'
             WHEN TYPE_NAME(c.system_type_id) IN ('nvarchar', 'nchar')
               THEN '(' + IIF(c.max_length = -1, 'max', CAST(c.max_length / 2 AS varchar)) + ')'
             WHEN TYPE_NAME(c.system_type_id) IN ('decimal', 'numeric')
               THEN '(' + CAST(c.precision AS varchar) + ',' + CAST(c.scale AS varchar) + ')'
             WHEN TYPE_NAME(c.system_type_id) IN ('time', 'datetime2', 'datetimeoffset')
               THEN '(' + CAST(c.scale AS varchar) + ')'
             ELSE '' END AS t
      FROM tempdb.sys.columns c WHERE c.object_id = OBJECT_ID('tempdb..#tp')''',
        parameters: [parameter]);
    return (row['v'], row['t'] as String);
  }

  group('SqlParameter round trip', () {
    final cases = <String, (SqlParameter, Object?, String)>{
      'bit': (const SqlParameter.bit(true), true, 'bit'),
      'tinyint': (const SqlParameter.tinyint(200), 200, 'tinyint'),
      'smallint': (const SqlParameter.smallint(-300), -300, 'smallint'),
      'int': (const SqlParameter.int(-5), -5, 'int'),
      'bigint': (const SqlParameter.bigint(1 << 40), 1 << 40, 'bigint'),
      'real': (const SqlParameter.real(1.5), 1.5, 'real'),
      'float': (const SqlParameter.float(2.25), 2.25, 'float'),
      'decimal rounds to the scale': (
        const SqlParameter.decimal(12.345, precision: 10, scale: 2),
        DecimalValue.parse('12.35'),
        'decimal(10,2)'
      ),
      'decimal from text': (
        SqlParameter.decimal('-98765432109876543210.123456',
            precision: 38, scale: 6),
        DecimalValue.parse('-98765432109876543210.123456'),
        'decimal(38,6)'
      ),
      'money': (const SqlParameter.money(12.3456), 12.3456, 'money'),
      'smallmoney': (const SqlParameter.smallmoney(-7.5), -7.5, 'smallmoney'),
      'date': (
        SqlParameter.date(DateTime(2024, 2, 29, 23, 59)),
        DateTime.utc(2024, 2, 29),
        'date'
      ),
      'time(3)': (
        const SqlParameter.time(
            Duration(hours: 13, minutes: 45, seconds: 1, microseconds: 123456),
            scale: 3),
        const Duration(hours: 13, minutes: 45, seconds: 1, milliseconds: 123),
        'time(3)'
      ),
      'datetime': (
        SqlParameter.datetime(DateTime.utc(2024, 1, 2, 3, 4, 5, 7)),
        DateTime.utc(2024, 1, 2, 3, 4, 5, 7),
        'datetime'
      ),
      'smalldatetime rounds the minute': (
        SqlParameter.smalldatetime(DateTime.utc(2024, 1, 2, 3, 4, 31)),
        DateTime.utc(2024, 1, 2, 3, 5),
        'smalldatetime'
      ),
      'datetime2(3)': (
        SqlParameter.datetime2(DateTime.utc(1, 1, 1, 0, 0, 0, 1, 999),
            scale: 3),
        DateTime.utc(1, 1, 1, 0, 0, 0, 1),
        'datetime2(3)'
      ),
      'uniqueidentifier from text': (
        const SqlParameter.uniqueidentifier(
            '6F9619FF-8B86-D011-B42D-00C04FC964FF'),
        '6f9619ff-8b86-d011-b42d-00c04fc964ff',
        'uniqueidentifier'
      ),
      'uniqueidentifier from bytes': (
        SqlParameter.uniqueidentifier(List.generate(16, (i) => i)),
        '00010203-0405-0607-0809-0a0b0c0d0e0f',
        'uniqueidentifier'
      ),
      'varchar': (
        const SqlParameter.varchar('ação', length: 10),
        'ação',
        'varchar(10)'
      ),
      'varchar without length': (
        const SqlParameter.varchar('abc'),
        'abc',
        'varchar(8000)'
      ),
      'varchar(max)': (
        SqlParameter.varchar('x' * 9000),
        'x' * 9000,
        'varchar(max)'
      ),
      'char': (const SqlParameter.char('ab', length: 5), 'ab   ', 'char(5)'),
      'nvarchar': (
        const SqlParameter.nvarchar('漢字', length: 20),
        '漢字',
        'nvarchar(20)'
      ),
      'nvarchar(max)': (
        const SqlParameter.nvarchar('y', length: SqlParameter.max),
        'y',
        'nvarchar(max)'
      ),
      'nchar': (const SqlParameter.nchar('é', length: 3), 'é  ', 'nchar(3)'),
      'varbinary': (
        SqlParameter.varbinary(Uint8List.fromList([1, 2, 3]), length: 16),
        Uint8List.fromList([1, 2, 3]),
        'varbinary(16)'
      ),
      'binary': (
        SqlParameter.binary(Uint8List.fromList([1, 2]), length: 4),
        Uint8List.fromList([1, 2, 0, 0]),
        'binary(4)'
      ),
      'varbinary(max)': (
        SqlParameter.varbinary(Uint8List(10000)),
        Uint8List(10000),
        'varbinary(max)'
      ),
      'xml': (
        const SqlParameter.xml('<a b="1">ç</a>'),
        '<a b="1">ç</a>',
        'xml'
      ),
    };
    cases.forEach((name, testCase) {
      test(name, () async {
        final (parameter, expected, type) = testCase;
        final (value, actualType) = await roundTrip(parameter);
        expect(actualType, type);
        expect(value, expected);
      });
    });

    test('datetimeoffset', () async {
      final offset = DateTimeOffsetValue(
          utc: DateTime.utc(2024, 6, 1, 12, 30), offsetMinutes: -180);
      final (value, type) =
          await roundTrip(SqlParameter.datetimeoffset(offset, scale: 2));
      expect(type, 'datetimeoffset(2)');
      value as DateTimeOffsetValue;
      expect(value.utc, offset.utc);
      expect(value.offsetMinutes, -180);
      final (fromUtc, _) = await roundTrip(
          SqlParameter.datetimeoffset(DateTime.utc(2024, 1, 1, 8)));
      expect((fromUtc as DateTimeOffsetValue).offsetMinutes, 0);
      expect(fromUtc.utc, DateTime.utc(2024, 1, 1, 8));
    });

    test('typed nulls keep their type', () async {
      final nulls = <SqlParameter, String>{
        const SqlParameter.bit(null): 'bit',
        const SqlParameter.tinyint(null): 'tinyint',
        const SqlParameter.smallint(null): 'smallint',
        const SqlParameter.int(null): 'int',
        const SqlParameter.bigint(null): 'bigint',
        const SqlParameter.real(null): 'real',
        const SqlParameter.float(null): 'float',
        const SqlParameter.decimal(null, precision: 9, scale: 3):
            'decimal(9,3)',
        const SqlParameter.money(null): 'money',
        const SqlParameter.date(null): 'date',
        const SqlParameter.time(null, scale: 0): 'time(0)',
        const SqlParameter.datetime(null): 'datetime',
        const SqlParameter.smalldatetime(null): 'smalldatetime',
        const SqlParameter.datetime2(null, scale: 4): 'datetime2(4)',
        const SqlParameter.datetimeoffset(null): 'datetimeoffset(7)',
        const SqlParameter.uniqueidentifier(null): 'uniqueidentifier',
        const SqlParameter.varchar(null, length: 30): 'varchar(30)',
        const SqlParameter.nvarchar(null): 'nvarchar(4000)',
        const SqlParameter.varbinary(null, length: SqlParameter.max):
            'varbinary(max)',
        const SqlParameter.xml(null): 'xml',
      };
      for (final MapEntry(key: parameter, value: type) in nulls.entries) {
        final (value, actualType) = await roundTrip(parameter);
        expect(value, isNull, reason: '$parameter');
        expect(actualType, type, reason: '$parameter');
      }
    });

    test('works in a Map, mixed with inferred values', () async {
      final row = await conn.querySingle(
          'SELECT @a AS a, @b AS b, SQL_VARIANT_PROPERTY(@a, \'BaseType\') AS t',
          parameters: {'a': const SqlParameter.smallint(7), 'b': 'texto'});
      expect(row['a'], 7);
      expect(row['b'], 'texto');
      expect(row['t'], 'smallint');
    });

    test('invalid values throw DataException before sending', () async {
      Future<void> fails(SqlParameter parameter) => expectLater(
          conn.query('SELECT @p0', parameters: [parameter]),
          throwsA(isA<DataException>()));
      await fails(const SqlParameter.tinyint(256));
      await fails(const SqlParameter.int(1 << 40));
      await fails(const SqlParameter.decimal(1000, precision: 3));
      await fails(const SqlParameter.varchar('abcdef', length: 3));
      await fails(const SqlParameter.varchar('Привет')); // outside cp1252
      await fails(const SqlParameter.uniqueidentifier('nope'));
      await fails(SqlParameter.datetime(DateTime.utc(1700)));
      expect(await conn.queryScalar<int>('SELECT 1'), 1);
    });
  });

  group('OUTPUT via sp_executesql', () {
    test('query returns outputParameters', () async {
      final result = await conn.query(
        'SET @dobro = @valor * 2; SET @texto = UPPER(@entrada); SELECT 1 AS x',
        parameters: {
          'valor': 21,
          'entrada': 'abc',
          'dobro': const SqlParameter.int(null).output(),
          'texto': const SqlParameter.nvarchar(null, length: 10).output(),
        },
      );
      expect(result.single['x'], 1);
      expect(result.outputParameters, {'dobro': 42, 'texto': 'ABC'});
    });
  });

  group('varchar and indexes', () {
    test('varchar against a varchar column does not convert the column',
        () async {
      await conn
          .execute('CREATE TABLE #idx (codigo varchar(20) PRIMARY KEY, n int)');
      await conn.executeMany('INSERT INTO #idx VALUES (@p0, @p1)', [
        for (var i = 0; i < 200; i++) ['C$i', i]
      ]);

      /// Actual plan (STATISTICS XML), which comes in an extra result set.
      Future<String> plan(Object parameter) async {
        await conn.execute('SET STATISTICS XML ON');
        final cursor = await conn.openCursor(
            'SELECT n FROM #idx WHERE codigo = @p0',
            parameters: [parameter]);
        final plans = StringBuffer();
        try {
          do {
            for (final row in await cursor.fetchAll()) {
              final value = row[0];
              if (value is String && value.contains('ShowPlanXML')) {
                plans.write(value);
              }
            }
          } while (await cursor.nextSet());
        } finally {
          await cursor.close();
          await conn.execute('SET STATISTICS XML OFF');
        }
        return plans.toString();
      }

      final typed = await plan(const SqlParameter.varchar('C42', length: 20));
      expect(typed, contains('Clustered Index Seek'));
      expect(typed, isNot(contains('CONVERT_IMPLICIT')));
      // With the inferred String (nvarchar) the column is converted.
      expect(await plan('C42'), contains('CONVERT_IMPLICIT'));
      expect(
          await conn.queryScalar<int>('SELECT n FROM #idx WHERE codigo = @p0',
              parameters: [const SqlParameter.varchar('C42', length: 20)]),
          42);
    });

    test('varchar in the code page of the connection collation (Cyrillic)',
        () async {
      // A varchar parameter value is interpreted in the database default
      // collation, so the test uses a database with a Cyrillic collation.
      const db = 'mssql_dart_cyrillic_test';
      try {
        await conn.execute("IF DB_ID('$db') IS NULL "
            'CREATE DATABASE $db COLLATE Cyrillic_General_CI_AS');
      } on DatabaseException catch (e) {
        markTestSkipped('no permission to create a database: ${e.message}');
        return;
      }
      addTearDown(() async {
        try {
          await conn.execute('ALTER DATABASE $db SET SINGLE_USER WITH '
              'ROLLBACK IMMEDIATE; DROP DATABASE $db');
        } catch (_) {}
      });
      final cyr = await MssqlConnection.connect(_settings(db));
      try {
        // Temporary table columns use the tempdb collation without
        // COLLATE DATABASE_DEFAULT.
        await cyr.execute(
            'CREATE TABLE #nomes (nome varchar(30) COLLATE DATABASE_DEFAULT '
            'PRIMARY KEY, id int)');
        await cyr.executeMany('INSERT INTO #nomes VALUES (@p0, @p1)', [
          [const SqlParameter.varchar('Привет', length: 30), 1],
          [const SqlParameter.varchar('мир', length: 30), 2],
        ]);
        // The stored bytes are the code page 1251 ones.
        expect(
            await cyr.queryScalar<Uint8List>(
                "SELECT CAST(nome AS varbinary(30)) FROM #nomes WHERE id = 2"),
            [0xEC, 0xE8, 0xF0]);
        expect(
            await cyr.queryScalar<int>('SELECT id FROM #nomes WHERE nome = @p0',
                parameters: [const SqlParameter.varchar('ПРИВЕТ', length: 30)]),
            1);
        expect(
            await cyr.queryScalar<String>(
                'SELECT nome FROM #nomes WHERE id = @p0',
                parameters: [2]),
            'мир');
      } finally {
        await cyr.close();
      }
    });
  });
}
