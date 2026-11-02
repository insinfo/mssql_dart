import 'dart:typed_data';

import 'package:mssql_dart/tds.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  late MssqlConnection conn;

  setUpAll(() async {
    conn = await MssqlConnection.connect(MssqlConnectionSettings(
      caFile: testCa,
      trustServerCertificate: testTrustServerCertificate,
      host: testHost,
      port: testPort,
      username: testUser,
      password: testPassword,
      database: testDatabase,
    ));
  });

  tearDownAll(() => conn.close());

  Future<List<dynamic>> row(String sql, [List<dynamic>? params]) async {
    final cursor = await conn.openCursor(sql, parameters: params);
    final result = await cursor.fetchOne() as List<dynamic>;
    await cursor.close();
    return result;
  }

  Future<dynamic> echo(dynamic value) async =>
      (await row('SELECT @p0', [value])).first;

  group('RPC parameters (round trip)', () {
    test('integers, bit and float', () async {
      expect(await echo(42), 42);
      expect(await echo(-2147483648), -2147483648);
      expect(await echo(9007199254740993), 9007199254740993);
      expect(await echo(true), isTrue);
      expect(await echo(false), isFalse);
      expect(await echo(3.25), 3.25);
    });

    test('short Unicode text and nvarchar(max)', () async {
      expect(await echo('ação 漢字 😀'), 'ação 漢字 😀');
      expect(await echo(''), '');
      final long = 'x' * 5000 + 'ç';
      expect(await echo(long), long);
      expect(
          await echo("O'Reilly; DROP TABLE x --"), "O'Reilly; DROP TABLE x --");
    });

    test('short binary and varbinary(max)', () async {
      final small = Uint8List.fromList([0, 1, 2, 255]);
      expect(await echo(small), small);
      final big = Uint8List.fromList(List.generate(100000, (i) => i & 0xFF));
      expect(await echo(big), big);
    });

    test('dates and times', () async {
      final dt = DateTime.utc(2024, 2, 29, 13, 45, 1, 123, 456);
      expect(await echo(dt), dt);
      expect(
          await echo(const Duration(
              hours: 23, minutes: 59, seconds: 59, microseconds: 999999)),
          const Duration(
              hours: 23, minutes: 59, seconds: 59, microseconds: 999999));
      final offset = DateTimeOffsetValue(
          utc: DateTime.utc(2024, 1, 1, 12), offsetMinutes: -180);
      final back = await echo(offset) as DateTimeOffsetValue;
      expect(back.utc, offset.utc);
      expect(back.offsetMinutes, -180);
    });

    test('decimal', () async {
      final value = DecimalValue(
          unscaledValue: BigInt.parse('-12345678901234567890123'), scale: 5);
      expect((await echo(value)).toString(), '-123456789012345678.90123');
      expect(
          (await echo(BigInt.parse('99999999999999999999999999999999999999')))
              .toString(),
          '99999999999999999999999999999999999999');
    });

    test('nulls', () async {
      expect(await echo(null), isNull);
      expect(
          (await row('SELECT CASE WHEN @p0 IS NULL THEN 1 ELSE 0 END', [null]))
              .first,
          1);
    });

    test('several positional and named parameters', () async {
      final cursor = await conn.openCursor(
        'SELECT @p0 + @p1, @nome',
        parameters: {'p0': 40, 'p1': 2, 'nome': 'dart'},
      );
      expect(await cursor.fetchOne(), [42, 'dart']);
      await cursor.close();
    });
  });

  group('placeholders ?', () {
    test('positional with ?', () async {
      final cursor = await conn.openCursor(
        "SELECT ? + ?, '?' AS literal, ?",
        parameters: [40, 2, 'x'],
        placeholder: PlaceholderIdentifier.onlyQuestionMark,
      );
      expect(await cursor.fetchOne(), [42, '?', 'x']);
      await cursor.close();
    });

    test('executeMany with ?', () async {
      await (await conn
              .openCursor('CREATE TABLE #q (id int, nome nvarchar(20))'))
          .close();
      final affected = await conn.executeMany(
        'INSERT INTO #q VALUES (?, ?)',
        [
          [1, 'um'],
          [2, 'dois'],
        ],
        placeholder: PlaceholderIdentifier.onlyQuestionMark,
      );
      expect(affected, 2);
      final check = await conn.openCursor('SELECT nome FROM #q WHERE id = ?',
          parameters: [2], placeholder: PlaceholderIdentifier.onlyQuestionMark);
      expect(await check.fetchAll(), [
        ['dois']
      ]);
      await check.close();
    });
  });

  group('robustness', () {
    test('a server error in the middle of a batch keeps the connection usable',
        () async {
      final cursor = await conn.openCursor('SELECT 1; SELECT 1/0; SELECT 2');
      expect(await cursor.fetchAll(), [
        [1]
      ]);
      await expectLater(() async {
        while (await cursor.nextSet()) {
          await cursor.fetchAll();
        }
      }(),
          throwsA(isA<DatabaseException>()
              .having((e) => e.number, 'number', 8134)));
      await cursor.close();
      expect((await row('SELECT 3')).first, 3);
      // Abandoning the failed response does not taint the next command.
      await (await conn.openCursor('SELECT 1; SELECT 1/0')).close();
      expect((await row('SELECT 4')).first, 4);
    });

    test('closing a cursor without reading everything frees the connection',
        () async {
      final cursor = await conn.openCursor(
          'SELECT TOP 1000 object_id FROM sys.all_objects; SELECT 7');
      await cursor.fetchOne();
      await cursor.close();
      expect((await row('SELECT 8')).first, 8);
    });
  });

  group('column decoding', () {
    test('all fixed and nullable types', () async {
      final r = await row('''
        SELECT CAST(1 AS bit), CAST(NULL AS bit), CAST(255 AS tinyint), CAST(-32768 AS smallint),
               CAST(2147483647 AS int), CAST(-9223372036854775808 AS bigint),
               CAST(1.5 AS real), CAST(2.5 AS float), CAST(12.3456 AS money), CAST(-1.25 AS smallmoney),
               CAST('2024-05-06T07:08:09.123' AS datetime), CAST('2024-05-06T07:08:00' AS smalldatetime),
               CAST('2024-05-06' AS date), CAST('07:08:09.1234567' AS time(7)),
               CAST('2024-05-06T07:08:09.1234567' AS datetime2(7)),
               CAST('6F9619FF-8B86-D011-B42D-00C04FD430C8' AS uniqueidentifier),
               CAST(123.45 AS decimal(10,2)), CAST(NULL AS int)''');
      expect(r.sublist(0, 6),
          [true, null, 255, -32768, 2147483647, -9223372036854775808]);
      expect(r[6], 1.5);
      expect(r[7], 2.5);
      expect(r[8], closeTo(12.3456, 1e-9));
      expect(r[9], closeTo(-1.25, 1e-9));
      expect(r[10], DateTime.utc(2024, 5, 6, 7, 8, 9, 123));
      expect(r[11], DateTime.utc(2024, 5, 6, 7, 8));
      expect(r[12], DateTime.utc(2024, 5, 6));
      expect(
          r[13],
          const Duration(
              hours: 7, minutes: 8, seconds: 9, microseconds: 123456));
      expect(r[14], DateTime.utc(2024, 5, 6, 7, 8, 9, 123, 456));
      expect(r[15].toString().toUpperCase(),
          '6F9619FF-8B86-D011-B42D-00C04FD430C8');
      expect(r[16].toString(), '123.45');
      expect(r[17], isNull);
    });

    test('text with collation, (max), text/ntext/image and xml', () async {
      final r = await row('''
        SELECT CAST('ação' AS varchar(10)) COLLATE Latin1_General_CI_AS,
               CAST('ab' AS char(4)), CAST(N'ñ' AS nchar(2)),
               CAST(REPLICATE(CAST('a' AS varchar(max)), 9000) AS varchar(max)),
               CAST(REPLICATE(CAST(N'é' AS nvarchar(max)), 9000) AS nvarchar(max)),
               CAST(REPLICATE(CAST(0xAB AS varbinary(max)), 9000) AS varbinary(max)),
               CAST(NULL AS nvarchar(max)), CAST('' AS varchar(max)),
               CAST('texto' AS text), CAST(N'ntexto' AS ntext), CAST(0x0102 AS image),
               CAST('<a>1</a>' AS xml), CAST(0x0A0B AS binary(3)), CAST(0x0C AS varbinary(10))''');
      expect(r[0], 'ação');
      expect(r[1], 'ab  ');
      expect(r[2], 'ñ ');
      expect(r[3], 'a' * 9000);
      expect(r[4], 'é' * 9000);
      expect(r[5], Uint8List.fromList(List.filled(9000, 0xAB)));
      expect(r[6], isNull);
      expect(r[7], '');
      expect(r[8], 'texto');
      expect(r[9], 'ntexto');
      expect(r[10], [1, 2]);
      expect(r[11], '<a>1</a>');
      expect(r[12], [0x0A, 0x0B, 0]);
      expect(r[13], [0x0C]);
    });

    test('varchar in several code pages and in a UTF-8 collation', () async {
      final samples = {
        'Cyrillic_General_CI_AS': 'Привет', // 1251
        'Greek_CI_AS': 'Καλημέρα', // 1253
        'Thai_CI_AS': 'สวัสดี', // 874
        'Japanese_CI_AS': 'こんにちは', // 932
        'Chinese_PRC_CI_AS': '你好', // 936
        'Korean_Wansung_CI_AS': '안녕하세요', // 949
        'Chinese_Taiwan_Stroke_CI_AS': '你好嗎', // 950
        'Latin1_General_100_CI_AS_SC_UTF8': 'ação 😀', // UTF-8
      };
      for (final entry in samples.entries) {
        final r = await row(
            "SELECT CAST(N'${entry.value}' COLLATE ${entry.key} AS varchar(40)) COLLATE ${entry.key}");
        expect(r.first, entry.value, reason: entry.key);
      }
    });

    test('sql_variant', () async {
      final r = await row(
          "SELECT CAST(42 AS sql_variant), CAST(N'x' AS sql_variant), CAST(NULL AS sql_variant)");
      expect(r, [42, 'x', null]);
    });

    test('table with many rows and mixed types', () async {
      final cursor = await conn.openCursor('''
        SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n,
               CAST(N'linha' AS nvarchar(20)), CAST(NULL AS varchar(10)), CAST(1 AS bit)
        FROM sys.all_objects a CROSS JOIN sys.all_objects b''');
      final rows = await cursor.fetchAll();
      expect(rows, hasLength(5000));
      expect(rows.last, [5000, 'linha', null, true]);
      await cursor.close();
    });
  });
}
