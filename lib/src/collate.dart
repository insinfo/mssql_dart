import 'dart:convert';

import 'dart:typed_data';

import '../third_party/charset/other/code_page.dart';
import '../third_party/charset/other/euc_kr.dart';
import '../third_party/charset/other/gbk.dart';
import '../third_party/charset/other/shift_jis.dart';
import '../third_party/charset/src/big5/big5.dart';

const int TDS_CHARSET_ISO_8859_1 = 1;
const int TDS_CHARSET_CP1251 = 2;
const int TDS_CHARSET_CP1252 = 3;
const int TDS_CHARSET_UCS_2LE = 4;
const int TDS_CHARSET_UNICODE = 5;

const Encoding ucs2Codec = _Utf16leEncoding();

const _ucs2Names = <String>{
  'unicode',
  'ucs-2',
  'ucs2',
  'ucs-2le',
  'utf-16le',
};

/// Code pages used by SQL Server collations.
final Map<String, Encoding> _codePages = {
  'cp437': cp437,
  'cp850': cp850,
  'cp874': windows874,
  'cp932': shiftJis,
  'cp936': gbk,
  'cp949': eucKr,
  'cp950': big5,
  'cp1250': windows1250,
  'cp1251': windows1251,
  'cp1252': windows1252,
  'cp1253': windows1253,
  'cp1254': windows1254,
  'cp1255': windows1255,
  'cp1256': windows1256,
  'cp1257': windows1257,
  'cp1258': windows1258,
  'utf-8': utf8,
};

/// Maps a sort_id to its charset, following the original table.
String sortid2charset(int sortId) {
  if ([30, 31, 32, 33, 34].contains(sortId)) {
    return "CP437";
  } else if ([40, 41, 42, 43, 44, 49, 55, 56, 57, 58, 59, 60, 61]
      .contains(sortId)) {
    return "CP850";
  } else if ([
    80,
    81,
    82,
    83,
    84,
    85,
    86,
    87,
    88,
    89,
    90,
    91,
    92,
    93,
    94,
    95,
    96
  ].contains(sortId)) {
    return "CP1250";
  } else if ([104, 105, 106, 107, 108].contains(sortId)) {
    return "CP1251";
  } else if ([51, 52, 53, 54, 183, 184, 185, 186].contains(sortId)) {
    return "CP1252";
  } else if ([112, 113, 114, 120, 121, 122, 124].contains(sortId)) {
    return "CP1253";
  } else if ([128, 129, 130].contains(sortId)) {
    return "CP1254";
  } else if ([136, 137, 138].contains(sortId)) {
    return "CP1255";
  } else if ([144, 145, 146].contains(sortId)) {
    return "CP1256";
  } else if ([152, 153, 154, 155, 156, 157, 158, 159, 160].contains(sortId)) {
    return "CP1257";
  } else {
    throw Exception("Invalid collation: 0x${sortId.toRadixString(16)}");
  }
}

/// Maps an LCID to its charset, following the original table.
String lcid2charset(int lcid) {
  if ([0x405, 0x40E, 0x415, 0x418, 0x41A, 0x41B, 0x41C, 0x424, 0x104E]
      .contains(lcid)) {
    return "CP1250";
  } else if ([
    0x402,
    0x419,
    0x422,
    0x423,
    0x42F,
    0x43F,
    0x440,
    0x444,
    0x450,
    0x81A,
    0x82C,
    0x843,
    0xC1A
  ].contains(lcid)) {
    return "CP1251";
  } else if ([
    0x1007,
    0x1009,
    0x100A,
    0x100C,
    0x1407,
    0x1409,
    0x140A,
    0x140C,
    0x1809,
    0x180A,
    0x180C,
    0x1C09,
    0x1C0A,
    0x2009,
    0x200A,
    0x2409,
    0x240A,
    0x2809,
    0x280A,
    0x2C09,
    0x2C0A,
    0x3009,
    0x300A,
    0x3409,
    0x340A,
    0x380A,
    0x3C0A,
    0x400A,
    0x403,
    0x406,
    0x407,
    0x409,
    0x40A,
    0x40B,
    0x40C,
    0x40F,
    0x410,
    0x413,
    0x414,
    0x416,
    0x41D,
    0x421,
    0x42D,
    0x436,
    0x437,
    0x438,
    0x43E,
    0x440A,
    0x441,
    0x456,
    0x480A,
    0x4C0A,
    0x500A,
    0x807,
    0x809,
    0x80A,
    0x80C,
    0x810,
    0x813,
    0x814,
    0x816,
    0x81D,
    0x83E,
    0xC07,
    0xC09,
    0xC0A,
    0xC0C
  ].contains(lcid)) {
    return "CP1252";
  } else if (lcid == 0x408) {
    return "CP1253";
  } else if ([0x41F, 0x42C, 0x443].contains(lcid)) {
    return "CP1254";
  } else if (lcid == 0x40D) {
    return "CP1255";
  } else if ([
    0x1001,
    0x1401,
    0x1801,
    0x1C01,
    0x2001,
    0x2401,
    0x2801,
    0x2C01,
    0x3001,
    0x3401,
    0x3801,
    0x3C01,
    0x4001,
    0x401,
    0x420,
    0x429,
    0x801,
    0xC01
  ].contains(lcid)) {
    return "CP1256";
  } else if ([0x425, 0x426, 0x427, 0x827].contains(lcid)) {
    return "CP1257";
  } else if (lcid == 0x42A) {
    return "CP1258";
  } else if (lcid == 0x41E) {
    return "CP874";
  } else if (lcid == 0x411) {
    return "CP932";
  } else if ([0x1004, 0x804].contains(lcid)) {
    return "CP936";
  } else if (lcid == 0x412) {
    return "CP949";
  } else if ([0x1404, 0x404, 0xC04].contains(lcid)) {
    return "CP950";
  } else {
    return "CP1252";
  }
}

/// A SQL Server collation, modeled on the original Python format.
class Collation {
  static const int wire_size = 5;
  static const int f_ignore_case = 0x100000;
  static const int f_ignore_accent = 0x200000;
  static const int f_ignore_width = 0x400000;
  static const int f_ignore_kana = 0x800000;
  static const int f_binary = 0x1000000;
  static const int f_binary2 = 0x2000000;
  static const int f_utf8 = 0x4000000;

  int lcid;
  int sort_id;
  bool ignore_case;
  bool ignore_accent;
  bool ignore_width;
  bool ignore_kana;
  bool binary;
  bool binary2;
  int version;

  Collation({
    required this.lcid,
    required this.sort_id,
    required this.ignore_case,
    required this.ignore_accent,
    required this.ignore_width,
    required this.ignore_kana,
    required this.binary,
    required this.binary2,
    required this.version,
    this.utf8 = false,
  });

  /// Whether this is a `*_UTF8` collation (SQL Server 2019+), which stores
  /// `char`/`varchar` as UTF-8.
  bool utf8;

  /// Unpacks a 5-byte list into a [Collation].
  static Collation unpack(List<int> b) {
    if (b.length < wire_size) {
      throw ArgumentError(
          'Collation data must be at least $wire_size bytes long.');
    }
    // The first 4 bytes are read as a little-endian integer.
    int lump = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
    // The 5th byte is the sort_id (second field of the "<LB" struct).
    int sortId = b[4];
    int version = (lump >> 28) & 0xF;
    int lcid = lump & 0xFFFFF;
    bool ignoreCase = (lump & f_ignore_case) != 0;
    bool ignoreAccent = (lump & f_ignore_accent) != 0;
    bool ignoreWidth = (lump & f_ignore_width) != 0;
    bool ignoreKana = (lump & f_ignore_kana) != 0;
    bool binary = (lump & f_binary) != 0;
    bool binary2 = (lump & f_binary2) != 0;
    bool isUtf8 = (lump & f_utf8) != 0;

    return Collation(
      lcid: lcid,
      sort_id: sortId,
      ignore_case: ignoreCase,
      ignore_accent: ignoreAccent,
      ignore_width: ignoreWidth,
      ignore_kana: ignoreKana,
      binary: binary,
      binary2: binary2,
      version: version,
      utf8: isUtf8,
    );
  }

  /// Packs this [Collation] into a 5-byte list.
  List<int> pack() {
    int lump = (lcid & 0xFFFFF) | ((version & 0xF) << 28);
    if (ignore_case) lump |= f_ignore_case;
    if (ignore_accent) lump |= f_ignore_accent;
    if (ignore_width) lump |= f_ignore_width;
    if (ignore_kana) lump |= f_ignore_kana;
    if (binary) lump |= f_binary;
    if (binary2) lump |= f_binary2;
    if (utf8) lump |= f_utf8;
    return [
      lump & 0xFF,
      (lump >> 8) & 0xFF,
      (lump >> 16) & 0xFF,
      (lump >> 24) & 0xFF,
      sort_id & 0xFF,
    ];
  }

  /// Returns the charset based on the sort_id (if set) or the LCID.
  String get_charset() {
    if (utf8) return 'utf-8';
    if (sort_id != 0) {
      return sortid2charset(sort_id);
    } else {
      return lcid2charset(lcid);
    }
  }

  /// Returns the [Encoding] for the charset.
  Encoding get_codec() {
    return _resolveEncoding(get_charset());
  }

  @override
  String toString() {
    return 'Collation(lcid: $lcid, sort_id: $sort_id, ignore_case: $ignore_case, '
        'ignore_accent: $ignore_accent, ignore_width: $ignore_width, ignore_kana: $ignore_kana, '
        'binary: $binary, binary2: $binary2, version: $version)';
  }
}

/// Default collation instance.
final raw_collation = Collation(
  lcid: 0,
  sort_id: 0,
  ignore_case: false,
  ignore_accent: false,
  ignore_width: false,
  ignore_kana: false,
  binary: false,
  binary2: false,
  version: 0,
);

Encoding _resolveEncoding(String charset) {
  final normalized = charset.toLowerCase();
  if (_ucs2Names.contains(normalized)) {
    return ucs2Codec;
  }
  return _codePages[normalized] ?? Encoding.getByName(normalized) ?? latin1;
}

class _Utf16leEncoding extends Encoding {
  const _Utf16leEncoding();

  @override
  Converter<List<int>, String> get decoder => const _Utf16leDecoder();

  @override
  Converter<String, List<int>> get encoder => const _Utf16leEncoder();

  @override
  String get name => 'utf-16le';
}

class _Utf16leEncoder extends Converter<String, List<int>> {
  const _Utf16leEncoder();

  @override
  List<int> convert(String input) => encodeUtf16le(input);
}

class _Utf16leDecoder extends Converter<List<int>, String> {
  const _Utf16leDecoder();

  @override
  String convert(List<int> input) => decodeUtf16le(input);
}

/// Encodes [input] as UTF-16LE. Dart strings are already sequences of UTF-16
/// code units, so surrogate pairs pass through intact.
Uint8List encodeUtf16le(String input) {
  final out = Uint8List(input.length * 2);
  for (var i = 0, j = 0; i < input.length; i++, j += 2) {
    final unit = input.codeUnitAt(i);
    out[j] = unit & 0xFF;
    out[j + 1] = unit >> 8;
  }
  return out;
}

/// Decodes UTF-16LE; a trailing unpaired byte becomes U+FFFD.
String decodeUtf16le(List<int> input) {
  final units = Uint16List((input.length + 1) >> 1);
  final even = input.length & ~1;
  for (var i = 0, j = 0; i < even; i += 2, j++) {
    units[j] = input[i] | (input[i + 1] << 8);
  }
  if (even != input.length) {
    units[units.length - 1] = 0xFFFD;
  }
  return String.fromCharCodes(units);
}
