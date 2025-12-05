import 'dart:math' as math;
import 'dart:typed_data';

import 'collate.dart';
import 'tds_base.dart' as tds;

/// Factory para construir objetos de timezone customizados a partir do offset em minutos.
typedef TzInfoFactory = Object? Function(int offsetMinutes);

/// Represents an abstract SQL type.
abstract class SqlType {
  const SqlType();

  /// Returns the T-SQL declaration string for the type.
  String get declaration;
}

/// Common base class for fixed-size SQL types.
abstract class SizedSqlType extends SqlType {
  final int size;
  const SizedSqlType(this.size);
}

class BitType extends SqlType {
  const BitType();
  @override
  String get declaration => 'BIT';
}

class TinyIntType extends SqlType {
  const TinyIntType();
  @override
  String get declaration => 'TINYINT';
}

class SmallIntType extends SqlType {
  const SmallIntType();
  @override
  String get declaration => 'SMALLINT';
}

class IntType extends SqlType {
  const IntType();
  @override
  String get declaration => 'INT';
}

class BigIntType extends SqlType {
  const BigIntType();
  @override
  String get declaration => 'BIGINT';
}

class RealType extends SqlType {
  const RealType();
  @override
  String get declaration => 'REAL';
}

class FloatType extends SqlType {
  const FloatType();
  @override
  String get declaration => 'FLOAT';
}

class BinaryType extends SizedSqlType {
  const BinaryType({int size = 30}) : super(size);
  @override
  String get declaration => 'BINARY($size)';
}

class VarBinaryType extends SizedSqlType {
  const VarBinaryType({int size = 30}) : super(size);
  @override
  String get declaration => 'VARBINARY($size)';
}

class VarBinaryMaxType extends SqlType {
  const VarBinaryMaxType();
  @override
  String get declaration => 'VARBINARY(MAX)';
}

class ImageType extends SqlType {
  const ImageType();
  @override
  String get declaration => 'IMAGE';
}

class CharType extends SizedSqlType {
  const CharType({int size = 30}) : super(size);
  @override
  String get declaration => 'CHAR($size)';
}

class VarCharType extends SizedSqlType {
  const VarCharType({int size = 30}) : super(size);
  @override
  String get declaration => 'VARCHAR($size)';
}

class VarCharMaxType extends SqlType {
  const VarCharMaxType();
  @override
  String get declaration => 'VARCHAR(MAX)';
}

class NCharType extends SizedSqlType {
  const NCharType({int size = 30}) : super(size);
  @override
  String get declaration => 'NCHAR($size)';
}

class NVarCharType extends SizedSqlType {
  const NVarCharType({int size = 30}) : super(size);
  @override
  String get declaration => 'NVARCHAR($size)';
}

class NVarCharMaxType extends SqlType {
  const NVarCharMaxType();
  @override
  String get declaration => 'NVARCHAR(MAX)';
}

class TextType extends SqlType {
  const TextType();
  @override
  String get declaration => 'TEXT';
}

class NTextType extends SqlType {
  const NTextType();
  @override
  String get declaration => 'NTEXT';
}

class XmlType extends SqlType {
  const XmlType();
  @override
  String get declaration => 'XML';
}

class SmallMoneyType extends SqlType {
  const SmallMoneyType();
  @override
  String get declaration => 'SMALLMONEY';
}

class MoneyType extends SqlType {
  const MoneyType();
  @override
  String get declaration => 'MONEY';
}

class DecimalType extends SqlType {
  final int precision;
  final int scale;
  const DecimalType({this.precision = 18, this.scale = 0});

  factory DecimalType.fromNum(num value) {
    final asString = value.toString();
    final dot = asString.indexOf('.');
    if (dot == -1) {
      return DecimalType(
        precision: math.max(asString.replaceAll('-', '').length, 1),
        scale: 0,
      );
    }
    final whole = asString.substring(0, dot).replaceAll('-', '');
    final frac = asString.substring(dot + 1);
    return DecimalType(
      precision: math.max(whole.length + frac.length, 1),
      scale: frac.length,
    );
  }

  @override
  String get declaration => 'DECIMAL($precision, $scale)';
}

class DecimalValue {
  final BigInt unscaledValue;
  final int scale;
  const DecimalValue({required this.unscaledValue, required this.scale});

  bool get isNegative => unscaledValue.isNegative;

  double toDouble() {
    if (scale == 0) {
      return unscaledValue.toDouble();
    }
    return unscaledValue.toDouble() / math.pow(10, scale);
  }

  num toNum() => scale == 0 ? unscaledValue.toInt() : toDouble();

  @override
  String toString() {
    if (scale == 0) {
      return unscaledValue.toString();
    }
    final absValue = unscaledValue.abs().toString();
    final padded = absValue.padLeft(scale + 1, '0');
    final whole = padded.substring(0, padded.length - scale);
    final frac = padded.substring(padded.length - scale);
    final sign = unscaledValue.isNegative ? '-' : '';
    return '$sign$whole.$frac';
  }
}

class UniqueIdentifierType extends SqlType {
  const UniqueIdentifierType();
  @override
  String get declaration => 'UNIQUEIDENTIFIER';
}

class VariantType extends SqlType {
  const VariantType();
  @override
  String get declaration => 'SQL_VARIANT';
}

class SmallDateTimeType extends SqlType {
  const SmallDateTimeType();
  @override
  String get declaration => 'SMALLDATETIME';
}

class DateTimeType extends SqlType {
  const DateTimeType();
  @override
  String get declaration => 'DATETIME';
}

class DateType extends SqlType {
  const DateType();
  @override
  String get declaration => 'DATE';
}

class TimeType extends SqlType {
  final int precision;
  const TimeType({this.precision = 6});
  @override
  String get declaration => 'TIME($precision)';
}

class DateTime2Type extends SqlType {
  final int precision;
  const DateTime2Type({this.precision = 7});
  @override
  String get declaration => 'DATETIME2($precision)';
}

class DateTimeOffsetType extends SqlType {
  final int precision;
  const DateTimeOffsetType({this.precision = 7});
  @override
  String get declaration => 'DATETIMEOFFSET($precision)';
}

class DateTimeOffsetValue {
  final DateTime utc;
  final int offsetMinutes;
  const DateTimeOffsetValue({required this.utc, required this.offsetMinutes});

  Duration get offset => Duration(minutes: offsetMinutes);
  DateTime get localDateTime => utc.add(offset);

  @override
  String toString() {
    final absMinutes = offsetMinutes.abs();
    final hours = (absMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (absMinutes % 60).toString().padLeft(2, '0');
    final sign = offsetMinutes >= 0 ? '+' : '-';
    final localIso = localDateTime.toIso8601String();
    return '$localIso (UTC$sign$hours:$minutes)';
  }
}

class TableType extends SqlType {
  final String typSchema;
  final String typName;
  final List<tds.Column>? columns;

  const TableType({
    this.typSchema = '',
    this.typName = '',
    this.columns,
  });

  @override
  String get declaration {
    final schema = typSchema.isNotEmpty ? '$typSchema.' : '';
    return '${schema + typName} READONLY';
  }
}

/// Represents the value of a table-valued parameter (TVP).
class TableValuedParam {
  final String typSchema;
  final String typName;
  List<tds.Column>? columns;
  Iterable<List<dynamic>>? rows;

  TableValuedParam({
    String? typeName,
    this.columns,
    this.rows,
  })  : typSchema = _schemaFrom(typeName),
        typName = _nameFrom(typeName);

  static String _schemaFrom(String? typeName) {
    if (typeName == null || typeName.isEmpty) {
      return '';
    }
    final parts = typeName.split('.');
    return parts.length == 2 ? parts[0] : '';
  }

  static String _nameFrom(String? typeName) {
    if (typeName == null || typeName.isEmpty) {
      return '';
    }
    final parts = typeName.split('.');
    return parts.length == 2 ? parts[1] : parts[0];
  }

  bool get isNull => rows == null;

  Iterable<dynamic>? peekRow() {
    final currentRows = rows;
    if (currentRows == null) {
      return null;
    }
    final iterator = currentRows.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    final first = iterator.current;
    rows = [first, ...currentRows.skip(1)];
    return first;
  }
}

/// Base class for serializers. Real serializers will implement read/write later.
abstract class BaseTypeSerializer {
  int get typeId;

  String get debugName;

  void writeValue(dynamic value) {
    throw UnimplementedError('Serializer $debugName.writeValue ainda não foi portado');
  }

  dynamic readValue() {
    throw UnimplementedError('Serializer $debugName.readValue ainda não foi portado');
  }
}

class PlaceholderSerializer extends BaseTypeSerializer {
  @override
  final int typeId;
  @override
  final String debugName;
  final SqlType sqlType;

  PlaceholderSerializer({required this.typeId, required this.sqlType})
      : debugName = sqlType.declaration;
}

class SerializerFactory {
  final int tdsVersion;
  SerializerFactory(this.tdsVersion);

  BaseTypeSerializer getTypeSerializer(int typeId) {
    final serializer = _builtInSerializers[typeId];
    if (serializer == null) {
      throw tds.InterfaceError('Tipo TDS desconhecido: $typeId');
    }
    return serializer;
  }

  SqlType longBinaryType() {
    return tdsVersion >= tds.TDS72 ? const VarBinaryMaxType() : const ImageType();
  }

  SqlType longVarcharType() {
    return tdsVersion >= tds.TDS72 ? const VarCharMaxType() : const TextType();
  }

  SqlType longStringType() {
    return tdsVersion >= tds.TDS72 ? const NVarCharMaxType() : const NTextType();
  }

  SqlType datetimeType({int precision = 6}) {
    return tdsVersion >= tds.TDS72
        ? DateTime2Type(precision: precision)
        : const DateTimeType();
  }

  bool supportsDateTimeWithTz() => tdsVersion >= tds.TDS72;

  SqlType datetimeWithTz({int precision = 6}) {
    if (!supportsDateTimeWithTz()) {
      throw tds.DataError(
        'A versão TDS atual não suporta DATETIMEOFFSET (necessário TDS 7.2+)',
      );
    }
    return DateTimeOffsetType(precision: precision);
  }

  SqlType dateType() {
    return tdsVersion >= tds.TDS72 ? const DateType() : const DateTimeType();
  }

  SqlType timeType({int precision = 6}) {
    if (tdsVersion < tds.TDS72) {
      throw tds.DataError('A versão TDS atual não suporta TIME');
    }
    return TimeType(precision: precision);
  }

  BaseTypeSerializer serializerByType({
    required SqlType sqlType,
    Collation? collation,
  }) {
    // ignore: unused_local_variable
    final effectiveCollation = collation ?? raw_collation;
    final typeId = _mapSqlTypeToTypeId(sqlType);
    if (typeId == null) {
      throw ArgumentError('Não foi possível mapear ${sqlType.declaration} para um typeId TDS');
    }
    return PlaceholderSerializer(typeId: typeId, sqlType: sqlType);
  }

  static final Map<int, BaseTypeSerializer> _builtInSerializers = {
    tds.BITTYPE:
        PlaceholderSerializer(typeId: tds.BITTYPE, sqlType: const BitType()),
    tds.INT1TYPE:
        PlaceholderSerializer(typeId: tds.INT1TYPE, sqlType: const TinyIntType()),
    tds.INT2TYPE:
        PlaceholderSerializer(typeId: tds.INT2TYPE, sqlType: const SmallIntType()),
    tds.INT4TYPE:
        PlaceholderSerializer(typeId: tds.INT4TYPE, sqlType: const IntType()),
    tds.INT8TYPE:
        PlaceholderSerializer(typeId: tds.INT8TYPE, sqlType: const BigIntType()),
    tds.FLT4TYPE:
        PlaceholderSerializer(typeId: tds.FLT4TYPE, sqlType: const RealType()),
    tds.FLT8TYPE:
        PlaceholderSerializer(typeId: tds.FLT8TYPE, sqlType: const FloatType()),
    tds.MONEYTYPE:
        PlaceholderSerializer(typeId: tds.MONEYTYPE, sqlType: const MoneyType()),
    tds.MONEY4TYPE: PlaceholderSerializer(
      typeId: tds.MONEY4TYPE,
      sqlType: const SmallMoneyType(),
    ),
    tds.BIGCHARTYPE:
        PlaceholderSerializer(typeId: tds.BIGCHARTYPE, sqlType: const CharType()),
    tds.BIGVARCHRTYPE: PlaceholderSerializer(
      typeId: tds.BIGVARCHRTYPE,
      sqlType: const VarCharType(),
    ),
    tds.NCHARTYPE:
        PlaceholderSerializer(typeId: tds.NCHARTYPE, sqlType: const NCharType()),
    tds.NVARCHARTYPE: PlaceholderSerializer(
      typeId: tds.NVARCHARTYPE,
      sqlType: const NVarCharType(),
    ),
    tds.TEXTTYPE:
        PlaceholderSerializer(typeId: tds.TEXTTYPE, sqlType: const TextType()),
    tds.NTEXTTYPE:
        PlaceholderSerializer(typeId: tds.NTEXTTYPE, sqlType: const NTextType()),
    tds.XMLTYPE:
        PlaceholderSerializer(typeId: tds.XMLTYPE, sqlType: const XmlType()),
    tds.BIGBINARYTYPE: PlaceholderSerializer(
      typeId: tds.BIGBINARYTYPE,
      sqlType: const BinaryType(),
    ),
    tds.BIGVARBINTYPE: PlaceholderSerializer(
      typeId: tds.BIGVARBINTYPE,
      sqlType: const VarBinaryType(),
    ),
    tds.IMAGETYPE:
        PlaceholderSerializer(typeId: tds.IMAGETYPE, sqlType: const ImageType()),
    tds.DECIMALNTYPE: PlaceholderSerializer(
      typeId: tds.DECIMALNTYPE,
      sqlType: const DecimalType(),
    ),
    tds.NUMERICNTYPE: PlaceholderSerializer(
      typeId: tds.NUMERICNTYPE,
      sqlType: const DecimalType(),
    ),
    tds.SSVARIANTTYPE: PlaceholderSerializer(
      typeId: tds.SSVARIANTTYPE,
      sqlType: const VariantType(),
    ),
    tds.DATENTYPE:
        PlaceholderSerializer(typeId: tds.DATENTYPE, sqlType: const DateType()),
    tds.TIMENTYPE:
        PlaceholderSerializer(typeId: tds.TIMENTYPE, sqlType: const TimeType()),
    tds.DATETIME2NTYPE: PlaceholderSerializer(
      typeId: tds.DATETIME2NTYPE,
      sqlType: const DateTime2Type(),
    ),
    tds.DATETIMEOFFSETNTYPE: PlaceholderSerializer(
      typeId: tds.DATETIMEOFFSETNTYPE,
      sqlType: const DateTimeOffsetType(),
    ),
    tds.DATETIMETYPE: PlaceholderSerializer(
      typeId: tds.DATETIMETYPE,
      sqlType: const DateTimeType(),
    ),
    tds.DATETIM4TYPE: PlaceholderSerializer(
      typeId: tds.DATETIM4TYPE,
      sqlType: const SmallDateTimeType(),
    ),
    tds.GUIDTYPE: PlaceholderSerializer(
      typeId: tds.GUIDTYPE,
      sqlType: const UniqueIdentifierType(),
    ),
    tds.TVPTYPE: PlaceholderSerializer(
      typeId: tds.TVPTYPE,
      sqlType: const TableType(),
    ),
  };
}

int? _mapSqlTypeToTypeId(SqlType type) {
  if (type is BitType) return tds.BITTYPE;
  if (type is TinyIntType) return tds.INT1TYPE;
  if (type is SmallIntType) return tds.INT2TYPE;
  if (type is IntType) return tds.INT4TYPE;
  if (type is BigIntType) return tds.INT8TYPE;
  if (type is RealType) return tds.FLT4TYPE;
  if (type is FloatType) return tds.FLT8TYPE;
  if (type is SmallMoneyType) return tds.MONEY4TYPE;
  if (type is MoneyType) return tds.MONEYTYPE;
  if (type is CharType) return tds.BIGCHARTYPE;
  if (type is VarCharType || type is VarCharMaxType) return tds.BIGVARCHRTYPE;
  if (type is NCharType) return tds.NCHARTYPE;
  if (type is NVarCharType || type is NVarCharMaxType) return tds.NVARCHARTYPE;
  if (type is TextType) return tds.TEXTTYPE;
  if (type is NTextType) return tds.NTEXTTYPE;
  if (type is XmlType) return tds.XMLTYPE;
  if (type is BinaryType) return tds.BIGBINARYTYPE;
  if (type is VarBinaryType || type is VarBinaryMaxType) return tds.BIGVARBINTYPE;
  if (type is DecimalType) return tds.DECIMALNTYPE;
  if (type is VariantType) return tds.SSVARIANTTYPE;
  if (type is SmallDateTimeType) return tds.DATETIM4TYPE;
  if (type is DateTimeType) return tds.DATETIMETYPE;
  if (type is DateType) return tds.DATENTYPE;
  if (type is TimeType) return tds.TIMENTYPE;
  if (type is DateTime2Type) return tds.DATETIME2NTYPE;
  if (type is DateTimeOffsetType) return tds.DATETIMEOFFSETNTYPE;
  if (type is UniqueIdentifierType) return tds.GUIDTYPE;
  if (type is TableType) return tds.TVPTYPE;
  return null;
}

/// Infers SQL types from Dart values, similar to pytds.TdsTypeInferrer.
class TdsTypeInferrer {
  final SerializerFactory typeFactory;
  final Collation collation;
  final bool bytesToUnicode;
  final bool allowTz;

  TdsTypeInferrer({
    required this.typeFactory,
    Collation? collation,
    this.bytesToUnicode = false,
    this.allowTz = false,
  }) : collation = collation ?? raw_collation;

  SqlType fromValue(dynamic value) {
    if (value == null) {
      return const NVarCharType(size: 1);
    }
    return _fromClassValue(value, value.runtimeType);
  }

  SqlType fromType(Type type) {
    return _fromClassValue(null, type);
  }

  SqlType _fromClassValue(dynamic value, Type type) {
    if (type == bool || value is bool) {
      return const BitType();
    } else if (value is int || type == int) {
      if (value == null) {
        return const IntType();
      }
      if (value >= -(1 << 31) && value <= (1 << 31) - 1) {
        return const IntType();
      } else if (value >= -(1 << 63) && value <= (1 << 63) - 1) {
        return const BigIntType();
      }
      return const DecimalType(precision: 38, scale: 0);
    } else if (value is double || type == double) {
      return const FloatType();
    } else if (value is Uint8List || value is List<int>) {
      if (bytesToUnicode) {
        return typeFactory.longStringType();
      }
      final length = value is List ? value.length : (value as Uint8List).length;
      if (length <= 8000) {
        return const VarBinaryType(size: 8000);
      }
      return typeFactory.longBinaryType();
    } else if (value is String || type == String) {
      return typeFactory.longStringType();
    } else if (value is BigInt || type == BigInt) {
      return const DecimalType(precision: 38, scale: 0);
    } else if (value is DateTime || type == DateTime) {
      final dateTime = value as DateTime?;
      if (dateTime != null && dateTime.isUtc && allowTz &&
          typeFactory.supportsDateTimeWithTz()) {
        return typeFactory.datetimeWithTz();
      }
      return typeFactory.datetimeType();
    } else if (value is DateTime) {
      return const DateType();
    } else if (value is TableValuedParam) {
      var columns = value.columns;
      final rows = value.rows;
      if (columns == null && rows != null) {
        final iterator = rows.iterator;
        if (iterator.moveNext()) {
          final firstRow = iterator.current;
          columns = [];
          for (final cell in firstRow) {
            final columnType = fromValue(cell);
            columns.add(tds.Column(type: columnType));
          }
          value.rows = [firstRow, ...rows.skip(1)];
        } else {
          throw tds.DataError('Não há linhas para inferir o schema do TVP');
        }
      }
      return TableType(
        typSchema: value.typSchema,
        typName: value.typName,
        columns: columns,
      );
    }

    throw tds.DataError('Não é possível inferir tipo TDS para valor ${value.runtimeType}');
  }
}
