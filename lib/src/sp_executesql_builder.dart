import 'dart:typed_data';

import 'tds_base.dart' as tds;
import 'tds_types.dart';

/// Helper responsável por gerar batches seguros utilizando
/// `sp_executesql`, convertendo parâmetros Dart em literais SQL.
class SpExecutesqlBuilder {
  SpExecutesqlBuilder({required TdsTypeInferrer typeInferrer})
      : _typeInferrer = typeInferrer;

  final TdsTypeInferrer _typeInferrer;

  /// Constrói um batch `EXEC sp_executesql` equivalente ao comando original.
  ///
  /// Retorna `null` quando não há parâmetros válidos e o SQL pode ser enviado
  /// sem modificações.
  String? buildBatch(String sql, Map<String, dynamic> params) {
    if (params.isEmpty) {
      return null;
    }
    final converted = _convertParams(params);
    if (converted.isEmpty) {
      return null;
    }
    final definition = _buildParamDefinition(converted);
    final assignments = _buildParamAssignments(converted);
    final batch = StringBuffer('EXEC sp_executesql N')
      ..write(_escapeUnicodeLiteral(sql))
      ..write(', N')
      ..write(_escapeUnicodeLiteral(definition));
    if (assignments.isNotEmpty) {
      batch.write(', ');
      batch.write(assignments.join(', '));
    }
    return batch.toString();
  }

  List<tds.Param> _convertParams(Map<String, dynamic> params) {
    final bindings = <tds.Param>[];
    params.forEach((key, value) {
      bindings.add(_makeParam(key, value));
    });
    return bindings;
  }

  tds.Param _makeParam(
    String name,
    dynamic value, {
    SqlType? forcedType,
  }) {
    if (value is tds.Param) {
      final effectiveName = value.name.isNotEmpty ? value.name : name;
      final normalized = _normalizeParamName(effectiveName);
      final sqlType = value.type is SqlType
          ? value.type as SqlType
          : forcedType ?? _typeInferrer.fromValue(value.value);
      return tds.Param(
        name: normalized,
        type: sqlType,
        value: value.value,
        flags: value.flags,
      );
    }
    final normalized = _normalizeParamName(name);
    final sqlType = forcedType ?? _typeInferrer.fromValue(value);
    return tds.Param(
      name: normalized,
      type: sqlType,
      value: value,
    );
  }

  String _normalizeParamName(String name) {
    if (name.isEmpty) {
      return '';
    }
    return name.startsWith('@') ? name : '@$name';
  }

  String _buildParamDefinition(List<tds.Param> params) {
    return params
        .map((param) {
          final sqlType = param.type;
          if (sqlType is! SqlType) {
            throw tds.InterfaceError('Tipo de parâmetro ausente para ${param.name}');
          }
          return '${param.name} ${sqlType.declaration}';
        })
        .join(', ');
  }

  List<String> _buildParamAssignments(List<tds.Param> params) {
    final assignments = <String>[];
    for (final param in params) {
      assignments.add('${param.name} = ${_formatLiteral(param)}');
    }
    return assignments;
  }

  String _formatLiteral(tds.Param param) {
    final sqlType = param.type;
    final value = param.value;
    if (value == null) {
      return 'NULL';
    }
    if (sqlType is! SqlType) {
      throw tds.InterfaceError('Não é possível inferir o tipo SQL para ${param.name}');
    }
    if (sqlType is BitType) {
      return (value == true) ? '1' : '0';
    }
    if (sqlType is TinyIntType ||
        sqlType is SmallIntType ||
        sqlType is IntType ||
        sqlType is BigIntType) {
      return _formatIntegerLiteral(value);
    }
    if (sqlType is FloatType || sqlType is RealType) {
      return _formatFloatLiteral(value);
    }
    if (sqlType is DecimalType) {
      return _formatDecimalLiteral(value);
    }
    if (sqlType is NVarCharType || sqlType is NVarCharMaxType) {
      final text = _coerceString(value);
      return 'N${_escapeUnicodeLiteral(text)}';
    }
    if (sqlType is VarBinaryType || sqlType is VarBinaryMaxType) {
      return _formatBinaryLiteral(value);
    }
    if (sqlType is DateType) {
      return _formatDateLiteral(value);
    }
    if (sqlType is TimeType) {
      return _formatTimeLiteral(value, sqlType.precision);
    }
    if (sqlType is DateTime2Type) {
      return _formatDateTimeLiteral(value, sqlType.precision);
    }
    if (sqlType is UniqueIdentifierType) {
      final text = _coerceString(value);
      return _escapeUnicodeLiteral(text);
    }
    throw tds.NotSupportedError(
      'Parâmetros do tipo ${sqlType.declaration} ainda não são suportados.',
    );
  }

  String _formatIntegerLiteral(dynamic value) {
    if (value is int || value is BigInt) {
      return value.toString();
    }
    if (value is num && value == value.truncate()) {
      return value.toInt().toString();
    }
    throw tds.DataError('Valor inteiro inválido: ${value.runtimeType}');
  }

  String _formatFloatLiteral(dynamic value) {
    if (value is num) {
      if (value is double) {
        if (value.isNaN || value.isInfinite) {
          throw tds.DataError('Valores especiais não são permitidos em FLOAT');
        }
      }
      return value.toString();
    }
    throw tds.DataError('Valor numérico inválido: ${value.runtimeType}');
  }

  String _formatDecimalLiteral(dynamic value) {
    if (value is DecimalValue) {
      return value.toString();
    }
    if (value is num) {
      return value.toString();
    }
    throw tds.DataError('Valor decimal inválido: ${value.runtimeType}');
  }

  String _formatBinaryLiteral(dynamic value) {
    Uint8List buffer;
    if (value is Uint8List) {
      buffer = value;
    } else if (value is List<int>) {
      buffer = Uint8List.fromList(value);
    } else {
      throw tds.DataError('Valor binário inválido: ${value.runtimeType}');
    }
    final out = StringBuffer('0x');
    for (final byte in buffer) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  String _formatDateLiteral(dynamic value) {
    if (value is! DateTime) {
      throw tds.DataError('Valor DATE inválido: ${value.runtimeType}');
    }
    final date = value.toLocal();
    final literal =
        '${_fourDigits(date.year)}-${_twoDigits(date.month)}-${_twoDigits(date.day)}';
    return 'CONVERT(DATE, N${_escapeUnicodeLiteral(literal)}, 23)';
  }

  String _formatTimeLiteral(dynamic value, int precision) {
    DateTime reference;
    if (value is DateTime) {
      reference = value.toLocal();
    } else if (value is Duration) {
      reference = DateTime(1970, 1, 1).add(value);
    } else {
      throw tds.DataError('Valor TIME inválido: ${value.runtimeType}');
    }
    final literal = _buildTimeLiteral(reference, precision);
    return 'CONVERT(TIME($precision), N${_escapeUnicodeLiteral(literal)}, 114)';
  }

  String _formatDateTimeLiteral(dynamic value, int precision) {
    if (value is! DateTime) {
      throw tds.DataError('Valor DATETIME2 inválido: ${value.runtimeType}');
    }
    final local = value.toLocal();
    final literal = _buildDateTimeLiteral(local, precision);
    return 'CONVERT(DATETIME2($precision), N${_escapeUnicodeLiteral(literal)}, 126)';
  }

  String _buildDateTimeLiteral(DateTime value, int precision) {
    final buffer = StringBuffer()
      ..write(_fourDigits(value.year))
      ..write('-')
      ..write(_twoDigits(value.month))
      ..write('-')
      ..write(_twoDigits(value.day))
      ..write('T')
      ..write(_twoDigits(value.hour))
      ..write(':')
      ..write(_twoDigits(value.minute))
      ..write(':')
      ..write(_twoDigits(value.second));
    if (precision > 0) {
      final fraction = _formatFraction(value.microsecond, precision);
      if (fraction.isNotEmpty) {
        buffer
          ..write('.')
          ..write(fraction);
      }
    }
    return buffer.toString();
  }

  String _buildTimeLiteral(DateTime value, int precision) {
    final buffer = StringBuffer()
      ..write(_twoDigits(value.hour))
      ..write(':')
      ..write(_twoDigits(value.minute))
      ..write(':')
      ..write(_twoDigits(value.second));
    if (precision > 0) {
      final fraction = _formatFraction(value.microsecond, precision);
      if (fraction.isNotEmpty) {
        buffer
          ..write('.')
          ..write(fraction);
      }
    }
    return buffer.toString();
  }

  String _formatFraction(int microseconds, int precision) {
    if (precision <= 0) {
      return '';
    }
    final normalizedPrecision = precision.clamp(0, 7).toInt();
    final full = microseconds.toString().padLeft(6, '0');
    if (normalizedPrecision <= 6) {
      return full.substring(0, normalizedPrecision);
    }
    final extra = normalizedPrecision - 6;
    return full + ''.padRight(extra, '0');
  }

  String _coerceString(dynamic value) {
    if (value is String) {
      return value;
    }
    if (value is List<int>) {
      return String.fromCharCodes(value);
    }
    return '$value';
  }

  String _escapeUnicodeLiteral(String value) {
    final escaped = value.replaceAll("'", "''");
    return "'$escaped'";
  }

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

  String _fourDigits(int value) => value.toString().padLeft(4, '0');
}
