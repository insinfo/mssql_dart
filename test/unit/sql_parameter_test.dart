import 'dart:typed_data';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:mssql_dart/src/collate.dart';
import 'package:mssql_dart/src/rpc_params.dart';
import 'package:test/test.dart';

/// Parameter declaration (sp_executesql `@params`) generated for [params].
String definitionFor(Map<String, Object?> params, {Collation? collation}) {
  final out = TdsBufferWriter();
  encodeExecuteSql(out, 'SELECT 1', params, RpcCollation(collation));
  final bytes = out.takeBytes();
  // After the header (6 bytes) comes @stmt: empty name, status, nvarchar
  // TYPE_INFO (1 + 2 + 5), length (2) and the text; then @params.
  var pos = 6 + 2 + 8;
  final stmtLength = bytes[pos] | bytes[pos + 1] << 8;
  pos += 2 + stmtLength + 2 + 8;
  final length = bytes[pos] | bytes[pos + 1] << 8;
  final units = Uint16List.view(
      Uint8List.fromList(bytes.sublist(pos + 2, pos + 2 + length)).buffer);
  return String.fromCharCodes(units);
}

void main() {
  test('declarations of explicit types', () {
    expect(
        definitionFor({
          'a': const SqlParameter.varchar('x', length: 20),
          'b': const SqlParameter.varchar('x'),
          'c': SqlParameter.varchar('x' * 9000),
          'd': const SqlParameter.nvarchar(null),
          'e': const SqlParameter.nchar('ab'),
          'f': const SqlParameter.decimal(1, precision: 12, scale: 3),
          'g': const SqlParameter.time(null, scale: 2),
          'h': const SqlParameter.int(null).output(),
          'i': const SqlParameter.varbinary(null, length: SqlParameter.max),
          'j': const SqlParameter.xml(null),
        }),
        '@a varchar(20), @b varchar(8000), @c varchar(max), '
        '@d nvarchar(4000), @e nchar(2), @f decimal(12, 3), @g time(2), '
        '@h int OUTPUT, @i varbinary(max), @j xml');
  });

  test('inferred values stay the same', () {
    expect(definitionFor({'a': 1, 'b': 'x', 'c': DateTime(2024), 'd': null}),
        '@a int, @b nvarchar(4000), @c datetime2(7), @d nvarchar(4000)');
  });

  test('varchar uses the collation code page', () {
    final cyrillic = Collation(
        lcid: 0x419,
        sort_id: 0,
        ignore_case: true,
        ignore_accent: false,
        ignore_width: true,
        ignore_kana: true,
        binary: false,
        binary2: false,
        version: 0);
    expect(RpcCollation(cyrillic).encode('мир'), [0xEC, 0xE8, 0xF0]);
    expect(
        () => RpcCollation(null).encode('мир'), throwsA(isA<DataException>()));
  });

  test('validations', () {
    void fails(SqlParameter p) =>
        expect(() => definitionFor({'p': p}), throwsA(isA<DataException>()));
    fails(const SqlParameter.smallint(40000));
    fails(const SqlParameter.decimal(1, precision: 39));
    fails(const SqlParameter.decimal(1, precision: 5, scale: 6));
    fails(const SqlParameter.time(Duration(hours: 24)));
    fails(const SqlParameter.datetime2(null, scale: 8));
    fails(const SqlParameter.char('x', length: SqlParameter.max));
    fails(const SqlParameter.nvarchar('abc', length: 2));
    fails(SqlParameter.smalldatetime(DateTime.utc(2080)));
    fails(const SqlParameter.float(double.nan));
    expect(() => definitionFor({'p': const SqlParameter.int(null)}),
        returnsNormally);
    expect(() => definitionFor({'p': const SqlParameter.bit(null)}),
        returnsNormally);
  });

  test('output() keeps the type', () {
    const p = SqlParameter.decimal(1, precision: 5, scale: 2);
    final out = p.output();
    expect(out.isOutput, isTrue);
    expect(p.isOutput, isFalse);
    expect(out.kind, SqlParameterKind.decimal);
    expect(out.precision, 5);
    expect(out.scale, 2);
    expect(out.toString(), 'SqlParameter.decimal(1, OUTPUT)');
  });
}
