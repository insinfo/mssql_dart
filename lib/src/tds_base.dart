/// tds_base.dart
///
/// Várias definições internas para o protocolo TDS.
/// Adaptado a partir do código Python original (pytds.tds_base).
/// 
/// Esta implementação define constantes de versões, tokens, flags, funções utilitárias,
/// classes de exceção e estruturas de dados usadas internamente pela biblioteca.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:galileo_utf/galileo_utf.dart';
import 'package:tuple/tuple.dart';

// -----------------------------------------------------------------------------
// TDS Protocol Versions
// -----------------------------------------------------------------------------
const int TDS70 = 0x70000000;
const int TDS71 = 0x71000000;
const int TDS71rev1 = 0x71000001;
const int TDS72 = 0x72090002;
const int TDS73A = 0x730A0003;
const int TDS73 = TDS73A;
const int TDS73B = 0x730B0003;
const int TDS74 = 0x74000004;

// Funções para verificar a versão do TDS.
// Assume-se que a classe [TdsSessionContract] (definida em outro módulo) possua o campo tdsVersion.
abstract class TdsSessionContract {
  int get tdsVersion;
}

bool isTds7Plus(TdsSessionContract session) => session.tdsVersion >= TDS70;
bool isTds71Plus(TdsSessionContract session) => session.tdsVersion >= TDS71;
bool isTds72Plus(TdsSessionContract session) => session.tdsVersion >= TDS72;
bool isTds73Plus(TdsSessionContract session) => session.tdsVersion >= TDS73A;

// -----------------------------------------------------------------------------
// Packet Types
// -----------------------------------------------------------------------------
class PacketType {
  static const int QUERY = 1;
  static const int OLDLOGIN = 2;
  static const int RPC = 3;
  static const int REPLY = 4;
  static const int CANCEL = 6;
  static const int BULK = 7;
  static const int FEDAUTHTOKEN = 8;
  static const int TRANS = 14; // Transaction management
  static const int LOGIN = 16;
  static const int AUTH = 17;
  static const int PRELOGIN = 18;
}

// -----------------------------------------------------------------------------
// TDS Login Option Flags (option_flag1, option_flag2, option_flag3)
// -----------------------------------------------------------------------------
const int TDS_BYTE_ORDER_X86 = 0;
const int TDS_CHARSET_ASCII = 0;
const int TDS_DUMPLOAD_ON = 0;
const int TDS_FLOAT_IEEE_754 = 0;
const int TDS_INIT_DB_WARN = 0;
const int TDS_SET_LANG_OFF = 0;
const int TDS_USE_DB_SILENT = 0;
const int TDS_BYTE_ORDER_68000 = 0x01;
const int TDS_CHARSET_EBDDIC = 0x02;
const int TDS_FLOAT_VAX = 0x04;
const int TDS_FLOAT_ND5000 = 0x08;
const int TDS_DUMPLOAD_OFF = 0x10; // Prevent BCP
const int TDS_USE_DB_NOTIFY = 0x20;
const int TDS_INIT_DB_FATAL = 0x40;
const int TDS_SET_LANG_ON = 0x80;

// option_flag2 values
const int TDS_INIT_LANG_WARN = 0;
const int TDS_INTEGRATED_SECURTY_OFF = 0;
const int TDS_ODBC_OFF = 0;
const int TDS_USER_NORMAL = 0; // SQL Server login
const int TDS_INIT_LANG_REQUIRED = 0x01;
const int TDS_ODBC_ON = 0x02;
const int TDS_TRANSACTION_BOUNDARY71 = 0x04; // removido no TDS 7.2
const int TDS_CACHE_CONNECT71 = 0x08; // removido no TDS 7.2
const int TDS_USER_SERVER = 0x10; // reservado
const int TDS_USER_REMUSER = 0x20; // DQ login
const int TDS_USER_SQLREPL = 0x40; // replication login
const int TDS_INTEGRATED_SECURITY_ON = 0x80;

// option_flag3 values (TDS 7.3+)
const int TDS_RESTRICTED_COLLATION = 0;
const int TDS_CHANGE_PASSWORD = 0x01;
const int TDS_SEND_YUKON_BINARY_XML = 0x02;
const int TDS_REQUEST_USER_INSTANCE = 0x04;
const int TDS_UNKNOWN_COLLATION_HANDLING = 0x08;
const int TDS_ANY_COLLATION = 0x10;

// -----------------------------------------------------------------------------
// TDS Tokens
// -----------------------------------------------------------------------------
const int TDS5_PARAMFMT2_TOKEN = 32;
const int TDS_LANGUAGE_TOKEN = 33;
const int TDS_ORDERBY2_TOKEN = 34;
const int TDS_ROWFMT2_TOKEN = 97;
const int TDS_LOGOUT_TOKEN = 113;
const int TDS_RETURNSTATUS_TOKEN = 121;
const int TDS_PROCID_TOKEN = 124;
const int TDS7_RESULT_TOKEN = 129;
const int TDS7_COMPUTE_RESULT_TOKEN = 136;
const int TDS_COLNAME_TOKEN = 160;
const int TDS_COLFMT_TOKEN = 161;
const int TDS_DYNAMIC2_TOKEN = 163;
const int TDS_TABNAME_TOKEN = 164;
const int TDS_COLINFO_TOKEN = 165;
const int TDS_OPTIONCMD_TOKEN = 166;
const int TDS_COMPUTE_NAMES_TOKEN = 167;
const int TDS_COMPUTE_RESULT_TOKEN = 168;
const int TDS_ORDERBY_TOKEN = 169;
const int TDS_ERROR_TOKEN = 170;
const int TDS_INFO_TOKEN = 171;
const int TDS_PARAM_TOKEN = 172;
const int TDS_LOGINACK_TOKEN = 173;
const int TDS_CONTROL_TOKEN = 174;
const int TDS_ROW_TOKEN = 209;
const int TDS_NBC_ROW_TOKEN = 210;
const int TDS_CMP_ROW_TOKEN = 211;
const int TDS5_PARAMS_TOKEN = 215;
const int TDS_CAPABILITY_TOKEN = 226;
const int TDS_ENVCHANGE_TOKEN = 227;
const int TDS_DBRPC_TOKEN = 230;
const int TDS5_DYNAMIC_TOKEN = 231;
const int TDS5_PARAMFMT_TOKEN = 236;
const int TDS_AUTH_TOKEN = 237;
const int TDS_RESULT_TOKEN = 238;
const int TDS_DONE_TOKEN = 253;
const int TDS_DONEPROC_TOKEN = 254;
const int TDS_DONEINPROC_TOKEN = 255;

// CURSOR support (TDS 5.0 only)
const int TDS_CURCLOSE_TOKEN = 128;
const int TDS_CURDELETE_TOKEN = 129;
const int TDS_CURFETCH_TOKEN = 130;
const int TDS_CURINFO_TOKEN = 131;
const int TDS_CUROPEN_TOKEN = 132;
const int TDS_CURDECLARE_TOKEN = 134;

// -----------------------------------------------------------------------------
// Environment Type Field Constants
// -----------------------------------------------------------------------------
const int TDS_ENV_DATABASE = 1;
const int TDS_ENV_LANG = 2;
const int TDS_ENV_CHARSET = 3;
const int TDS_ENV_PACKSIZE = 4;
const int TDS_ENV_LCID = 5;
const int TDS_ENV_UNICODE_DATA_SORT_COMP_FLAGS = 6;
const int TDS_ENV_SQLCOLLATION = 7;
const int TDS_ENV_BEGINTRANS = 8;
const int TDS_ENV_COMMITTRANS = 9;
const int TDS_ENV_ROLLBACKTRANS = 10;
const int TDS_ENV_ENLIST_DTC_TRANS = 11;
const int TDS_ENV_DEFECT_TRANS = 12;
const int TDS_ENV_DB_MIRRORING_PARTNER = 13;
const int TDS_ENV_PROMOTE_TRANS = 15;
const int TDS_ENV_TRANS_MANAGER_ADDR = 16;
const int TDS_ENV_TRANS_ENDED = 17;
const int TDS_ENV_RESET_COMPLETION_ACK = 18;
const int TDS_ENV_INSTANCE_INFO = 19;
const int TDS_ENV_ROUTING = 20;

// -----------------------------------------------------------------------------
// Stored Procedure IDs (Microsoft internal)
// -----------------------------------------------------------------------------
const int TDS_SP_CURSOR = 1;
const int TDS_SP_CURSOROPEN = 2;
const int TDS_SP_CURSORPREPARE = 3;
const int TDS_SP_CURSOREXECUTE = 4;
const int TDS_SP_CURSORPREPEXEC = 5;
const int TDS_SP_CURSORUNPREPARE = 6;
const int TDS_SP_CURSORFETCH = 7;
const int TDS_SP_CURSOROPTION = 8;
const int TDS_SP_CURSORCLOSE = 9;
const int TDS_SP_EXECUTESQL = 10;
const int TDS_SP_PREPARE = 11;
const int TDS_SP_EXECUTE = 12;
const int TDS_SP_PREPEXEC = 13;
const int TDS_SP_PREPEXECRPC = 14;
const int TDS_SP_UNPREPARE = 15;

// -----------------------------------------------------------------------------
// Flags returned in TDS_DONE token
// -----------------------------------------------------------------------------
const int TDS_DONE_FINAL = 0;
const int TDS_DONE_MORE_RESULTS = 0x01; // more results follow
const int TDS_DONE_ERROR = 0x02; // error occurred
const int TDS_DONE_INXACT = 0x04; // transaction in progress
const int TDS_DONE_PROC = 0x08; // results from a stored procedure
const int TDS_DONE_COUNT = 0x10; // count field is valid
const int TDS_DONE_CANCELLED = 0x20; // attention command (cancel)
const int TDS_DONE_EVENT = 0x40; // event notification
const int TDS_DONE_SRVERROR = 0x100; // SQL Server error

// -----------------------------------------------------------------------------
// TDS Data Types & Type Flags
// -----------------------------------------------------------------------------
const int SYBVOID = 31;
const int IMAGETYPE = 34; // also SYBIMAGE
const int TEXTTYPE = 35; // also SYBTEXT
const int SYBVARBINARY = 37;
const int INTNTYPE = 38; // also SYBINTN
const int SYBVARCHAR = 39;
const int BINARYTYPE = 45; // also SYBBINARY
const int SYBCHAR = 47;
const int INT1TYPE = 48; // also SYBINT1
const int BITTYPE = 50; // also SYBBIT
const int INT2TYPE = 52; // also SYBINT2
const int INT4TYPE = 56; // also SYBINT4
const int DATETIM4TYPE = 58; // also SYBDATETIME4
const int FLT4TYPE = 59; // also SYBREAL
const int MONEYTYPE = 60; // also SYBMONEY
const int DATETIMETYPE = 61; // also SYBDATETIME
const int FLT8TYPE = 62; // also SYBFLT8
const int NTEXTTYPE = 99; // also SYBNTEXT
const int SYBNVARCHAR = 103;
const int BITNTYPE = 104; // also SYBBITN
const int NUMERICNTYPE = 108; // also SYBNUMERIC
const int DECIMALNTYPE = 106; // also SYBDECIMAL
const int FLTNTYPE = 109; // also SYBFLTN
const int MONEYNTYPE = 110; // also SYBMONEYN
const int DATETIMNTYPE = 111; // also SYBDATETIMN
const int MONEY4TYPE = 122; // also SYBMONEY4

const int INT8TYPE = 127; // also SYBINT8
const int BIGCHARTYPE = 175; // also XSYBCHAR
const int BIGVARCHRTYPE = 167; // also XSYBVARCHAR
const int NVARCHARTYPE = 231; // also XSYBNVARCHAR
const int NCHARTYPE = 239; // also XSYBNCHAR
const int BIGVARBINTYPE = 165; // also XSYBVARBINARY
const int BIGBINARYTYPE = 173; // also XSYBBINARY
const int GUIDTYPE = 36; // also SYBUNIQUE
const int SSVARIANTTYPE = 98; // also SYBVARIANT
const int UDTTYPE = 240; // also SYBMSUDT
const int XMLTYPE = 241; // also SYBMSXML
const int TVPTYPE = 243;
const int DATENTYPE = 40; // also SYBMSDATE
const int TIMENTYPE = 41; // also SYBMSTIME
const int DATETIME2NTYPE = 42; // also SYBMSDATETIME2
const int DATETIMEOFFSETNTYPE = 43; // also SYBMSDATETIMEOFFSET

// TDS type flags
const int TDS_FSQLTYPE_SQL_DFLT = 0x00;
const int TDS_FSQLTYPE_SQL_TSQL = 0x01;
const int TDS_FOLEDB = 0x10;
const int TDS_FREADONLY_INTENT = 0x20;

// Sybase-only types
const int SYBLONGBINARY = 225;
const int SYBUINT1 = 64;
const int SYBUINT2 = 65;
const int SYBUINT4 = 66;
const int SYBUINT8 = 67;
const int SYBBLOB = 36;
const int SYBBOUNDARY = 104;
const int SYBDATE = 49;
const int SYBDATEN = 123;
const int SYB5INT8 = 191;
const int SYBINTERVAL = 46;
const int SYBLONGCHAR = 175;
const int SYBSENSITIVITY = 103;
const int SYBSINT1 = 176;
const int SYBTIME = 51;
const int SYBTIMEN = 147;
const int SYBUINTN = 68;
const int SYBUNITEXT = 174;
const int SYBXML = 163;

const int TDS_UT_TIMESTAMP = 80;

// Compute operators
const int SYBAOPCNT = 0x4B;
const int SYBAOPCNTU = 0x4C;
const int SYBAOPSUM = 0x4D;
const int SYBAOPSUMU = 0x4E;
const int SYBAOPAVG = 0x4F;
const int SYBAOPAVGU = 0x50;
const int SYBAOPMIN = 0x51;
const int SYBAOPMAX = 0x52;

// MSSQL 2000 compute operators
const int SYBAOPCNT_BIG = 0x09;
const int SYBAOPSTDEV = 0x30;
const int SYBAOPSTDEVP = 0x31;
const int SYBAOPVAR = 0x32;
const int SYBAOPVARP = 0x33;
const int SYBAOPCHECKSUM_AGG = 0x72;

// -----------------------------------------------------------------------------
// Param Flags
// -----------------------------------------------------------------------------
const int fByRefValue = 1;
const int fDefaultValue = 2;

// -----------------------------------------------------------------------------
// Connection States
// -----------------------------------------------------------------------------
const int TDS_IDLE = 0;
const int TDS_QUERYING = 1;
const int TDS_PENDING = 2;
const int TDS_READING = 3;
const int TDS_DEAD = 4;
final List<String> stateNames = ["IDLE", "QUERYING", "PENDING", "READING", "DEAD"];

const int TDS_ENCRYPTION_OFF = 0;
const int TDS_ENCRYPTION_REQUEST = 1;
const int TDS_ENCRYPTION_REQUIRE = 2;

// -----------------------------------------------------------------------------
// PreLogin Tokens and Encryption
// -----------------------------------------------------------------------------
class PreLoginToken {
  static const int VERSION = 0;
  static const int ENCRYPTION = 1;
  static const int INSTOPT = 2;
  static const int THREADID = 3;
  static const int MARS = 4;
  static const int TRACEID = 5;
  static const int FEDAUTHREQUIRED = 6;
  static const int NONCEOPT = 7;
  static const int TERMINATOR = 0xFF;
}

class PreLoginEnc {
  static const int ENCRYPT_OFF = 0; // Encryption available but off
  static const int ENCRYPT_ON = 1;  // Encryption available and on
  static const int ENCRYPT_NOT_SUP = 2; // Encryption not available
  static const int ENCRYPT_REQ = 3; // Encryption required
}

// -----------------------------------------------------------------------------
// PLP Constants and TVP Tokens
// -----------------------------------------------------------------------------
const int PLP_MARKER = 0xFFFF;
const int PLP_NULL = 0xFFFFFFFFFFFFFFFF; // 64-bit
const int PLP_UNKNOWN = 0xFFFFFFFFFFFFFFFE; // 64-bit

const int TDS_NO_COUNT = -1;

const int TVP_NULL_TOKEN = 0xFFFF;
const int TVP_COLUMN_DEFAULT_FLAG = 0x200;
const int TVP_END_TOKEN = 0x00;
const int TVP_ROW_TOKEN = 0x01;
const int TVP_ORDER_UNIQUE_TOKEN = 0x10;
const int TVP_COLUMN_ORDERING_TOKEN = 0x11;

// -----------------------------------------------------------------------------
// Common Equality Mixin
// -----------------------------------------------------------------------------
mixin CommonEqualityMixin {
  @override
  bool operator ==(Object other) {
    return other.runtimeType == runtimeType && toString() == other.toString();
  }

  @override
  int get hashCode => toString().hashCode;
}

// -----------------------------------------------------------------------------
// Utility Functions
// -----------------------------------------------------------------------------

/// Itera sobre pedaços de bytes (chunks) e os decodifica usando o [codec].
Iterable<String> iterdecode(Iterable<List<int>> iterable, Encoding codec) sync* {
  var decoder = codec.decoder;
  for (var chunk in iterable) {
    yield decoder.convert(chunk);
  }
  yield decoder.convert([]);
}

/// Converte a entrada em string. Se for uma lista de bytes, decodifica com UTF-8.
String forceUnicode(dynamic s) {
  if (s is List<int>) {
    try {
      return utf8.decode(s);
    } catch (e) {
      throw DatabaseError(e.toString());
    }
  } else if (s is String) {
    return s;
  } else {
    return s.toString();
  }
}

/// Cita um identificador conforme as regras do MSSQL.
String tdsQuoteId(String ident) {
  return "[${ident.replaceAll("]", "]]")}]";
}

const Set<int> progErrors = {
  102,
  207,
  208,
  2812,
  4104,
};

const Set<int> integrityErrors = {
  515,
  547,
  2601,
  2627,
};

/// Função identidade para valores (equivalente a ord() em Python).
int myOrd(dynamic val) => val;

/// Junta uma lista de listas de inteiros (byte arrays) em um único array.
List<int> joinByteArrays(Iterable<List<int>> ba) {
  return ba.expand((element) => element).toList();
}

// -----------------------------------------------------------------------------
// Exceções e Hierarquia de Erros
// -----------------------------------------------------------------------------
class Warning implements Exception {
  final String message;
  Warning(this.message);
  @override
  String toString() => "Warning: $message";
}

class Error implements Exception {
  final String message;
  Error(this.message);
  @override
  String toString() => "Error: $message";
}

class InterfaceError extends Error {
  InterfaceError(String message) : super(message);
}

typedef TimeoutError = TimeoutException;

class DatabaseError extends Error {
  int msgNo = 0;
  String text;
  String srvName = "";
  String procName = "";
  int number = 0;
  int severity = 0;
  int state = 0;
  int line = 0;

  DatabaseError(String message, [dynamic exc])
      : text = message,
        super(message);

  String get message {
    if (procName.isNotEmpty) {
      return "SQL Server message $number, severity $severity, state $state, procedure $procName, line $line:\n$text";
    } else {
      return "SQL Server message $number, severity $severity, state $state, line $line:\n$text";
    }
  }
}

class ClosedConnectionError extends InterfaceError {
  ClosedConnectionError() : super("Server closed connection");
}

class DataError extends Error {
  DataError(String message) : super(message);
}

class OperationalError extends DatabaseError {
  OperationalError(String message) : super(message);
}

class LoginError extends OperationalError {
  LoginError(String message) : super(message);
}

class IntegrityError extends DatabaseError {
  IntegrityError(String message) : super(message);
}

class InternalError extends DatabaseError {
  InternalError(String message) : super(message);
}

class ProgrammingError extends DatabaseError {
  ProgrammingError(String message) : super(message);
}

class NotSupportedError extends DatabaseError {
  NotSupportedError(String message) : super(message);
}

// -----------------------------------------------------------------------------
// DB-API Type Definitions
// -----------------------------------------------------------------------------
class DBAPITypeObject {
  final Set<int> values;
  DBAPITypeObject(List<int> values) : values = values.toSet();

  @override
  bool operator ==(Object other) {
    if (other is int) return values.contains(other);
    return false;
  }

  @override
  int get hashCode => values.hashCode;
}

// Standard DB-API type objects
final DBAPITypeObject STRING = DBAPITypeObject([
  SYBVARCHAR,
  SYBCHAR,
  TEXTTYPE,
  NVARCHARTYPE,
  NCHARTYPE,
  NTEXTTYPE,
  NVARCHARTYPE,
  SYBCHAR,
  XMLTYPE,
]);
final DBAPITypeObject BINARY = DBAPITypeObject([
  IMAGETYPE,
  BINARYTYPE,
  SYBVARBINARY,
  BIGVARBINTYPE,
  BIGBINARYTYPE,
]);
final DBAPITypeObject NUMBER = DBAPITypeObject([
  BITTYPE, BITNTYPE, INT1TYPE, INT2TYPE, INT4TYPE, INT8TYPE, INTNTYPE, FLT4TYPE, FLT8TYPE, FLTNTYPE,
]);
final DBAPITypeObject DATETIME = DBAPITypeObject([
  DATETIMETYPE, DATETIM4TYPE, DATETIMNTYPE,
]);
final DBAPITypeObject DECIMAL = DBAPITypeObject([
  MONEYTYPE, MONEY4TYPE, MONEYNTYPE, NUMERICNTYPE, DECIMALNTYPE,
]);
final DBAPITypeObject ROWID = DBAPITypeObject([]);

// Non-standard but useful type objects
final DBAPITypeObject INTEGER = DBAPITypeObject([
  BITTYPE, BITNTYPE, INT1TYPE, INT2TYPE, INT4TYPE, INT8TYPE, INTNTYPE,
]);
final DBAPITypeObject REAL = DBAPITypeObject([
  FLT4TYPE, FLT8TYPE, FLTNTYPE,
]);
final DBAPITypeObject XML = DBAPITypeObject([XMLTYPE]);

// -----------------------------------------------------------------------------
// Internal Stored Procedures
// -----------------------------------------------------------------------------
class InternalProc {
  final int procId;
  final String name;
  InternalProc(this.procId, this.name);

  @override
  String toString() => name;
}

final InternalProc SP_EXECUTESQL = InternalProc(TDS_SP_EXECUTESQL, "sp_executesql");
final InternalProc SP_PREPARE = InternalProc(TDS_SP_PREPARE, "sp_prepare");
final InternalProc SP_EXECUTE = InternalProc(TDS_SP_EXECUTE, "sp_execute");

// -----------------------------------------------------------------------------
// Funções de Leitura de Dados
// -----------------------------------------------------------------------------

/// Lê exatamente [size] bytes do stream [stm] e ignora-os.
/// Se EOF for alcançado antes, lança ClosedConnectionError.
void skipall(TransportProtocol stm, int size) {
  final res = stm.recv(size);
  if (res.length == size) {
    return;
  }
  if (res.isEmpty) {
    throw ClosedConnectionError();
  }
  var left = size - res.length;
  while (left > 0) {
    final buf = stm.recv(left);
    if (buf.isEmpty) {
      throw ClosedConnectionError();
    }
    left -= buf.length;
  }
}

/// Retorna um Iterable que gera pedaços (chunks) de [size] bytes lidos do stream [stm].
Iterable<List<int>> readChunks(TransportProtocol stm, int size) sync* {
  if (size == 0) {
    yield <int>[];
    return;
  }
  final res = stm.recv(size);
  if (res.isEmpty) {
    throw ClosedConnectionError();
  }
  yield res;
  var left = size - res.length;
  while (left > 0) {
    final buf = stm.recv(left);
    if (buf.isEmpty) {
      throw ClosedConnectionError();
    }
    yield buf;
    left -= buf.length;
  }
}

/// Lê exatamente [size] bytes do stream [stm].
List<int> readall(TransportProtocol stm, int size) {
  return joinByteArrays(readChunks(stm, size));
}

/// Uma versão “rápida” de readall para dados pequenos.
/// Retorna uma tupla com a lista de bytes e um offset (0 neste placeholder).
Tuple2<List<int>, int> readallFast(TransportProtocol stm, int size) {
  var buf = stm.recv(size);
  if (buf.length >= size) {
    return Tuple2(buf, 0);
  }

  final aggregated = List<int>.from(buf);
  while (aggregated.length < size) {
    final chunk = stm.recv(size - aggregated.length);
    if (chunk.isEmpty) {
      throw ClosedConnectionError();
    }
    aggregated.addAll(chunk);
  }
  return Tuple2(aggregated, 0);
}

/// Retorna o total de segundos de um Duration.
int totalSeconds(Duration td) => td.inSeconds;

// -----------------------------------------------------------------------------
// Classes Param e Column
// -----------------------------------------------------------------------------
class Param {
  String name;
  dynamic type;
  dynamic value;
  int flags;
  Param({this.name = "", this.type, this.value, this.flags = 0});
}

class Column with CommonEqualityMixin {
  Encoding? charCodec;
  String columnName;
  int columnUserType;
  int flags;
  dynamic type;
  dynamic value;
  dynamic serializer;

  Column({this.columnName = "", this.type, this.flags = fNullable, this.value})
      : columnUserType = 0;

  static const int fNullable = 1;
  static const int fCaseSen = 2;
  static const int fReadWrite = 8;
  static const int fIdentity = 0x10;
  static const int fComputed = 0x20;

  dynamic chooseSerializer(dynamic typeFactory, dynamic collation) {
    // Placeholder: implementar conforme a lógica do typeFactory.
    return typeFactory.serializerByType(sqlType: type, collation: collation);
  }

  @override
  String toString() {
    var val = value;
    if (val is List<int> && val.length > 100) {
      val = "${val.sublist(0, 100)}... len is ${val.length}";
    }
    if (val is String && val.length > 100) {
      val = "${val.substring(0, 100)}... len is ${val.length}";
    }
    return "<Column(name: $columnName, type: $type, value: $val, flags: $flags, user_type: $columnUserType, codec: $charCodec)>";
  }
}

// -----------------------------------------------------------------------------
// Protocols: Transport, LoadBalancer e Auth
// -----------------------------------------------------------------------------
abstract class TransportProtocol {
  bool isConnected();
  void close();
  double? get timeout;
  set timeout(double? value);
  void sendall(List<int> buf, {int flags = 0});
  List<int> recv(int size);
  int recvInto(ByteBuffer buf, {int size = 0, int flags = 0});
}

abstract class AsyncTransportProtocol {
  bool get isConnected;
  Future<void> close();
  Duration? get timeout;
  set timeout(Duration? value);
  Future<void> sendAll(List<int> data, {int flags = 0});
  Future<Uint8List> recv(int size);
  Future<Uint8List> recvAvailable(int maxSize);
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0});
}

abstract class LoadBalancer {
  Iterable<String> choose();
}

abstract class AuthProtocol {
  List<int> createPacket();
  List<int>? handleNext(List<int> packet);
  void close();
}

// -----------------------------------------------------------------------------
// Estruturas para processamento de headers e outros (usando ByteData)
// -----------------------------------------------------------------------------
final ByteData header = ByteData(8); // conforme a struct ">BBHHBx" (8 bytes)
final ByteData byteData1 = ByteData(1);
final ByteData smallintLe = ByteData(2);
final ByteData smallintBe = ByteData(2);
final ByteData usmallintLe = ByteData(2);
final ByteData usmallintBe = ByteData(2);
final ByteData intLe = ByteData(4);
final ByteData intBe = ByteData(4);
final ByteData uintLe = ByteData(4);
final ByteData uintBe = ByteData(4);
final ByteData int8Le = ByteData(8);
final ByteData int8Be = ByteData(8);
final ByteData uint8Le = ByteData(8);
final ByteData uint8Be = ByteData(8);

bool loggingEnabled = false;

// -----------------------------------------------------------------------------
// Output Parameter Class
// -----------------------------------------------------------------------------
class Output {
  dynamic _type;
  dynamic _value;
  Output({dynamic value, dynamic paramType}) {
    if (paramType == null) {
      if (value == null) {
        throw ArgumentError("Output type cannot be autodetected");
      }
    } else if (paramType is Type && value != null) {
      // Verificação simples; ajuste conforme necessário.
      if (value != defaultValue && value.runtimeType != paramType) {
        throw ArgumentError("Value should match paramType, value is $value, paramType is $paramType");
      }
    }
    _type = paramType;
    _value = value;
  }

  dynamic get type => _type;
  dynamic get value => _value;
}

class _Default {}
final defaultValue = _Default();

// -----------------------------------------------------------------------------
// tds7_crypt_pass: "Mangle" a senha conforme as regras TDS.
// -----------------------------------------------------------------------------
List<int> tds7CryptPass(String password) {
  final mangled = List<int>.from(encodeUtf16le(password, false));
  for (int i = 0; i < mangled.length; i++) {
    final ch = mangled[i];
    mangled[i] = (((ch << 4) & 0xFF) | (ch >> 4)) ^ 0xA5;
  }
  return mangled;
}

// -----------------------------------------------------------------------------
// _TdsLogin Class
// -----------------------------------------------------------------------------

/// Backend TLS preferido pelo cliente.
enum TlsBackend {
  /// Usa o SecureSocket nativo do Dart (requer conexão TLS-first).
  dartSecureSocket,
  
  /// Usa OpenSSL via FFI (permite upgrade mid-stream).
  openSsl,
  
  /// Usa implementação pura Dart do tlslite (permite upgrade mid-stream).
  tlslite,
}

class TdsLogin {
  String clientHostName = "";
  String library = "";
  String serverName = "";
  String instanceName = "";
  String userName = "";
  String password = "";
  String appName = "";
  int? port;
  String language = "";
  String attachDbFile = "";
  int tdsVersion = TDS74;
  String database = "";
  bool bulkCopy = false;
  int clientLcid = 0;
  bool useMars = false;
  int pid = 0;
  String changePassword = "";
  int clientId = 0;
  String? cafile;
  bool validateHost = true;
  bool encLoginOnly = false;
  int encFlag = 0;
  dynamic tlsCtx; // Contexto TLS (SecurityContext ou similar)
  
  /// Backend TLS preferido para upgrade mid-stream.
  /// O padrão é [TlsBackend.tlslite].
  TlsBackend tlsBackend = TlsBackend.tlslite;
  
  DateTime clientTz = DateTime.now(); // Placeholder para timezone
  int optionFlag2 = 0;
  double connectTimeout = 0.0;
  double? queryTimeout;
  int blocksize = 4096;
  bool readonly = false;
  LoadBalancer? loadBalancer;
  bool bytesToUnicode = false;
  AuthProtocol? auth;
  Queue<Tuple3<dynamic, int?, String>> servers = Queue<Tuple3<dynamic, int?, String>>();
  int serverEncFlag = 0;
}

// Helper Tuple3 para a fila de servidores.
class Tuple3<T1, T2, T3> {
  final T1 item1;
  final T2 item2;
  final T3 item3;
  Tuple3(this.item1, this.item2, this.item3);
}

// -----------------------------------------------------------------------------
// _TdsEnv Class
// -----------------------------------------------------------------------------
class TdsEnv {
  String? database;
  String? language;
  String? charset;
  String? mirroringPartner;
  bool autocommit = false;
  int isolationLevel = 0;
}

// -----------------------------------------------------------------------------
// _create_exception_by_message
// -----------------------------------------------------------------------------
DatabaseError createExceptionByMessage(Message msg, {String? customErrorMsg}) {
  final msgNo = msg["msgno"] as int? ?? 0;
  final errorMsg = customErrorMsg ?? (msg["message"] as String? ?? "");

  DatabaseError ex;
  if (progErrors.contains(msgNo)) {
    ex = ProgrammingError(errorMsg);
  } else if (integrityErrors.contains(msgNo)) {
    ex = IntegrityError(errorMsg);
  } else {
    ex = OperationalError(errorMsg);
  }

  ex.msgNo = msgNo;
  ex.text = msg["message"] as String? ?? errorMsg;
  ex.srvName = msg["server"] as String? ?? "";
  ex.procName = msg["proc_name"] as String? ?? "";
  ex.number = msgNo;
  ex.severity = msg["severity"] as int? ?? 0;
  ex.state = msg["state"] as int? ?? 0;
  ex.line = msg["line_number"] as int? ?? 0;
  return ex;
}

// Message e Route são representados como Map<String, dynamic>
typedef Message = Map<String, dynamic>;
typedef Route = Map<String, dynamic>;

// -----------------------------------------------------------------------------
// _Results Class
// -----------------------------------------------------------------------------
class Results {
  List<Column> columns = [];
  int rowCount = 0;
  // Descrição dos resultados (lista de listas, cada coluna com seus metadados)
  List<List<dynamic>> description = [];
}
