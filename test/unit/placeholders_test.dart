import 'package:mssql_dart/src/placeholders.dart';
import 'package:mssql_dart/src/tds_base.dart' as tds;
import 'package:test/test.dart';

void main() {
  String convert(String sql) => convertQuestionMarks(sql).sql;

  test('numbers the ? markers in order', () {
    expect(convertQuestionMarks('SELECT ?, ? FROM t WHERE a = ?'),
        (sql: 'SELECT @p0, @p1 FROM t WHERE a = @p2', count: 3));
  });

  test('ignores ? in literals, identifiers and comments', () {
    expect(
        convert("SELECT '?', N'it''s ?', \"col?\", [a?]]b] FROM t WHERE x = ?"),
        "SELECT '?', N'it''s ?', \"col?\", [a?]]b] FROM t WHERE x = @p0");
    expect(convert('SELECT ? -- comentário ?\n, ?'),
        'SELECT @p0 -- comentário ?\n, @p1');
    expect(convert('SELECT /* a /* aninhado ? */ ? */ ?'),
        'SELECT /* a /* aninhado ? */ ? */ @p0');
  });

  test('SQL without ? is returned unchanged', () {
    const sql = 'SELECT 1';
    expect(identical(convert(sql), sql), isTrue);
  });

  test('validates the parameter count', () {
    expect(
        () => prepareSql(
            'SELECT ?', PlaceholderIdentifier.onlyQuestionMark, [], null),
        throwsA(isA<tds.InterfaceException>()));
    expect(
        () => prepareSql(
            'SELECT ?', PlaceholderIdentifier.onlyQuestionMark, [1], {'a': 1}),
        throwsA(isA<tds.InterfaceException>()));
    expect(
        prepareSql('SELECT @x', PlaceholderIdentifier.atSign, null, {'x': 1}),
        'SELECT @x');
  });
}
