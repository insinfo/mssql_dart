import 'dart:convert';
import 'dart:typed_data';

import 'collate.dart';
import 'sql_parameter.dart';
import 'tds_base.dart' as tds;
import 'tds_types.dart';

/// Growable synchronous write buffer used to build whole requests before
/// handing them to the [AsyncTdsWriter] in a single `write`.
class TdsBufferWriter {
  TdsBufferWriter([int initialCapacity = 256])
      : _buf = Uint8List(initialCapacity),
        _data = ByteData(0) {
    _data = ByteData.sublistView(_buf);
  }

  Uint8List _buf;
  ByteData _data;
  int _len = 0;

  int get length => _len;

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);

  void _ensure(int extra) {
    final needed = _len + extra;
    if (needed <= _buf.length) return;
    var capacity = _buf.length * 2;
    if (capacity < needed) capacity = needed;
    final grown = Uint8List(capacity)..setRange(0, _len, _buf);
    _buf = grown;
    _data = ByteData.sublistView(grown);
  }

  void byte(int value) {
    _ensure(1);
    _buf[_len++] = value;
  }

  void uint16(int value) {
    _ensure(2);
    _data.setUint16(_len, value, Endian.little);
    _len += 2;
  }

  void int32(int value) {
    _ensure(4);
    _data.setInt32(_len, value, Endian.little);
    _len += 4;
  }

  void uint32(int value) {
    _ensure(4);
    _data.setUint32(_len, value, Endian.little);
    _len += 4;
  }

  void int64(int value) {
    _ensure(8);
    _data.setInt64(_len, value, Endian.little);
    _len += 8;
  }

  void float64(double value) {
    _ensure(8);
    _data.setFloat64(_len, value, Endian.little);
    _len += 8;
  }

  /// Writes [value] as a little-endian unsigned integer of [size] bytes.
  void uintN(int value, int size) {
    _ensure(size);
    for (var i = 0; i < size; i++) {
      _buf[_len++] = value & 0xFF;
      value >>= 8;
    }
  }

  void bytes(List<int> data) {
    _ensure(data.length);
    _buf.setRange(_len, _len + data.length, data);
    _len += data.length;
  }

  /// Writes [value] as UTF-16LE (Dart code units copied straight in).
  void ucs2(String value) {
    _ensure(value.length * 2);
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      _buf[_len++] = unit & 0xFF;
      _buf[_len++] = unit >> 8;
    }
  }

  /// Writes a B_VARCHAR: length in characters (1 byte) followed by UTF-16LE.
  void bVarchar(String value) {
    byte(value.length);
    ucs2(value);
  }
}

const int _spExecuteSql = 10;
const int _fByRefValue = 0x01;

/// Separates the requests of an RPC batch (TDS 7.2+, MS-TDS 2.2.6.6).
const int _batchFlag = 0xFF;

/// Largest `nvarchar(n)`/`varbinary(n)`, in bytes, before switching to `(max)`.
const int _maxShortBytes = 8000;

/// Collation used for text parameters: the 5 TYPE_INFO bytes and the code
/// page that encodes `varchar`/`char`.
class RpcCollation {
  RpcCollation(this.collation)
      : bytes = collation == null
            ? Uint8List(5)
            : Uint8List.fromList(collation.pack());

  final Collation? collation;
  final Uint8List bytes;

  late final Encoding codec = collation?.get_codec() ?? latin1;

  /// Encodes [value] in the collation's code page.
  Uint8List encode(String value) {
    try {
      final encoded = codec.encode(value);
      return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
    } catch (_) {
      throw tds.DataException(
          'Text contains characters that do not exist in code page '
          '${codec.name} of the connection collation; '
          'use SqlParameter.nvarchar');
    }
  }
}

/// Encodes an RPC call to `sp_executesql` with binary parameters
/// (TYPE_INFO + value), never embedding the values in the SQL text.
void encodeExecuteSql(
  TdsBufferWriter out,
  String sql,
  Map<String, dynamic> params,
  RpcCollation collation,
) {
  out
    ..uint16(0xFFFF)
    ..uint16(_spExecuteSql)
    ..uint16(0);
  final encoders = <_ParamEncoder>[];
  final definition = StringBuffer();
  params.forEach((name, value) {
    final encoder =
        _ParamEncoder.forValue(_normalizeName(name), value, collation);
    if (definition.isNotEmpty) definition.write(', ');
    definition
      ..write(encoder.name)
      ..write(' ')
      ..write(encoder.declaration);
    if (encoder.output) definition.write(' OUTPUT');
    encoders.add(encoder);
  });
  _writeNVarChar(out, '', sql, collation);
  if (encoders.isEmpty) return;
  _writeNVarChar(out, '', definition.toString(), collation);
  for (final encoder in encoders) {
    encoder.write(out, collation);
  }
}

/// Writes the separator between two requests of an RPC batch.
void writeRpcBatchSeparator(TdsBufferWriter out) => out.byte(_batchFlag);

/// Encodes an RPC call to the procedure [name] (by name, without
/// `sp_executesql`). Entries of [params] with an empty name are positional.
void encodeProcedureCall(
  TdsBufferWriter out,
  String name,
  List<(String, Object?)> params,
  RpcCollation collation,
) {
  if (name.isEmpty || name.length > 0xFFFE) {
    throw ArgumentError.value(name, 'name', 'invalid procedure name');
  }
  out
    ..uint16(name.length)
    ..ucs2(name)
    ..uint16(0);
  for (final (paramName, value) in params) {
    final normalized = paramName.isEmpty ? '' : _normalizeName(paramName);
    _ParamEncoder.forValue(normalized, value, collation).write(out, collation);
  }
}

String _normalizeName(String name) => name.startsWith('@') ? name : '@$name';

void _writeNVarChar(
    TdsBufferWriter out, String name, String value, RpcCollation collation) {
  out
    ..bVarchar(name)
    ..byte(0);
  _writeNVarCharTypeAndValue(out, value, collation);
}

void _writeNVarCharTypeAndValue(
    TdsBufferWriter out, String? value, RpcCollation collation) {
  final byteLength = (value?.length ?? 0) * 2;
  final isMax = byteLength > _maxShortBytes;
  out
    ..byte(tds.NVARCHARTYPE)
    ..uint16(isMax ? 0xFFFF : _maxShortBytes)
    ..bytes(collation.bytes);
  if (isMax) {
    _writePlp(out, value == null ? null : (w) => w.ucs2(value), byteLength);
  } else if (value == null) {
    out.uint16(0xFFFF);
  } else {
    out
      ..uint16(byteLength)
      ..ucs2(value);
  }
}

void _writeVarBinaryTypeAndValue(TdsBufferWriter out, List<int>? value) {
  final isMax = (value?.length ?? 0) > _maxShortBytes;
  out
    ..byte(tds.BIGVARBINTYPE)
    ..uint16(isMax ? 0xFFFF : _maxShortBytes);
  if (isMax) {
    _writePlp(out, value == null ? null : (w) => w.bytes(value), value!.length);
  } else if (value == null) {
    out.uint16(0xFFFF);
  } else {
    out
      ..uint16(value.length)
      ..bytes(value);
  }
}

/// Writes a PLP value of known length, in a single chunk when it fits.
void _writePlp(
    TdsBufferWriter out, void Function(TdsBufferWriter)? body, int length) {
  if (body == null) {
    out.int64(-1); // PLP_NULL
    return;
  }
  out.int64(length);
  if (length > 0) {
    // The payload is written in one go; the chunk length is the total, which
    // the server accepts up to 2^32-1 bytes.
    out.uint32(length);
    body(out);
  }
  out.uint32(0);
}

typedef _TypeAndValueWriter = void Function(
    TdsBufferWriter out, RpcCollation collation);

class _ParamEncoder {
  _ParamEncoder(this.name, this.declaration, this._writeTypeAndValue,
      {this.output = false});

  final String name;
  final String declaration;
  final bool output;
  final _TypeAndValueWriter _writeTypeAndValue;

  void write(TdsBufferWriter out, RpcCollation collation) {
    out
      ..bVarchar(name)
      ..byte(output ? _fByRefValue : 0);
    _writeTypeAndValue(out, collation);
  }

  factory _ParamEncoder.forValue(
      String name, dynamic value, RpcCollation collation) {
    if (value is SqlParameter) {
      return _typedParameter(name, value, collation);
    }
    if (value is tds.Param) {
      return _ParamEncoder._typed(name, value, collation);
    }
    if (value == null) {
      // No known type: a NULL NVARCHAR converts implicitly to any type.
      return _ParamEncoder(name, 'nvarchar(4000)',
          (out, c) => _writeNVarCharTypeAndValue(out, null, c));
    }
    if (value is bool) {
      return _ParamEncoder(name, 'bit', (out, _) {
        out
          ..byte(tds.BITNTYPE)
          ..byte(1)
          ..byte(1)
          ..byte(value ? 1 : 0);
      });
    }
    if (value is int) {
      final small = value >= -0x80000000 && value <= 0x7FFFFFFF;
      return _ParamEncoder(name, small ? 'int' : 'bigint', (out, _) {
        out
          ..byte(tds.INTNTYPE)
          ..byte(small ? 4 : 8)
          ..byte(small ? 4 : 8);
        small ? out.int32(value) : out.int64(value);
      });
    }
    if (value is double) {
      _checkFinite(value);
      return _ParamEncoder(name, 'float', (out, _) {
        out
          ..byte(tds.FLTNTYPE)
          ..byte(8)
          ..byte(8)
          ..float64(value);
      });
    }
    if (value is String) {
      final isMax = value.length * 2 > _maxShortBytes;
      return _ParamEncoder(name, isMax ? 'nvarchar(max)' : 'nvarchar(4000)',
          (out, c) => _writeNVarCharTypeAndValue(out, value, c));
    }
    if (value is List<int>) {
      final isMax = value.length > _maxShortBytes;
      return _ParamEncoder(name, isMax ? 'varbinary(max)' : 'varbinary(8000)',
          (out, _) => _writeVarBinaryTypeAndValue(out, value));
    }
    if (value is DateTime) {
      return _typedParameter(name, SqlParameter.datetime2(value), collation);
    }
    if (value is DateTimeOffsetValue) {
      return _typedParameter(
          name, SqlParameter.datetimeoffset(value), collation);
    }
    if (value is Duration) {
      return _typedParameter(name, SqlParameter.time(value), collation);
    }
    if (value is DecimalValue) {
      return _decimal(name, value.unscaledValue, 38, value.scale);
    }
    if (value is BigInt) {
      return _decimal(name, value, 38, 0);
    }
    throw tds.InterfaceException(
      'Unsupported parameter type: ${value.runtimeType} ($name)',
    );
  }

  factory _ParamEncoder._typed(
      String name, tds.Param param, RpcCollation collation) {
    final type = param.type;
    final value = param.value;
    final output = (param.flags & _fByRefValue) != 0;
    if (type is UniqueIdentifierType) {
      return _typedParameter(
          name, SqlParameter.uniqueidentifier(value), collation,
          output: output);
    }
    if (value == null) return _nullOf(name, type, output, collation);
    final base = _ParamEncoder.forValue(name, value, collation);
    return _ParamEncoder(name, base.declaration, base._writeTypeAndValue,
        output: output);
  }

  static _ParamEncoder _decimal(
      String name, BigInt? unscaled, int precision, int scale,
      {bool output = false}) {
    if (precision < 1 || precision > 38) {
      throw tds.DataException('Decimal precision outside 1..38: $precision');
    }
    if (scale < 0 || scale > precision) {
      throw tds.DataException('Decimal scale outside 0..$precision: $scale');
    }
    final storage = _decimalStorage(precision);
    final magnitude = unscaled?.abs();
    if (magnitude != null && magnitude >= BigInt.from(10).pow(precision)) {
      throw tds.DataException(
          'Decimal value exceeds $precision digits: $unscaled');
    }
    return _ParamEncoder(name, 'decimal($precision, $scale)', (out, _) {
      out
        ..byte(tds.DECIMALNTYPE)
        ..byte(storage)
        ..byte(precision)
        ..byte(scale);
      if (magnitude == null) {
        out.byte(0);
        return;
      }
      out
        ..byte(storage)
        ..byte(unscaled!.isNegative ? 0 : 1);
      var rest = magnitude;
      final mask = BigInt.from(0xFFFFFFFF);
      for (var i = 0; i < (storage - 1) ~/ 4; i++) {
        out.uint32((rest & mask).toInt());
        rest >>= 32;
      }
    }, output: output);
  }

  /// Null parameter of the requested type (for OUTPUT and typed columns).
  static _ParamEncoder _nullOf(
      String name, Object? type, bool output, RpcCollation collation) {
    final SqlParameter typed = switch (type) {
      IntType() => const SqlParameter.int(null),
      BigIntType() => const SqlParameter.bigint(null),
      BitType() => const SqlParameter.bit(null),
      FloatType() => const SqlParameter.float(null),
      DateTime2Type() => const SqlParameter.datetime2(null),
      VarBinaryType() ||
      VarBinaryMaxType() =>
        const SqlParameter.varbinary(null, length: SqlParameter.max),
      NVarCharMaxType() =>
        const SqlParameter.nvarchar(null, length: SqlParameter.max),
      _ => const SqlParameter.nvarchar(null),
    };
    return _typedParameter(name, typed, collation, output: output);
  }
}

void _checkFinite(double value) {
  if (value.isNaN || value.isInfinite) {
    throw tds.DataException(
        'SQL Server FLOAT does not accept NaN or infinity: $value');
  }
}

/// Storage bytes (including the sign) of a `decimal` with [precision].
int _decimalStorage(int precision) => precision <= 9
    ? 5
    : precision <= 19
        ? 9
        : precision <= 28
            ? 13
            : 17;

/// Value bytes of a `time` with [scale] fractional digits.
int _timeLength(int scale) => scale <= 2
    ? 3
    : scale <= 4
        ? 4
        : 5;

void _checkScale(int scale) {
  if (scale < 0 || scale > 7) {
    throw tds.DataException('Time scale outside 0..7: $scale');
  }
}

/// Converts 100 ns ticks to the unit of [scale] (truncating).
int _scaleTicks(int ticks, int scale) {
  for (var i = scale; i < 7; i++) {
    ticks ~/= 10;
  }
  return ticks;
}

T _expect<T>(Object? value, String type) {
  if (value is T) return value;
  throw tds.DataException(
      'SqlParameter.$type does not accept ${value.runtimeType}: $value');
}

/// Returns the unscaled value of [value] at exactly [scale] fractional
/// digits, rounding half away from zero.
BigInt _unscaledFor(Object value, int scale, String type) {
  final DecimalValue decimal = switch (value) {
    DecimalValue v => v,
    BigInt v => DecimalValue(unscaledValue: v, scale: 0),
    int v => DecimalValue(unscaledValue: BigInt.from(v), scale: 0),
    double v => () {
        _checkFinite(v);
        return DecimalValue.parse(v.toStringAsFixed(scale > 20 ? 20 : scale));
      }(),
    String v => DecimalValue.parse(v),
    _ => throw tds.DataException(
        'SqlParameter.$type does not accept ${value.runtimeType}: $value'),
  };
  final ten = BigInt.from(10);
  if (decimal.scale <= scale) {
    return decimal.unscaledValue * ten.pow(scale - decimal.scale);
  }
  final divisor = ten.pow(decimal.scale - scale);
  final magnitude = decimal.unscaledValue.abs();
  var quotient = magnitude ~/ divisor;
  if ((magnitude % divisor) * BigInt.two >= divisor) quotient += BigInt.one;
  return decimal.unscaledValue.isNegative ? -quotient : quotient;
}

_ParamEncoder _typedParameter(
    String name, SqlParameter p, RpcCollation collation,
    {bool? output}) {
  final out = output ?? p.isOutput;
  final value = p.value;

  _ParamEncoder fixed(String declaration, int typeId, int size,
      void Function(TdsBufferWriter w)? body) {
    return _ParamEncoder(name, declaration, (w, _) {
      w
        ..byte(typeId)
        ..byte(size);
      if (body == null) {
        w.byte(0);
      } else {
        w.byte(size);
        body(w);
      }
    }, output: out);
  }

  switch (p.kind) {
    case SqlParameterKind.bit:
      final v = _expect<bool?>(value, 'bit');
      return fixed(
          'bit', tds.BITNTYPE, 1, v == null ? null : (w) => w.byte(v ? 1 : 0));
    case SqlParameterKind.tinyint ||
          SqlParameterKind.smallint ||
          SqlParameterKind.int ||
          SqlParameterKind.bigint:
      final v = _expect<int?>(value, p.kind.name);
      final (size, min, max) = switch (p.kind) {
        SqlParameterKind.tinyint => (1, 0, 255),
        SqlParameterKind.smallint => (2, -32768, 32767),
        SqlParameterKind.int => (4, -0x80000000, 0x7FFFFFFF),
        _ => (8, null, null),
      };
      if (v != null && min != null && (v < min || v > max!)) {
        throw tds.DataException('Value out of range for ${p.kind.name}: $v');
      }
      return fixed(p.kind.name, tds.INTNTYPE, size,
          v == null ? null : (w) => w.uintN(v, size));
    case SqlParameterKind.real || SqlParameterKind.float:
      final v = _expect<num?>(value, p.kind.name)?.toDouble();
      if (v != null) _checkFinite(v);
      final single = p.kind == SqlParameterKind.real;
      return fixed(
          p.kind.name,
          tds.FLTNTYPE,
          single ? 4 : 8,
          switch (v) {
            null => null,
            _ when single => (w) {
                final data = ByteData(4)..setFloat32(0, v, Endian.little);
                w.bytes(data.buffer.asUint8List());
              },
            _ => (w) => w.float64(v),
          });
    case SqlParameterKind.decimal:
      final precision = p.precision ?? 18;
      final scale = p.scale ?? 0;
      return _ParamEncoder._decimal(
          name,
          value == null ? null : _unscaledFor(value, scale, 'decimal'),
          precision,
          scale,
          output: out);
    case SqlParameterKind.money || SqlParameterKind.smallmoney:
      final small = p.kind == SqlParameterKind.smallmoney;
      final unscaled =
          value == null ? null : _unscaledFor(value, 4, p.kind.name).toInt();
      if (unscaled != null &&
          small &&
          (unscaled < -0x80000000 || unscaled > 0x7FFFFFFF)) {
        throw tds.DataException('Value out of range for smallmoney');
      }
      return fixed(
          p.kind.name,
          tds.MONEYNTYPE,
          small ? 4 : 8,
          switch (unscaled) {
            null => null,
            _ when small => (w) => w.int32(unscaled),
            _ => (w) => w
              ..int32(unscaled >> 32)
              ..uint32(unscaled & 0xFFFFFFFF),
          });
    case SqlParameterKind.date:
      final v = _expect<DateTime?>(value, 'date');
      return _ParamEncoder(name, 'date', (w, _) {
        w.byte(tds.DATENTYPE);
        if (v == null) {
          w.byte(0);
        } else {
          w.byte(3);
          _writeDate(w, v);
        }
      }, output: out);
    case SqlParameterKind.time:
      final scale = p.scale ?? 7;
      _checkScale(scale);
      final v = _expect<Duration?>(value, 'time');
      final ticks = v == null ? null : v.inMicroseconds * 10;
      if (ticks != null && (ticks < 0 || ticks >= _ticksPerDay)) {
        throw tds.DataException(
            'TIME must be between 00:00 and 23:59:59.9999999: $v');
      }
      final length = _timeLength(scale);
      return _ParamEncoder(name, 'time($scale)', (w, _) {
        w
          ..byte(tds.TIMENTYPE)
          ..byte(scale);
        if (ticks == null) {
          w.byte(0);
        } else {
          w
            ..byte(length)
            ..uintN(_scaleTicks(ticks, scale), length);
        }
      }, output: out);
    case SqlParameterKind.datetime:
      final v = _expect<DateTime?>(value, 'datetime');
      if (v != null && (v.year < 1753 || v.year > 9999)) {
        throw tds.DataException('datetime accepts years 1753 to 9999: $v');
      }
      return fixed(
          'datetime',
          tds.DATETIMNTYPE,
          8,
          switch (v) {
            null => null,
            _ => (w) {
                var days = _daysSince(v, _epoch1900);
                var ticks = (_timeOfDayTicks(v) * 3 / 100000).round();
                if (ticks >= 300 * 86400) {
                  days += 1;
                  ticks = 0;
                }
                w
                  ..int32(days)
                  ..uint32(ticks);
              },
          });
    case SqlParameterKind.smalldatetime:
      final v = _expect<DateTime?>(value, 'smalldatetime');
      return fixed(
          'smalldatetime',
          tds.DATETIMNTYPE,
          4,
          switch (v) {
            null => null,
            _ => (w) {
                var days = _daysSince(v, _epoch1900);
                var minutes = (_timeOfDayTicks(v) / 600000000).round();
                if (minutes >= 1440) {
                  days += 1;
                  minutes = 0;
                }
                if (days < 0 || days > 0xFFFF) {
                  throw tds.DataException(
                      'smalldatetime accepts dates from 1900-01-01 to '
                      '2079-06-06: $v');
                }
                w
                  ..uint16(days)
                  ..uint16(minutes);
              },
          });
    case SqlParameterKind.datetime2:
      final scale = p.scale ?? 7;
      _checkScale(scale);
      final v = _expect<DateTime?>(value, 'datetime2');
      final length = _timeLength(scale) + 3;
      return _ParamEncoder(name, 'datetime2($scale)', (w, _) {
        w
          ..byte(tds.DATETIME2NTYPE)
          ..byte(scale);
        if (v == null) {
          w.byte(0);
        } else {
          w
            ..byte(length)
            ..uintN(_scaleTicks(_timeOfDayTicks(v), scale), length - 3);
          _writeDate(w, v);
        }
      }, output: out);
    case SqlParameterKind.datetimeoffset:
      final scale = p.scale ?? 7;
      _checkScale(scale);
      final DateTimeOffsetValue? v = switch (value) {
        null => null,
        DateTimeOffsetValue v => v,
        DateTime v => DateTimeOffsetValue(
            utc: v.toUtc(),
            offsetMinutes: v.isUtc ? 0 : v.timeZoneOffset.inMinutes),
        _ => throw tds.DataException(
            'SqlParameter.datetimeoffset does not accept ${value.runtimeType}'),
      };
      final length = _timeLength(scale) + 5;
      return _ParamEncoder(name, 'datetimeoffset($scale)', (w, _) {
        w
          ..byte(tds.DATETIMEOFFSETNTYPE)
          ..byte(scale);
        if (v == null) {
          w.byte(0);
        } else {
          final utc = v.utc.toUtc();
          w
            ..byte(length)
            ..uintN(_scaleTicks(_timeOfDayTicks(utc), scale), length - 5);
          _writeDate(w, utc);
          w.uint16(v.offsetMinutes & 0xFFFF);
        }
      }, output: out);
    case SqlParameterKind.uniqueidentifier:
      final bytes = value == null ? null : _guidBytes(value);
      return fixed('uniqueidentifier', tds.GUIDTYPE, 16,
          bytes == null ? null : (w) => w.bytes(bytes));
    case SqlParameterKind.varchar || SqlParameterKind.char:
      final v = _expect<String?>(value, p.kind.name);
      final fixedLength = p.kind == SqlParameterKind.char;
      final bytes = v == null ? null : collation.encode(v);
      final size = bytes?.length ?? 0;
      final length = _declaredLength(p, size, fixedLength, _maxShortBytes);
      final isMax = length == SqlParameter.max;
      final typeName = fixedLength ? 'char' : 'varchar';
      return _ParamEncoder(name, '$typeName(${isMax ? 'max' : length})',
          (w, c) {
        w
          ..byte(fixedLength ? tds.BIGCHARTYPE : tds.BIGVARCHRTYPE)
          ..uint16(isMax ? 0xFFFF : length)
          ..bytes(c.bytes);
        if (isMax) {
          _writePlp(w, bytes == null ? null : (b) => b.bytes(bytes), size);
        } else if (bytes == null) {
          w.uint16(0xFFFF);
        } else {
          w
            ..uint16(size)
            ..bytes(bytes);
        }
      }, output: out);
    case SqlParameterKind.nvarchar || SqlParameterKind.nchar:
      final v = _expect<String?>(value, p.kind.name);
      final fixedLength = p.kind == SqlParameterKind.nchar;
      final units = v?.length ?? 0;
      final length = _declaredLength(p, units, fixedLength, 4000);
      final isMax = length == SqlParameter.max;
      final typeName = fixedLength ? 'nchar' : 'nvarchar';
      return _ParamEncoder(name, '$typeName(${isMax ? 'max' : length})',
          (w, c) {
        w
          ..byte(fixedLength ? tds.NCHARTYPE : tds.NVARCHARTYPE)
          ..uint16(isMax ? 0xFFFF : length * 2)
          ..bytes(c.bytes);
        if (isMax) {
          _writePlp(w, v == null ? null : (b) => b.ucs2(v), units * 2);
        } else if (v == null) {
          w.uint16(0xFFFF);
        } else {
          w
            ..uint16(units * 2)
            ..ucs2(v);
        }
      }, output: out);
    case SqlParameterKind.varbinary || SqlParameterKind.binary:
      final v = _expect<List<int>?>(value, p.kind.name);
      final fixedLength = p.kind == SqlParameterKind.binary;
      final size = v?.length ?? 0;
      final length = _declaredLength(p, size, fixedLength, _maxShortBytes);
      final isMax = length == SqlParameter.max;
      final typeName = fixedLength ? 'binary' : 'varbinary';
      return _ParamEncoder(name, '$typeName(${isMax ? 'max' : length})',
          (w, _) {
        w
          ..byte(fixedLength ? tds.BIGBINARYTYPE : tds.BIGVARBINTYPE)
          ..uint16(isMax ? 0xFFFF : length);
        if (isMax) {
          _writePlp(w, v == null ? null : (b) => b.bytes(v), size);
        } else if (v == null) {
          w.uint16(0xFFFF);
        } else {
          w
            ..uint16(size)
            ..bytes(v);
        }
      }, output: out);
    case SqlParameterKind.xml:
      final v = _expect<String?>(value, 'xml');
      return _ParamEncoder(name, 'xml', (w, _) {
        w
          ..byte(tds.XMLTYPE)
          ..byte(0); // no schema collection
        _writePlp(w, v == null ? null : (b) => b.ucs2(v), (v?.length ?? 0) * 2);
      }, output: out);
  }
}

/// Length to declare: the one requested in [SqlParameter.length] (checked
/// against [size]), or the type's default: [shortLimit] or `(max)` for
/// variable-length types, and the value's own size for fixed-length ones.
int _declaredLength(
    SqlParameter p, int size, bool fixedLength, int shortLimit) {
  final requested = p.length;
  final name = p.kind.name;
  if (requested == SqlParameter.max) {
    if (fixedLength) throw tds.DataException('$name does not accept (max)');
    return SqlParameter.max;
  }
  if (requested != null) {
    if (requested < 1 || requested > shortLimit) {
      throw tds.DataException(
          'Length of $name outside 1..$shortLimit: $requested');
    }
    if (size > requested) {
      throw tds.DataException(
          'Value of length $size does not fit in $name($requested)');
    }
    return requested;
  }
  if (fixedLength) {
    if (size > shortLimit) {
      throw tds.DataException('Value too large for $name: $size');
    }
    return size < 1 ? 1 : size;
  }
  return size > shortLimit ? SqlParameter.max : shortLimit;
}

const int _ticksPerDay = 864000000000;

int _timeOfDayTicks(DateTime value) =>
    ((value.hour * 3600 + value.minute * 60 + value.second) * 1000000 +
        value.millisecond * 1000 +
        value.microsecond) *
    10;

final DateTime _epoch0001 = DateTime.utc(1, 1, 1);
final DateTime _epoch1900 = DateTime.utc(1900, 1, 1);

/// Days from [epoch] to the date of [value], using the calendar fields.
int _daysSince(DateTime value, DateTime epoch) =>
    DateTime.utc(value.year, value.month, value.day).difference(epoch).inDays;

/// Writes the days since 0001-01-01 using the value's calendar fields, with
/// no time zone conversion: what you see in [value] is what the server stores.
void _writeDate(TdsBufferWriter out, DateTime value) =>
    out.uintN(_daysSince(value, _epoch0001), 3);

Uint8List _guidBytes(Object value) {
  final Uint8List raw;
  if (value is List<int>) {
    if (value.length != 16) {
      throw tds.DataException('GUID requires 16 bytes: ${value.length}');
    }
    raw = Uint8List.fromList(value);
  } else {
    final hex = value
        .toString()
        .replaceAll('-', '')
        .replaceAll('{', '')
        .replaceAll('}', '');
    if (hex.length != 32) {
      throw tds.DataException('Invalid GUID: $value');
    }
    raw = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) throw tds.DataException('Invalid GUID: $value');
      raw[i] = byte;
    }
  }
  // SQL Server stores the first three groups little-endian.
  return Uint8List.fromList([
    raw[3],
    raw[2],
    raw[1],
    raw[0],
    raw[5],
    raw[4],
    raw[7],
    raw[6],
    ...raw.sublist(8),
  ]);
}
