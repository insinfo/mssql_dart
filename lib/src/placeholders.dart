import 'dart:collection';

import 'tds_base.dart' as tds;

/// Style of the parameter placeholders in SQL text.
class PlaceholderIdentifier {
  const PlaceholderIdentifier._(this.value);

  final String value;

  /// SQL Server default: `@name`, or `@p0`, `@p1`... for positional
  /// parameters. E.g. `SELECT * FROM livro WHERE titulo = @p0`.
  static const PlaceholderIdentifier atSign = PlaceholderIdentifier._('@');

  /// PDO/JDBC-style question marks: `SELECT * FROM livro WHERE titulo = ?`.
  ///
  /// Each `?` outside literals, identifiers and comments becomes `@p0`,
  /// `@p1`... in order of appearance. A `?` inside `'...'` is not a
  /// parameter.
  static const PlaceholderIdentifier onlyQuestionMark =
      PlaceholderIdentifier._('?');

  @override
  String toString() => switch (this) {
        atSign => 'PlaceholderIdentifier.atSign',
        _ => 'PlaceholderIdentifier.onlyQuestionMark',
      };
}

/// SQL with `?` converted to `@pN`, plus the number of placeholders found.
typedef ConvertedSql = ({String sql, int count});

final LinkedHashMap<String, ConvertedSql> _cache = LinkedHashMap();
const int _cacheCapacity = 256;

/// Converts the `?` placeholders in [sql] to `@p0`, `@p1`...
///
/// Literals (`'...'`, `N'...'`), identifiers (`"..."`, `[...]`) and comments
/// (`-- ...` and `/* ... */`, which can be nested in T-SQL) are skipped.
ConvertedSql convertQuestionMarks(String sql) {
  final cached = _cache.remove(sql);
  if (cached != null) {
    _cache[sql] = cached;
    return cached;
  }
  final converted = _convert(sql);
  _cache[sql] = converted;
  if (_cache.length > _cacheCapacity) {
    _cache.remove(_cache.keys.first);
  }
  return converted;
}

const int _quote = 0x27; // '
const int _dquote = 0x22; // "
const int _lbracket = 0x5B; // [
const int _rbracket = 0x5D; // ]
const int _dash = 0x2D; // -
const int _slash = 0x2F; // /
const int _star = 0x2A; // *
const int _newline = 0x0A;
const int _question = 0x3F; // ?

ConvertedSql _convert(String sql) {
  final out = StringBuffer();
  var count = 0;
  var start = 0; // start of the span not yet copied
  var i = 0;
  final n = sql.length;

  int skipUntil(int from, int close, {bool doubledEscapes = true}) {
    var j = from;
    while (j < n) {
      if (sql.codeUnitAt(j) == close) {
        if (doubledEscapes && j + 1 < n && sql.codeUnitAt(j + 1) == close) {
          j += 2;
          continue;
        }
        return j + 1;
      }
      j++;
    }
    return n;
  }

  while (i < n) {
    final c = sql.codeUnitAt(i);
    switch (c) {
      case _quote:
        i = skipUntil(i + 1, _quote);
      case _dquote:
        i = skipUntil(i + 1, _dquote);
      case _lbracket:
        i = skipUntil(i + 1, _rbracket);
      case _dash when i + 1 < n && sql.codeUnitAt(i + 1) == _dash:
        final end = sql.indexOf(String.fromCharCode(_newline), i + 2);
        i = end < 0 ? n : end + 1;
      case _slash when i + 1 < n && sql.codeUnitAt(i + 1) == _star:
        var depth = 1;
        i += 2;
        while (i < n && depth > 0) {
          final d = sql.codeUnitAt(i);
          if (d == _slash && i + 1 < n && sql.codeUnitAt(i + 1) == _star) {
            depth++;
            i += 2;
          } else if (d == _star &&
              i + 1 < n &&
              sql.codeUnitAt(i + 1) == _slash) {
            depth--;
            i += 2;
          } else {
            i++;
          }
        }
      case _question:
        out
          ..write(sql.substring(start, i))
          ..write('@p')
          ..write(count++);
        i++;
        start = i;
      default:
        i++;
    }
  }
  if (count == 0) return (sql: sql, count: 0);
  out.write(sql.substring(start));
  return (sql: out.toString(), count: count);
}

/// Applies [identifier] to [sql].
///
/// With [PlaceholderIdentifier.onlyQuestionMark], also checks that the number
/// of positional parameters matches the number of placeholders.
String prepareSql(
  String sql,
  PlaceholderIdentifier identifier,
  List<dynamic>? params,
  Map<String, dynamic>? namedParams,
) {
  if (identifier != PlaceholderIdentifier.onlyQuestionMark) return sql;
  if (namedParams != null && namedParams.isNotEmpty) {
    throw tds.InterfaceException(
      'PlaceholderIdentifier.onlyQuestionMark accepts only positional parameters',
    );
  }
  final converted = convertQuestionMarks(sql);
  final given = params?.length ?? 0;
  if (converted.count != given) {
    throw tds.InterfaceException(
      'The SQL has ${converted.count} ? placeholder(s) but $given parameter(s) were passed',
    );
  }
  return converted.sql;
}
