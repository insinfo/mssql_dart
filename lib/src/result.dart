import 'dart:collection';
import 'dart:convert' show base64;
import 'dart:typed_data';

import 'tds_types.dart';

/// Metadata of a result column.
class MssqlColumn {
  const MssqlColumn({
    required this.name,
    required this.typeId,
    required this.nullable,
    this.maxLength,
    this.precision,
    this.scale,
  });

  final String name;

  /// TDS protocol type code (e.g. 0xE7 for nvarchar).
  final int typeId;
  final bool nullable;
  final int? maxLength;
  final int? precision;
  final int? scale;

  static List<MssqlColumn> fromDescription(List<List<dynamic>> description) => [
        for (final d in description)
          MssqlColumn(
            name: d[0] as String,
            typeId: d[1] as int,
            maxLength: d[3] as int?,
            precision: d[4] as int?,
            scale: d[5] as int?,
            nullable: d[6] as bool,
          )
      ];

  @override
  String toString() => 'MssqlColumn($name)';
}

/// A result row, accessible by position or by column name.
///
/// ```dart
/// final row = result.first;
/// final id = row[0] as int;
/// final name = row['name'] as String;
/// ```
class MssqlRow extends UnmodifiableListView<Object?> {
  MssqlRow(List<Object?> values, this._schema) : super(values);

  final RowSchema _schema;

  List<MssqlColumn> get columns => _schema.columns;

  /// The value at a position ([int]) or for a column name ([String],
  /// case-insensitive). An unknown name throws [ArgumentError].
  @override
  Object? operator [](Object? key) => switch (key) {
        int index => super[index],
        String name => super[_schema.indexOf(name)],
        _ => throw ArgumentError.value(key, 'key', 'use int or String'),
      };

  /// Map of column name → value.
  Map<String, Object?> toColumnMap() => {
        for (var i = 0; i < length; i++) _schema.columns[i].name: super[i],
      };

  /// A map ready for `jsonEncode`: `DateTime` as ISO-8601, `time`
  /// (`Duration`) as `HH:MM:SS.ffffff`, `decimal` and `BigInt` as text
  /// (without losing precision), `datetimeoffset` as ISO-8601 with the offset
  /// and binary values as base64.
  Map<String, Object?> toJson() => {
        for (var i = 0; i < length; i++)
          _schema.columns[i].name: jsonSafeValue(super[i]),
      };
}

/// Converts a value read from SQL Server to a type accepted by `jsonEncode`.
Object? jsonSafeValue(Object? value) => switch (value) {
      null || bool() || num() || String() => value,
      DateTime() => value.toIso8601String(),
      Duration() => _formatTime(value),
      DecimalValue() => value.toJson(),
      DateTimeOffsetValue() => value.toJson(),
      BigInt() => value.toString(),
      Uint8List() => base64.encode(value),
      List<int>() => base64.encode(value),
      _ => value.toString(),
    };

String _formatTime(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final micros = d.inMicroseconds % Duration.microsecondsPerSecond;
  final text =
      '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return micros == 0 ? text : '$text.${micros.toString().padLeft(6, '0')}';
}

/// The columns of a result set and their name index, shared by its rows.
class RowSchema {
  RowSchema(this.columns);

  final List<MssqlColumn> columns;
  late final Map<String, int> _byName = {
    for (var i = columns.length - 1; i >= 0; i--)
      columns[i].name.toLowerCase(): i,
  };

  int indexOf(String name) {
    final index = _byName[name.toLowerCase()];
    if (index == null) {
      throw ArgumentError.value(name, 'name', 'no such column');
    }
    return index;
  }
}

/// The rows of a command's first result set.
class MssqlResult extends UnmodifiableListView<MssqlRow> {
  MssqlResult(
    super.rows, {
    required this.columns,
    required this.affectedRows,
    this.outputParameters = const {},
  });

  final List<MssqlColumn> columns;

  /// Rows affected as reported by the server, or -1.
  final int affectedRows;

  /// Values of the `OUTPUT` parameters (`SqlParameter.output`), keyed by name
  /// without the `@`.
  final Map<String, Object?> outputParameters;

  /// The rows as maps ready for `jsonEncode` (see [MssqlRow.toJson]).
  List<Map<String, Object?>> toJson() => [for (final row in this) row.toJson()];
}

/// The result of `MssqlConnection.callProcedure`.
class MssqlProcedureResult {
  MssqlProcedureResult({
    required this.resultSets,
    required this.outputParameters,
    required this.returnStatus,
    required this.affectedRows,
  });

  /// All result sets returned by the procedure, in order.
  final List<MssqlResult> resultSets;

  /// Values of the `OUTPUT` parameters, keyed by name without the `@`;
  /// parameters passed by position (in a [List]) are keyed by their position
  /// (`'0'`, `'1'`...).
  final Map<String, Object?> outputParameters;

  /// The procedure's `RETURN` value (0 when it does not use `RETURN`), or
  /// `null` if the server did not report it.
  final int? returnStatus;

  /// Rows affected by the last statement of the procedure that reported them,
  /// or -1.
  final int affectedRows;

  /// The first result set, or an empty one if there was none.
  MssqlResult get firstResultSet => resultSets.isEmpty
      ? MssqlResult(const [], columns: const [], affectedRows: affectedRows)
      : resultSets.first;
}
