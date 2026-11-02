import 'tds_types.dart';

/// SQL type of a [SqlParameter].
enum SqlParameterKind {
  bit,
  tinyint,
  smallint,
  int,
  bigint,
  real,
  float,
  decimal,
  money,
  smallmoney,
  date,
  time,
  datetime,
  smalldatetime,
  datetime2,
  datetimeoffset,
  uniqueidentifier,
  char,
  varchar,
  nchar,
  nvarchar,
  binary,
  varbinary,
  xml,
}

/// A parameter with an explicit SQL type, for when the type inferred from the
/// Dart value is not the right one.
///
/// Without it, a `String` is sent as `nvarchar`; compared with a `varchar`
/// column, SQL Server converts the column and can no longer use its index.
/// With [SqlParameter.varchar] the value is sent as `varchar`, encoded in the
/// code page of the connection collation:
///
/// ```dart
/// await conn.query(
///   'SELECT * FROM customers WHERE code = @code',
///   parameters: {'code': SqlParameter.varchar('A-123', length: 20)},
/// );
/// ```
///
/// It works anywhere `parameters` is accepted, inside the [List] or the
/// [Map], and allows typed nulls (`SqlParameter.int(null)`). [output] marks
/// the parameter as `OUTPUT`, for procedures
/// (`MssqlConnection.callProcedure`) and for `query`/`execute`.
class SqlParameter {
  const SqlParameter._(
    this.kind,
    this.value, {
    this.length,
    this.precision,
    this.scale,
    this.isOutput = false,
  });

  /// Pass as `length` for the `(max)` types: `varchar(max)`, `nvarchar(max)`
  /// and `varbinary(max)`.
  static const int max = -1;

  /// `bit`.
  const SqlParameter.bit(bool? value) : this._(SqlParameterKind.bit, value);

  /// `tinyint` (0 to 255).
  const SqlParameter.tinyint(int? value)
      : this._(SqlParameterKind.tinyint, value);

  /// `smallint`.
  const SqlParameter.smallint(int? value)
      : this._(SqlParameterKind.smallint, value);

  /// `int` (32-bit).
  const SqlParameter.int(int? value) : this._(SqlParameterKind.int, value);

  /// `bigint`.
  const SqlParameter.bigint(int? value)
      : this._(SqlParameterKind.bigint, value);

  /// `real` (32-bit floating point).
  const SqlParameter.real(num? value) : this._(SqlParameterKind.real, value);

  /// `float` (64-bit floating point).
  const SqlParameter.float(num? value) : this._(SqlParameterKind.float, value);

  /// `decimal(precision, scale)`. [value] may be a [DecimalValue], [num],
  /// [BigInt] or [String] (`'-12.50'`); digits beyond [scale] are rounded
  /// (half away from zero).
  const SqlParameter.decimal(Object? value, {int precision = 18, int scale = 0})
      : this._(SqlParameterKind.decimal, value,
            precision: precision, scale: scale);

  /// `money`; [value] as in [SqlParameter.decimal], with 4 decimal places.
  const SqlParameter.money(Object? value)
      : this._(SqlParameterKind.money, value);

  /// `smallmoney`; [value] as in [SqlParameter.decimal], with 4 decimal places.
  const SqlParameter.smallmoney(Object? value)
      : this._(SqlParameterKind.smallmoney, value);

  /// `date`; uses only the calendar fields of [value].
  const SqlParameter.date(DateTime? value)
      : this._(SqlParameterKind.date, value);

  /// `time(scale)`, with [value] measured from midnight.
  const SqlParameter.time(Duration? value, {int scale = 7})
      : this._(SqlParameterKind.time, value, scale: scale);

  /// `datetime` (1753 to 9999, 1/300 s precision).
  const SqlParameter.datetime(DateTime? value)
      : this._(SqlParameterKind.datetime, value);

  /// `smalldatetime` (1900 to 2079, one-minute precision).
  const SqlParameter.smalldatetime(DateTime? value)
      : this._(SqlParameterKind.smalldatetime, value);

  /// `datetime2(scale)`; uses the calendar fields of [value] as they are.
  const SqlParameter.datetime2(DateTime? value, {int scale = 7})
      : this._(SqlParameterKind.datetime2, value, scale: scale);

  /// `datetimeoffset(scale)`. [value] is a [DateTimeOffsetValue] or a
  /// [DateTime] (UTC is sent as +00:00; local time with the machine's offset).
  const SqlParameter.datetimeoffset(Object? value, {int scale = 7})
      : this._(SqlParameterKind.datetimeoffset, value, scale: scale);

  /// `uniqueidentifier`, from the text form
  /// (`'6F9619FF-8B86-D011-B42D-00C04FC964FF'`) or from the 16 bytes in text
  /// order.
  const SqlParameter.uniqueidentifier(Object? value)
      : this._(SqlParameterKind.uniqueidentifier, value);

  /// `varchar(length)`, encoded in the code page of the connection collation.
  ///
  /// Without [length], it is sent as `varchar(8000)`, or `varchar(max)` when
  /// longer than 8000 bytes. Characters missing from the code page throw a
  /// `DataException`; use [SqlParameter.nvarchar] for those.
  const SqlParameter.varchar(String? value, {int? length})
      : this._(SqlParameterKind.varchar, value, length: length);

  /// `char(length)`; without [length], uses the value's length.
  const SqlParameter.char(String? value, {int? length})
      : this._(SqlParameterKind.char, value, length: length);

  /// `nvarchar(length)`; without [length], `nvarchar(4000)` or `nvarchar(max)`.
  const SqlParameter.nvarchar(String? value, {int? length})
      : this._(SqlParameterKind.nvarchar, value, length: length);

  /// `nchar(length)`; without [length], uses the value's length.
  const SqlParameter.nchar(String? value, {int? length})
      : this._(SqlParameterKind.nchar, value, length: length);

  /// `varbinary(length)`; without [length], `varbinary(8000)` or
  /// `varbinary(max)`.
  const SqlParameter.varbinary(List<int>? value, {int? length})
      : this._(SqlParameterKind.varbinary, value, length: length);

  /// `binary(length)`; without [length], uses the value's length.
  const SqlParameter.binary(List<int>? value, {int? length})
      : this._(SqlParameterKind.binary, value, length: length);

  /// `xml`.
  const SqlParameter.xml(String? value) : this._(SqlParameterKind.xml, value);

  final SqlParameterKind kind;

  /// The value sent (`null` sends `NULL` with the declared type).
  final Object? value;

  /// Declared length of text and binary types ([max] for `(max)`).
  final int? length;

  /// Precision of a `decimal`.
  final int? precision;

  /// Scale of a `decimal`, and fractional-second digits of `time`,
  /// `datetime2` and `datetimeoffset`.
  final int? scale;

  /// Whether this is an `OUTPUT` parameter.
  final bool isOutput;

  /// Returns this parameter marked as `OUTPUT`; [value] is the input value.
  ///
  /// ```dart
  /// final result = await conn.callProcedure('dbo.next_number',
  ///     parameters: {'series': 'A', 'number': SqlParameter.int(null).output()});
  /// print(result.outputParameters['number']);
  /// ```
  SqlParameter output() => SqlParameter._(kind, value,
      length: length, precision: precision, scale: scale, isOutput: true);

  @override
  String toString() =>
      'SqlParameter.${kind.name}($value${isOutput ? ', OUTPUT' : ''})';
}
