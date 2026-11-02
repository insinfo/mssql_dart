import 'dart:convert';
import 'dart:typed_data';

import 'collate.dart';
import 'tds_base.dart' as tds;
import 'tds_types.dart';

/// TYPE_INFO of a column or return parameter.
class TdsTypeInfo {
  final int typeId;
  final int? maxLength;
  final int? precision;
  final int? scale;
  final Collation? collation;
  final List<String>? schema;

  const TdsTypeInfo({
    required this.typeId,
    this.maxLength,
    this.precision,
    this.scale,
    this.collation,
    this.schema,
  });

  /// Whether the value arrives as PLP (partially length-prefixed): `(max)`
  /// types, xml and large UDTs.
  bool get isPlp =>
      typeId == tds.XMLTYPE ||
      (maxLength == 0xFFFF &&
          (typeId == tds.BIGVARCHRTYPE ||
              typeId == tds.NVARCHARTYPE ||
              typeId == tds.BIGVARBINTYPE ||
              typeId == tds.UDTTYPE));
}

/// Thrown when the buffer ends in the middle of a value; [bytes] is the
/// minimum still missing to make progress. The decoder rewinds to the start
/// of the token, reads another packet and retries.
class NeedMoreData implements Exception {
  NeedMoreData(this.bytes);
  final int bytes;
}

/// Synchronous little-endian reader over a buffer range.
class ByteCursor {
  ByteCursor(this.buf, this.pos, this.end) : _data = ByteData.sublistView(buf);

  final Uint8List buf;
  final ByteData _data;
  int pos;
  final int end;

  int get available => end - pos;

  void need(int n) {
    final missing = n - (end - pos);
    if (missing > 0) throw NeedMoreData(missing);
  }

  int u8() {
    if (pos >= end) throw NeedMoreData(1);
    return buf[pos++];
  }

  int i16() {
    need(2);
    final v = _data.getInt16(pos, Endian.little);
    pos += 2;
    return v;
  }

  int u16() {
    need(2);
    final v = _data.getUint16(pos, Endian.little);
    pos += 2;
    return v;
  }

  int i32() {
    need(4);
    final v = _data.getInt32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u32() {
    need(4);
    final v = _data.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int i64() {
    need(8);
    final v = _data.getInt64(pos, Endian.little);
    pos += 8;
    return v;
  }

  double f32() {
    need(4);
    final v = _data.getFloat32(pos, Endian.little);
    pos += 4;
    return v;
  }

  double f64() {
    need(8);
    final v = _data.getFloat64(pos, Endian.little);
    pos += 8;
    return v;
  }

  int uintN(int n) {
    need(n);
    var v = 0;
    for (var i = n - 1; i >= 0; i--) {
      v = (v << 8) | buf[pos + i];
    }
    pos += n;
    return v;
  }

  /// Zero-copy view; valid only until the next packet is read.
  Uint8List view(int n) {
    need(n);
    final v = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return v;
  }

  /// Copy independent of the packet buffer (safe to hand to the caller).
  Uint8List copy(int n) {
    need(n);
    final v = buf.sublist(pos, pos + n);
    pos += n;
    return v;
  }

  void skip(int n) {
    need(n);
    pos += n;
  }

  String ucs2(int charCount) => decodeUtf16le(view(charCount * 2));

  Collation collation() => Collation.unpack(view(Collation.wire_size));
}

final DateTime _epoch1900 = DateTime.utc(1900, 1, 1);
final DateTime _epoch0001 = DateTime.utc(1, 1, 1);
const int _microsPerDay = 86400000000;

/// Decodes values from rows (ROW/NBCROW), RETURNVALUE and sql_variant.
class ValueDecoder {
  ValueDecoder({required this.bytesToUnicode, this.connectionCollation});

  final bool bytesToUnicode;
  Collation? connectionCollation;

  dynamic decode(ByteCursor r, TdsTypeInfo t) {
    switch (t.typeId) {
      case tds.BITTYPE:
        return r.u8() != 0;
      case tds.INT1TYPE:
        return r.u8();
      case tds.INT2TYPE:
        return r.i16();
      case tds.INT4TYPE:
        return r.i32();
      case tds.INT8TYPE:
        return r.i64();
      case tds.FLT4TYPE:
        return r.f32();
      case tds.FLT8TYPE:
        return r.f64();
      case tds.MONEYTYPE:
        return _money8(r);
      case tds.MONEY4TYPE:
        return r.i32() / 10000.0;
      case tds.DATETIMETYPE:
        return _datetime(r);
      case tds.DATETIM4TYPE:
        return _smallDatetime(r);
      case tds.INTNTYPE:
        switch (r.u8()) {
          case 0:
            return null;
          case 1:
            return r.u8();
          case 2:
            return r.i16();
          case 4:
            return r.i32();
          case 8:
            return r.i64();
          case final n:
            throw tds.InterfaceException('Invalid length for INTN: $n');
        }
      case tds.BITNTYPE:
        final n = r.u8();
        return n == 0 ? null : r.u8() != 0;
      case tds.FLTNTYPE:
        switch (r.u8()) {
          case 0:
            return null;
          case 4:
            return r.f32();
          case 8:
            return r.f64();
          case final n:
            throw tds.InterfaceException('Invalid length for FLOATN: $n');
        }
      case tds.MONEYNTYPE:
        switch (r.u8()) {
          case 0:
            return null;
          case 4:
            return r.i32() / 10000.0;
          case 8:
            return _money8(r);
          case final n:
            throw tds.InterfaceException('Invalid length for MONEYN: $n');
        }
      case tds.DATETIMNTYPE:
        switch (r.u8()) {
          case 0:
            return null;
          case 4:
            return _smallDatetime(r);
          case 8:
            return _datetime(r);
          case final n:
            throw tds.InterfaceException('Invalid length for DATETIMN: $n');
        }
      case tds.DATENTYPE:
        return r.u8() == 0 ? null : _date(r);
      case tds.TIMENTYPE:
        final n = r.u8();
        return n == 0
            ? null
            : Duration(microseconds: _timeMicros(r, n, t.precision ?? 7));
      case tds.DATETIME2NTYPE:
        final n = r.u8();
        if (n == 0) return null;
        final micros = _timeMicros(r, n - 3, t.precision ?? 7);
        return _date(r).add(Duration(microseconds: micros));
      case tds.DATETIMEOFFSETNTYPE:
        final n = r.u8();
        if (n == 0) return null;
        final micros = _timeMicros(r, n - 5, t.precision ?? 7);
        final utc = _date(r).add(Duration(microseconds: micros));
        return DateTimeOffsetValue(utc: utc, offsetMinutes: r.i16());
      case tds.DECIMALNTYPE:
      case tds.NUMERICNTYPE:
        final n = r.u8();
        return n == 0 ? null : _decimal(r, n, t.scale ?? 0);
      case tds.GUIDTYPE:
        final n = r.u8();
        if (n == 0) return null;
        if (n != 16) throw tds.InterfaceException('Invalid GUID with $n bytes');
        return _guid(r.view(16));
      case tds.BIGVARCHRTYPE:
      case tds.BIGCHARTYPE:
        final data = t.isPlp ? _plp(r) : _usVarBytes(r);
        return data == null ? null : _text(data, t.collation);
      case tds.NVARCHARTYPE:
      case tds.NCHARTYPE:
        final data = t.isPlp ? _plp(r) : _usVarBytes(r);
        return data == null ? null : _ucs2(data);
      case tds.BIGVARBINTYPE:
      case tds.BIGBINARYTYPE:
      case tds.UDTTYPE:
        final data = t.isPlp ? _plp(r) : _usVarBytes(r);
        return data == null ? null : Uint8List.fromList(data);
      case tds.SYBVARCHAR:
      case tds.SYBCHAR:
        final n = r.u8();
        return n == 0xFF ? null : _text(r.view(n), t.collation);
      case tds.SYBNVARCHAR:
        final n = r.u8();
        return n == 0xFF ? null : _ucs2(r.view(n));
      case tds.SYBVARBINARY:
      case tds.BINARYTYPE:
        final n = r.u8();
        return n == 0xFF ? null : r.copy(n);
      case tds.TEXTTYPE:
      case tds.NTEXTTYPE:
      case tds.IMAGETYPE:
        final ptr = r.u8();
        if (ptr == 0) return null;
        r.skip(ptr + 8); // text pointer + timestamp
        final data = r.view(r.i32());
        return switch (t.typeId) {
          tds.TEXTTYPE => _text(data, t.collation),
          tds.NTEXTTYPE => _ucs2(data),
          _ => Uint8List.fromList(data),
        };
      case tds.XMLTYPE:
        final data = _plp(r);
        return data == null ? null : _ucs2(data);
      case tds.SSVARIANTTYPE:
        return _variant(r);
      default:
        throw tds.NotSupportedException('Unsupported column type ${t.typeId}');
    }
  }

  dynamic _text(Uint8List data, Collation? collation) {
    if (!bytesToUnicode) return Uint8List.fromList(data);
    final Encoding codec =
        collation?.get_codec() ?? connectionCollation?.get_codec() ?? latin1;
    return codec.decode(data);
  }

  dynamic _ucs2(Uint8List data) =>
      bytesToUnicode ? decodeUtf16le(data) : Uint8List.fromList(data);

  static Uint8List? _usVarBytes(ByteCursor r) {
    final n = r.u16();
    return n == 0xFFFF ? null : r.view(n);
  }

  /// Joins the PLP chunks. Returns a view when there is a single chunk.
  static Uint8List? _plp(ByteCursor r) {
    final total = r.i64();
    if (total == -1) return null; // PLP_NULL
    if (total >= 0) {
      // Request everything the value occupies (plus one header) at once,
      // instead of re-reading the row for every chunk.
      final minimum = total + 8;
      if (r.available < minimum) throw NeedMoreData(minimum - r.available);
    }
    Uint8List? single;
    List<Uint8List>? parts;
    var length = 0;
    while (true) {
      final chunk = r.u32();
      if (chunk == 0) break;
      final part = r.view(chunk);
      length += chunk;
      if (single == null && parts == null) {
        single = part;
      } else {
        (parts ??= [single!])..add(part);
      }
    }
    if (parts == null) return single ?? Uint8List(0);
    final out = Uint8List(length);
    var offset = 0;
    for (final part in parts) {
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }

  static double _money8(ByteCursor r) {
    final high = r.i32();
    final low = r.u32();
    return ((high << 32) | low) / 10000.0;
  }

  static DateTime _datetime(ByteCursor r) {
    final days = r.i32();
    final ticks = r.u32(); // 1/300 s since midnight
    final millis = (ticks * 10 / 3).round();
    return _epoch1900.add(Duration(days: days, milliseconds: millis));
  }

  static DateTime _smallDatetime(ByteCursor r) {
    final days = r.u16();
    final minutes = r.u16();
    return _epoch1900.add(Duration(days: days, minutes: minutes));
  }

  static DateTime _date(ByteCursor r) =>
      _epoch0001.add(Duration(days: r.uintN(3)));

  static int _timeMicros(ByteCursor r, int size, int precision) {
    var ticks = r.uintN(size);
    for (var i = precision; i < 7; i++) {
      ticks *= 10;
    }
    final micros = ticks ~/ 10;
    if (micros >= _microsPerDay) {
      throw tds.InterfaceException('Time out of range: $ticks');
    }
    return micros;
  }

  static DecimalValue _decimal(ByteCursor r, int size, int scale) {
    final positive = r.u8() == 1;
    final n = size - 1;
    BigInt magnitude;
    if (n <= 8) {
      final v = r.uintN(n);
      magnitude = v >= 0 ? BigInt.from(v) : BigInt.from(v).toUnsigned(64);
    } else {
      r.need(n);
      magnitude = BigInt.zero;
      for (var i = n - 1; i >= 0; i--) {
        magnitude = (magnitude << 8) | BigInt.from(r.buf[r.pos + i]);
      }
      r.pos += n;
    }
    return DecimalValue(
        unscaledValue: positive ? magnitude : -magnitude, scale: scale);
  }

  static String _guid(Uint8List b) {
    const hex = '0123456789abcdef';
    const order = [
      3,
      2,
      1,
      0,
      -1,
      5,
      4,
      -1,
      7,
      6,
      -1,
      8,
      9,
      -1,
      10,
      11,
      12,
      13,
      14,
      15
    ];
    final out = StringBuffer();
    for (final i in order) {
      if (i < 0) {
        out.write('-');
      } else {
        out
          ..write(hex[b[i] >> 4])
          ..write(hex[b[i] & 0xF]);
      }
    }
    return out.toString();
  }

  dynamic _variant(ByteCursor r) {
    final total = r.i32();
    if (total == 0) return null;
    r.need(total);
    final end = r.pos + total;
    final baseType = r.u8();
    final propBytes = r.u8();
    final dataLength = total - 2 - propBytes;
    TdsTypeInfo info;
    switch (baseType) {
      case tds.TIMENTYPE:
      case tds.DATETIME2NTYPE:
      case tds.DATETIMEOFFSETNTYPE:
        info = TdsTypeInfo(typeId: baseType, precision: r.u8());
      case tds.DECIMALNTYPE:
      case tds.NUMERICNTYPE:
        final precision = r.u8();
        info =
            TdsTypeInfo(typeId: baseType, precision: precision, scale: r.u8());
      case tds.BIGVARCHRTYPE:
      case tds.BIGCHARTYPE:
      case tds.NVARCHARTYPE:
      case tds.NCHARTYPE:
        final collation = r.collation();
        r.u16(); // maximum length
        final data = r.view(dataLength);
        return baseType == tds.NVARCHARTYPE || baseType == tds.NCHARTYPE
            ? _ucs2(data)
            : _text(data, collation);
      case tds.BIGVARBINTYPE:
      case tds.BIGBINARYTYPE:
        r.u16();
        return r.copy(dataLength);
      default:
        r.skip(propBytes);
        info = TdsTypeInfo(typeId: baseType);
    }
    // Fixed-size types, and the "N" types, which carry no length byte inside
    // a variant.
    final value = switch (baseType) {
      tds.TIMENTYPE =>
        Duration(microseconds: _timeMicros(r, dataLength, info.precision ?? 7)),
      tds.DATETIME2NTYPE => () {
          final micros = _timeMicros(r, dataLength - 3, info.precision ?? 7);
          return _date(r).add(Duration(microseconds: micros));
        }(),
      tds.DATETIMEOFFSETNTYPE => () {
          final micros = _timeMicros(r, dataLength - 5, info.precision ?? 7);
          final utc = _date(r).add(Duration(microseconds: micros));
          return DateTimeOffsetValue(utc: utc, offsetMinutes: r.i16());
        }(),
      tds.DATENTYPE => _date(r),
      tds.DECIMALNTYPE ||
      tds.NUMERICNTYPE =>
        _decimal(r, dataLength, info.scale ?? 0),
      tds.GUIDTYPE => _guid(r.view(16)),
      _ => decode(r, info),
    };
    r.pos = end;
    return value;
  }
}
