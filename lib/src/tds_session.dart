import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'collate.dart';
import 'row_strategies.dart';
import 'session_link.dart';
import 'tds_base.dart' as tds;
import 'tds_reader.dart';
import 'tds_writer.dart';
import 'tds_types.dart';

const int _clientLibraryVersion = 0x01000000;
const String _defaultInstanceName = 'MSSQLServer';

/// Builder padrão usado enquanto o restante do port não disponibiliza uma
/// sessão completa.
final SessionBuilder defaultSessionBuilder =
    (context) => TdsSession.fromContext(context);

class TdsSession implements SessionLink, tds.TdsSessionContract {
  TdsSession({
    required tds.TransportProtocol transport,
    required tds.TdsEnv env,
    required int bufsize,
    this.tzinfoFactory,
    RowStrategy? rowStrategy,
    SerializerFactory? typeFactory,
    Collation? initialCollation,
    bool bytesToUnicode = true,
    void Function(Collation?)? onCollationChanged,
    void Function(int newTransactionId)? onTransactionStateChange,
    void Function(tds.Route route)? onRouteChange,
    void Function(String flags)? onUnicodeSortFlags,
    SessionTraceHook? traceHook,
  })  : _transport = transport,
        _env = env,
        _typeFactory = typeFactory ?? SerializerFactory(tds.TDS74),
        _connectionCollation = initialCollation,
        _bytesToUnicode = bytesToUnicode,
        _onCollationChanged = onCollationChanged,
        _onTransactionStateChange = onTransactionStateChange,
        _onRouteChange = onRouteChange,
        _onUnicodeSortFlags = onUnicodeSortFlags,
        _traceHook = traceHook {
    _setRowStrategy(rowStrategy ?? defaultRowStrategy);
    _collation = initialCollation;
    _reader = TdsReader(
      transport: transport,
      session: this,
      bufsize: bufsize,
    );
    _writer = TdsWriter(
      transport: transport,
      session: this,
      bufsize: bufsize,
    );
  }

  factory TdsSession.fromContext(SessionBuildContext context) {
    return TdsSession(
      transport: context.transport,
      env: context.env,
      bufsize: context.bufsize,
      tzinfoFactory: context.tzinfoFactory,
      rowStrategy: context.rowStrategy,
      typeFactory: context.typeFactory,
      initialCollation: context.collation,
      bytesToUnicode: context.bytesToUnicode,
      onCollationChanged: context.onCollationChanged,
      onTransactionStateChange: context.onTransactionStateChange,
      onRouteChange: context.onRouteChange,
      onUnicodeSortFlags: context.onUnicodeSortFlags,
      traceHook: context.traceHook,
    );
  }

  final tds.TransportProtocol _transport;
  final tds.TdsEnv _env;
  late final TdsReader _reader;
  late final TdsWriter _writer;
  final TzInfoFactory? tzinfoFactory;
  late RowStrategy _rowStrategy;
  late RowGenerator _rowConvertor;
  late SerializerFactory _typeFactory;
  Collation? _connectionCollation;
  bool _bytesToUnicode;
  final void Function(Collation?)? _onCollationChanged;
  final void Function(int)? _onTransactionStateChange;
  final void Function(tds.Route)? _onRouteChange;
  final void Function(String)? _onUnicodeSortFlags;
  final SessionTraceHook? _traceHook;
  static final DateTime _baseDate1900 = DateTime.utc(1900, 1, 1);
  static final DateTime _baseDate0001 = DateTime.utc(1, 1, 1);
  final Queue<dynamic> _rowBuffer = ListQueue<dynamic>();

  final List<tds.Message> _messages = [];
  tds.AuthProtocol? _authentication;
  int _state = tds.TDS_IDLE;
  int _tdsVersion = tds.TDS74;
  String? _lastQuery;
  int _doneFlags = 0;
  int _rowsAffected = tds.TDS_NO_COUNT;
  int? _returnStatus;
  bool _hasStatus = false;
  bool _inCancel = false;
  bool _moreRows = false;
  Collation? _collation;
  tds.Results? _results;
  List<dynamic> _currentRow = const <dynamic>[];
  bool _skippedToStatus = false;
  void _trace(String event, [Map<String, Object?>? data]) {
    final hook = _traceHook;
    if (hook == null) {
      return;
    }
    if (data == null || data.isEmpty) {
      hook(event, const {});
      return;
    }
    hook(event, Map.unmodifiable(data));
  }

  void _enforceSyncEncryptionPolicy(tds.TdsLogin login, int cryptFlag) {
    switch (cryptFlag) {
      case tds.PreLoginEnc.ENCRYPT_OFF:
        if (login.encFlag == tds.PreLoginEnc.ENCRYPT_ON) {
          _badStream('Servidor não aceitou criptografia obrigatória');
        }
        if (login.encFlag == tds.PreLoginEnc.ENCRYPT_OFF ||
            login.encFlag == tds.PreLoginEnc.ENCRYPT_REQ) {
          _failSyncTls(
            'O cliente solicitou criptografia apenas para o LOGIN, recurso indisponível no modo síncrono.',
          );
        }
        return;
      case tds.PreLoginEnc.ENCRYPT_ON:
      case tds.PreLoginEnc.ENCRYPT_REQ:
        _failSyncTls(
          'O servidor exige criptografia TLS (crypt_flag=$cryptFlag).',
        );
      case tds.PreLoginEnc.ENCRYPT_NOT_SUP:
        if (login.encFlag != tds.PreLoginEnc.ENCRYPT_NOT_SUP) {
          _failSyncTls(
            'Foi solicitada criptografia pelo cliente, porém o servidor não suporta.',
          );
        }
        return;
    }
  }

  Never _failSyncTls(String reason) {
    close();
    throw tds.NotSupportedError(
      '$reason Conexões síncronas ainda não suportam TLS; utilize connectAsync() para habilitar criptografia.',
    );
  }

  SerializerFactory get typeFactory => _typeFactory;
  Collation? get connectionCollation => _connectionCollation;
  bool get bytesToUnicode => _bytesToUnicode;

  int get rowsAffected => _rowsAffected;
  int? get returnStatus => _returnStatus;
  bool get hasReturnStatus => _hasStatus;
  bool get moreResults => _moreRows;
  Collation? get collation => _collation;
  RowStrategy get rowStrategy => _rowStrategy;
  tds.Results? get results => _results;
  List<dynamic> get currentRow => _currentRow;
  bool get skippedToStatus => _skippedToStatus;
  bool get hasBufferedRows => _rowBuffer.isNotEmpty;
  int get bufferedRowCount => _rowBuffer.length;

  String? get lastQuery => _lastQuery;

  tds.TdsEnv get env => _env;
  List<tds.Message> get messages => _messages;

  @override
  tds.TransportProtocol get transport => _transport;

  @override
  int get writerBufferSize => _writer.bufsize;

  @override
  int get readerBlockSize => _reader.blockSize;

  @override
  void setReaderBlockSize(int size) {
    _reader.setBlockSize(size);
  }

  @override
  void sendPrelogin(tds.TdsLogin login) {
    _tdsVersion = login.tdsVersion;
    final instance =
        login.instanceName.isEmpty ? _defaultInstanceName : login.instanceName;
    final instanceBytes = ascii.encode(instance);
    final startPos = tds.isTds72Plus(this) ? 26 : 21;
    final header = Uint8List(startPos);
    final view = ByteData.sublistView(header);
    var cursor = 0;
    var payloadOffset = startPos;

    void writeEntry(int token, int length) {
      view.setUint8(cursor, token);
      view.setUint16(cursor + 1, payloadOffset, Endian.big);
      view.setUint16(cursor + 3, length, Endian.big);
      cursor += 5;
      payloadOffset += length;
    }

    writeEntry(tds.PreLoginToken.VERSION, 6);
    writeEntry(tds.PreLoginToken.ENCRYPTION, 1);
    writeEntry(tds.PreLoginToken.INSTOPT, instanceBytes.length + 1);
    writeEntry(tds.PreLoginToken.THREADID, 4);
    if (tds.isTds72Plus(this)) {
      writeEntry(tds.PreLoginToken.MARS, 1);
    }
    view.setUint8(cursor, tds.PreLoginToken.TERMINATOR);

    _writer.beginPacket(tds.PacketType.PRELOGIN);
    _writer.write(header);
    _writer.putUIntBe(_clientLibraryVersion);
    _writer.putUSmallIntBe(0); // build number
    _writer.putByte(login.encFlag);
    _writer.write(instanceBytes);
    _writer.putByte(0);
    _writer.putInt(0); // thread id placeholder
    if (tds.isTds72Plus(this)) {
      _writer.putByte(login.useMars ? 1 : 0);
    }
    _trace('prelogin.send', {
      'tds_version': '0x${login.tdsVersion.toRadixString(16)}',
      'enc_flag': login.encFlag,
      'instance': instance,
      'mars': login.useMars,
    });
    _writer.flush();
    _state = tds.TDS_PENDING;
  }

  @override
  void processPrelogin(tds.TdsLogin login) {
    final resp = beginResponse();
    final payload = _reader.readWholePacket();
    if (resp.type != tds.PacketType.REPLY) {
      _badStream(
        'Tipo de pacote inesperado durante PRELOGIN: ${resp.type}',
      );
    }
    _parsePrelogin(payload, login);
  }

  void _parsePrelogin(List<int> octets, tds.TdsLogin login) {
    if (octets.isEmpty) {
      _badStream('Resposta PRELOGIN vazia');
    }
    final data = Uint8List.fromList(octets);
    final size = data.length;
    final byteView = ByteData.sublistView(data);
    var offset = 0;
    var cryptFlag = tds.PreLoginEnc.ENCRYPT_NOT_SUP;
    while (offset < size) {
      final token = data[offset];
      if (token == tds.PreLoginToken.TERMINATOR) {
        break;
      }
      if (offset + 5 > size) {
        _badStream('Estrutura PRELOGIN truncada');
      }
      final payloadOffset = byteView.getUint16(offset + 1, Endian.big);
      final payloadLength = byteView.getUint16(offset + 3, Endian.big);
      if (payloadOffset + payloadLength > size) {
        _badStream('Offset inválido em PRELOGIN');
      }
      switch (token) {
        case tds.PreLoginToken.VERSION:
          // ignorado por enquanto
          break;
        case tds.PreLoginToken.ENCRYPTION:
          cryptFlag = data[payloadOffset];
          break;
        default:
          break;
      }
      offset += 5;
    }
    login.serverEncFlag = cryptFlag;
    _enforceSyncEncryptionPolicy(login, cryptFlag);
    _trace('prelogin.response', {
      'crypt_flag': cryptFlag,
      'mars_requested': login.useMars,
    });
  }

  @override
  void sendLogin(tds.TdsLogin login) {
    final isTds72Plus = tds.isTds72Plus(this);
    final userName = login.userName;
    if (userName.length > 128) {
      throw ArgumentError('User name deve ter no máximo 128 caracteres');
    }
    _authentication = login.auth;
    Uint8List authPacket = Uint8List(0);
    if (_authentication != null) {
      authPacket = Uint8List.fromList(_authentication!.createPacket());
    }
    final headerBase = isTds72Plus ? 94 : 86;
    var currentPos = headerBase;
    final baseChars = login.clientHostName.length +
        login.appName.length +
        login.serverName.length +
        login.library.length +
        login.language.length +
        login.database.length +
        login.attachDbFile.length;
    final extraChars = isTds72Plus ? login.changePassword.length : 0;
    var packetSize = headerBase + 2 * (baseChars + extraChars);
    if (_authentication != null) {
      packetSize += authPacket.length;
    } else {
      packetSize += 2 * (userName.length + login.password.length);
    }
    final writer = _writer;
    writer.beginPacket(tds.PacketType.LOGIN);
    writer.putInt(packetSize);
    writer.putUInt(login.tdsVersion);
    writer.putInt(login.blocksize);
    writer.putUInt(_clientLibraryVersion);
    writer.putInt(login.pid);
    writer.putUInt(0); // connection id
    var optionFlag1 =
        tds.TDS_SET_LANG_ON | tds.TDS_USE_DB_NOTIFY | tds.TDS_INIT_DB_FATAL;
    if (!login.bulkCopy) {
      optionFlag1 |= tds.TDS_DUMPLOAD_OFF;
    }
    writer.putByte(optionFlag1);
    var optionFlag2 = login.optionFlag2;
    if (_authentication != null) {
      optionFlag2 |= tds.TDS_INTEGRATED_SECURITY_ON;
    }
    writer.putByte(optionFlag2);
    var typeFlags = 0;
    if (login.readonly) {
      typeFlags |= tds.TDS_FREADONLY_INTENT;
    }
    writer.putByte(typeFlags);
    writer.putByte(
        tds.isTds73Plus(this) ? tds.TDS_UNKNOWN_COLLATION_HANDLING : 0);
    final offsetMinutes = login.clientTz.timeZoneOffset.inMinutes;
    writer.putInt(offsetMinutes);
    writer.putInt(login.clientLcid);

    void writeOffsetLen(String value) {
      writer.putSmallInt(currentPos);
      writer.putSmallInt(value.length);
      currentPos += value.length * 2;
    }

    writeOffsetLen(login.clientHostName);
    if (_authentication != null) {
      writer.putSmallInt(0);
      writer.putSmallInt(0);
      writer.putSmallInt(0);
      writer.putSmallInt(0);
    } else {
      writeOffsetLen(userName);
      writeOffsetLen(login.password);
    }
    writeOffsetLen(login.appName);
    writeOffsetLen(login.serverName);
    writer.putSmallInt(0); // réserve
    writer.putSmallInt(0);
    writeOffsetLen(login.library);
    writeOffsetLen(login.language);
    writeOffsetLen(login.database);
    final clientIdBytes = ByteData(8)..setUint64(0, login.clientId, Endian.big);
    writer.write(clientIdBytes.buffer.asUint8List(2));
    writer.putSmallInt(currentPos);
    writer.putSmallInt(authPacket.length);
    currentPos += authPacket.length;
    writeOffsetLen(login.attachDbFile);
    if (isTds72Plus) {
      writeOffsetLen(login.changePassword);
      writer.putInt(0);
    }
    writer.writeUcs2(login.clientHostName);
    if (_authentication == null) {
      writer.writeUcs2(userName);
      writer.write(tds.tds7CryptPass(login.password));
    }
    writer.writeUcs2(login.appName);
    writer.writeUcs2(login.serverName);
    writer.writeUcs2(login.library);
    writer.writeUcs2(login.language);
    writer.writeUcs2(login.database);
    if (_authentication != null) {
      writer.write(authPacket);
    }
    writer.writeUcs2(login.attachDbFile);
    writer.writeUcs2(login.changePassword);
    _trace('login.send', {
      'user': userName,
      'database': login.database,
      'app': login.appName,
      'tds_version': '0x${login.tdsVersion.toRadixString(16)}',
      'packet_size': packetSize,
      'auth': _authentication != null,
    });
    writer.flush();
    _state = tds.TDS_PENDING;
  }

  @override
  ResponseMetadata beginResponse() {
    try {
      final meta = _reader.beginResponse();
      _state = tds.TDS_READING;
      return meta;
    } on tds.TimeoutError {
      _sendCancel();
      rethrow;
    }
  }

  @override
  bool processLoginTokens() {
    var succeed = false;
    while (true) {
      if (_reader.streamFinished()) {
        beginResponse();
      }
      final marker = _nextTokenId();
      if (marker == tds.TDS_LOGINACK_TOKEN) {
        succeed = true;
        _processLoginAck();
      } else if (_handleCommonToken(marker)) {
        if (marker == tds.TDS_DONE_TOKEN &&
            (_doneFlags & tds.TDS_DONE_MORE_RESULTS) == 0) {
          break;
        }
      } else {
        _skipToken(marker);
      }
      if (marker == tds.TDS_DONE_TOKEN &&
          (_doneFlags & tds.TDS_DONE_MORE_RESULTS) == 0) {
        break;
      }
    }
    return succeed;
  }

  void _processLoginAck() {
    var size = _reader.getSmallInt();
    _reader.getByte(); // interface id
    final version = _reader.getUIntBe();
    _tdsVersion = _serverToClientMapping[version] ?? version;
    if (!tds.isTds7Plus(this)) {
      _badStream('Versão TDS mínima suportada é 7.0');
    }
    _reader.getByte();
    size -= 10;
    final nameChars = math.max(0, size ~/ 2);
    _reader.readUcs2(nameChars);
    _reader.getUIntBe();
    if (_authentication != null) {
      _authentication!.close();
      _authentication = null;
    }
    _trace('login.ack', {
      'tds_version': '0x${_tdsVersion.toRadixString(16)}',
      'server_version': '0x${version.toRadixString(16)}',
    });
  }

  static const Map<int, int> _serverToClientMapping = {
    0x07000000: tds.TDS70,
    0x07010000: tds.TDS71,
    0x71000001: tds.TDS71rev1,
    tds.TDS72: tds.TDS72,
    tds.TDS73A: tds.TDS73A,
    tds.TDS73B: tds.TDS73B,
    tds.TDS74: tds.TDS74,
  };

  @override
  void raiseDbException() {
    if (_messages.isEmpty) {
      throw tds.Error(
        'Requisição falhou e o servidor não retornou detalhes.',
      );
    }
    while (_messages.isNotEmpty &&
        _messages.last['msgno'] == 3621 &&
        _messages.length > 1) {
      _messages.removeLast();
    }
    final msg = _messages.last;
    final errorMsg = _messages.map((m) => m['message']).join(' ');
    final ex = tds.createExceptionByMessage(msg, customErrorMsg: errorMsg);
    throw ex;
  }

  @override
  void submitPlainQuery(String sql) {
    if (_state != tds.TDS_IDLE) {
      throw tds.InterfaceError(
        'Já existe uma operação pendente na sessão atual.',
      );
    }
    _rowBuffer.clear();
    _messages.clear();
    _rowsAffected = tds.TDS_NO_COUNT;
    _lastQuery = sql;
    _writer.beginPacket(tds.PacketType.QUERY);
    if (tds.isTds72Plus(this)) {
      _startQuery();
    }
    _trace('query.submit', {
      'sql': sql,
      'length': sql.length,
    });
    _writer.writeUcs2(sql);
    _writer.flush();
    _state = tds.TDS_PENDING;
  }

  @override
  void processSimpleRequest() {
    beginResponse();
    _drainUntilDone();
  }

  void _drainUntilDone() {
    while (true) {
      final marker = _nextTokenId();
      if (_handleCommonToken(marker)) {
        if ((marker == tds.TDS_DONE_TOKEN ||
                marker == tds.TDS_DONEPROC_TOKEN ||
                marker == tds.TDS_DONEINPROC_TOKEN) &&
            (_doneFlags & tds.TDS_DONE_MORE_RESULTS) == 0) {
          return;
        }
        continue;
      }
      _skipToken(marker);
    }
  }

  bool _handleCommonToken(int marker) {
    switch (marker) {
      case tds.TDS_DONE_TOKEN:
      case tds.TDS_DONEPROC_TOKEN:
      case tds.TDS_DONEINPROC_TOKEN:
        _processDone(marker);
        return true;
      case tds.TDS_ENVCHANGE_TOKEN:
        _processEnvChange();
        return true;
      case tds.TDS_INFO_TOKEN:
      case tds.TDS_ERROR_TOKEN:
        _messages.add(_processMessage(marker));
        return true;
      case tds.TDS_RETURNSTATUS_TOKEN:
        _processReturnStatus();
        return true;
      case tds.TDS7_RESULT_TOKEN:
        _processResultToken();
        return true;
      case tds.TDS_ROW_TOKEN:
        _processRowToken();
        return true;
      case tds.TDS_NBC_ROW_TOKEN:
        _processNbcRowToken();
        return true;
      default:
        return false;
    }
  }

  void _processReturnStatus() {
    _returnStatus = _reader.getInt();
    _hasStatus = true;
    _trace('returnstatus', {'value': _returnStatus});
  }

  void _processDone(int marker) {
    final status = _reader.getUSmallInt();
    _reader.getUSmallInt(); // cur_cmd
    final hasMore = (status & tds.TDS_DONE_MORE_RESULTS) != 0;
    final wasCancelled = (status & tds.TDS_DONE_CANCELLED) != 0;
    final countValid = (status & tds.TDS_DONE_COUNT) != 0;
    final rows = tds.isTds72Plus(this) ? _reader.getInt8() : _reader.getInt();
    _doneFlags = status;
    _rowsAffected = countValid ? rows : tds.TDS_NO_COUNT;
    _moreRows = hasMore;
    _trace('done', {
      'marker': marker,
      'status': status,
      'rows': _rowsAffected,
      'more': hasMore,
      'cancelled': wasCancelled,
      'count_valid': countValid,
    });
    if ((status & tds.TDS_DONE_ERROR) != 0 && !wasCancelled && !_inCancel) {
      raiseDbException();
    }
    if (!hasMore && !_inCancel) {
      _state = tds.TDS_IDLE;
    }
  }

  tds.Message _processMessage(int marker) {
    final size = _reader.getSmallInt();
    final message = <String, dynamic>{
      'marker': marker,
      'msgno': _reader.getInt(),
      'state': _reader.getByte(),
      'severity': _reader.getByte(),
      'sql_state': null,
      'priv_msg_type': marker == tds.TDS_INFO_TOKEN ? 0 : 1,
      'message': '',
      'server': '',
      'proc_name': '',
      'line_number': 0,
    };
    final textLen = _reader.getSmallInt();
    message['message'] = _reader.readUcs2(textLen);
    final serverNameLen = _reader.getByte();
    message['server'] = _reader.readUcs2(serverNameLen);
    final procNameLen = _reader.getByte();
    message['proc_name'] = _reader.readUcs2(procNameLen);
    final hasLongLineNumber = tds.isTds72Plus(this);
    final lineByteCount = hasLongLineNumber ? 4 : 2;
    message['line_number'] =
        hasLongLineNumber ? _reader.getInt() : _reader.getSmallInt();
    final consumed = 4 +
        1 +
        1 +
        2 +
        textLen * 2 +
        1 +
        serverNameLen * 2 +
        1 +
        procNameLen * 2 +
        lineByteCount;
    final remaining = size - consumed;
    if (remaining > 0) {
      _reader.readBytes(remaining);
    }
    _trace('message', {
      'marker': marker,
      'msgno': message['msgno'],
      'severity': message['severity'],
      'state': message['state'],
      'line': message['line_number'],
      'text': message['message'],
    });
    return message;
  }

  void _processEnvChange() {
    final size = _reader.getSmallInt();
    final typeId = _reader.getByte();
    final traceData = <String, Object?>{'type': typeId};
    switch (typeId) {
      case tds.TDS_ENV_SQLCOLLATION:
        final payload = _reader.getByte();
        if (payload >= Collation.wire_size) {
          final bytes = _reader.readBytes(Collation.wire_size);
          _collation = Collation.unpack(bytes);
          _connectionCollation = _collation;
          _onCollationChanged?.call(_collation);
          traceData['new'] = _collation?.toString();
          final extra = payload - Collation.wire_size;
          if (extra > 0) {
            _reader.readBytes(extra);
          }
        } else {
          _reader.readBytes(payload);
        }
        final oldLen = _reader.getByte();
        if (oldLen > 0) {
          _reader.readBytes(oldLen);
        }
        break;
      case tds.TDS_ENV_PACKSIZE:
        final newVal = _reader.readUcs2(_reader.getByte());
        _reader.readUcs2(_reader.getByte());
        final block = int.tryParse(newVal);
        if (block != null && block >= 512) {
          _writer.bufsize = block;
        }
        traceData['new'] = block ?? newVal;
        break;
      case tds.TDS_ENV_CHARSET:
        final newCharset = _reader.readUcs2(_reader.getByte());
        _reader.readUcs2(_reader.getByte());
        _env.charset = newCharset;
        traceData['new'] = newCharset;
        break;
      case tds.TDS_ENV_DB_MIRRORING_PARTNER:
        final partner = _reader.readUcs2(_reader.getByte());
        _reader.readUcs2(_reader.getByte());
        _env.mirroringPartner = partner;
        traceData['new'] = partner;
        break;
      case tds.TDS_ENV_LCID:
        final lcidStr = _reader.readUcs2(_reader.getByte());
        final lcid = int.tryParse(lcidStr);
        if (lcid != null) {
          _env.charset = lcid2charset(lcid);
        }
        traceData['new'] = lcid ?? lcidStr;
        final oldLcidLen = _reader.getByte();
        if (oldLcidLen > 0) {
          _reader.readUcs2(oldLcidLen);
        }
        break;
      case tds.TDS_ENV_UNICODE_DATA_SORT_COMP_FLAGS:
        final newFlags = _reader.readUcs2(_reader.getByte());
        final oldFlagsLen = _reader.getByte();
        if (oldFlagsLen > 0) {
          _reader.readUcs2(oldFlagsLen);
        }
        _onUnicodeSortFlags?.call(newFlags);
        traceData['new'] = newFlags;
        break;
      case tds.TDS_ENV_BEGINTRANS:
        final newSize = _reader.getByte();
        int? txnValue;
        if (newSize == 8) {
          txnValue = _reader.getUInt8();
        } else if (newSize > 0) {
          txnValue = _decodeLittleEndianInt(_reader.readBytes(newSize));
        }
        final oldSize = _reader.getByte();
        if (oldSize > 0) {
          _reader.readBytes(oldSize);
        }
        if (txnValue != null) {
          _onTransactionStateChange?.call(txnValue);
          traceData['new'] = txnValue;
        }
        break;
      case tds.TDS_ENV_COMMITTRANS:
      case tds.TDS_ENV_ROLLBACKTRANS:
        final newTxSize = _reader.getByte();
        if (newTxSize > 0) {
          _reader.readBytes(newTxSize);
        }
        final oldTxSize = _reader.getByte();
        if (oldTxSize > 0) {
          _reader.readBytes(oldTxSize);
        }
        _onTransactionStateChange?.call(0);
        traceData['new'] = 0;
        break;
      case tds.TDS_ENV_DATABASE:
        final newDb = _reader.readUcs2(_reader.getByte());
        _reader.readUcs2(_reader.getByte());
        _env.database = newDb;
        traceData['new'] = newDb;
        break;
      case tds.TDS_ENV_LANG:
        final newLang = _reader.readUcs2(_reader.getByte());
        _reader.readUcs2(_reader.getByte());
        _env.language = newLang;
        traceData['new'] = newLang;
        break;
      case tds.TDS_ENV_ROUTING:
        _reader.getUSmallInt();
        final protocol = _reader.getByte();
        final protocolProperty = _reader.getUSmallInt();
        final serverLen = _reader.getUSmallInt();
        final serverName = serverLen > 0 ? _reader.readUcs2(serverLen) : '';
        final routeInfo = <String, dynamic>{
          'protocol': protocol,
          'port': protocolProperty,
          'server': serverName,
        };
        _onRouteChange?.call(routeInfo);
        traceData
          ..['protocol'] = protocol
          ..['port'] = protocolProperty
          ..['server'] = serverName;
        final oldValueLen = _reader.getUSmallInt();
        if (oldValueLen > 0) {
          _reader.readBytes(oldValueLen);
        }
        break;
      default:
        final toSkip = size - 1;
        if (toSkip > 0) {
          _reader.readBytes(toSkip);
        }
        traceData['unknown'] = true;
    }
    _trace('envchange', traceData);
  }

  void _skipToken(int marker) {
    switch (marker) {
      case tds.TDS5_PARAMFMT2_TOKEN:
      case tds.TDS_LANGUAGE_TOKEN:
      case tds.TDS_ORDERBY2_TOKEN:
        final len32 = _reader.getSmallInt();
        if (len32 > 0) {
          _reader.readBytes(len32);
        }
        break;
      case tds.TDS_TABNAME_TOKEN:
      case tds.TDS_COLINFO_TOKEN:
      case tds.TDS_CAPABILITY_TOKEN:
      case tds.TDS_ORDERBY_TOKEN:
        final len = _reader.getSmallInt();
        if (len > 0) {
          _reader.readBytes(len);
        }
        break;
      default:
        throw tds.InterfaceError(
          'Token TDS desconhecido: $marker (0x${marker.toRadixString(16)})',
        );
    }
  }

  // ignore: unused_element
  void _processResultToken() {
    final columnCount = _reader.getSmallInt();
    if (columnCount == -1) {
      return;
    }
    final results = tds.Results();
    results.columns = List.generate(columnCount, (_) => tds.Column());
    results.description = [];
    _results = results;
    _currentRow = List<dynamic>.filled(columnCount, null, growable: false);
    _rowsAffected = tds.TDS_NO_COUNT;
    _skippedToStatus = false;
    _hasStatus = false;
    _returnStatus = null;
    _moreRows = true;
    for (var i = 0; i < columnCount; i++) {
      _readColumnMetadata(results.columns[i], results.description);
    }
    final columnNames =
        results.columns.map((col) => col.columnName).toList(growable: false);
    _rebuildRowFactory(columnNames: columnNames);
  }

  void _processRowToken() {
    final metadata = _results;
    if (metadata == null) {
      _badStream('ROW recebido antes de COLMETADATA');
    }
    final safeInfo = metadata!;
    safeInfo.rowCount += 1;
    for (var i = 0; i < safeInfo.columns.length; i++) {
      _currentRow[i] = _readColumnValueSync(safeInfo.columns[i]);
    }
    _trace('row', {'values': List<dynamic>.from(_currentRow)});
    _bufferRowSnapshot();
  }

  void _processNbcRowToken() {
    final metadata = _results;
    if (metadata == null) {
      _badStream('NBCROW recebido antes de COLMETADATA');
    }
    final safeInfo = metadata!;
    final nullBitmap = _reader.readBytes((safeInfo.columns.length + 7) >> 3);
    safeInfo.rowCount += 1;
    for (var i = 0; i < safeInfo.columns.length; i++) {
      final isNull = (nullBitmap[i >> 3] & (1 << (i & 7))) != 0;
      if (isNull) {
        _currentRow[i] = null;
      } else {
        _currentRow[i] = _readColumnValueSync(safeInfo.columns[i]);
      }
    }
    _trace('nbcrow', {'values': List<dynamic>.from(_currentRow)});
    _bufferRowSnapshot();
  }

  /// Remove e devolve a próxima linha já materializada pelo [RowStrategy].
  dynamic takeRow() {
    if (_rowBuffer.isEmpty) {
      return null;
    }
    return _rowBuffer.removeFirst();
  }

  /// Devolve todas as linhas pendentes e limpa o buffer.
  List<dynamic> takeAllRows() {
    if (_rowBuffer.isEmpty) {
      return const <dynamic>[];
    }
    final rows = List<dynamic>.from(_rowBuffer, growable: false);
    _rowBuffer.clear();
    return rows;
  }

  /// Descarrega as linhas já lidas sem retorná-las.
  void clearRowBuffer() => _rowBuffer.clear();

  dynamic _readColumnValueSync(tds.Column column) {
    final typeInfo = column.serializer;
    if (typeInfo is! _TypeInfo) {
      throw tds.InterfaceError('Metadados de coluna ausentes para ${column.columnName}');
    }
    switch (typeInfo.typeId) {
      case tds.BITTYPE:
        return _reader.getByte() != 0;
      case tds.INT1TYPE:
        return _reader.getByte();
      case tds.INT2TYPE:
        return _reader.getSmallInt();
      case tds.INT4TYPE:
        return _reader.getInt();
      case tds.INT8TYPE:
        return _reader.getInt8();
      case tds.INTNTYPE:
        return _readIntnValueSync();
      case tds.FLT4TYPE:
        return _readFloat32ValueSync();
      case tds.FLT8TYPE:
        return _readFloat64ValueSync();
      case tds.FLTNTYPE:
        return _readFloatnValueSync();
      case tds.MONEYTYPE:
        return _readMoneyValueSync(8);
      case tds.MONEY4TYPE:
        return _readMoneyValueSync(4);
      case tds.MONEYNTYPE:
        return _readMoneynValueSync();
      case tds.DATETIMETYPE:
        return _readDateTimeValueSync();
      case tds.DATETIM4TYPE:
        return _readSmallDateTimeValueSync();
      case tds.DATETIMNTYPE:
        return _readDateTimenValueSync();
      case tds.DATENTYPE:
        return _readDateValueSync();
      case tds.TIMENTYPE:
        return _readTimeValueSync(typeInfo);
      case tds.DATETIME2NTYPE:
        return _readDateTime2ValueSync(typeInfo);
      case tds.DATETIMEOFFSETNTYPE:
        return _readDateTimeOffsetValueSync(typeInfo);
      case tds.DECIMALNTYPE:
      case tds.NUMERICNTYPE:
        return _readDecimalValueSync(typeInfo);
      case tds.GUIDTYPE:
        return _readGuidValueSync();
      case tds.BIGVARCHRTYPE:
      case tds.BIGCHARTYPE:
        return _readAnsiValueSync(lengthBytes: 2);
      case tds.SYBVARCHAR:
      case tds.SYBCHAR:
        return _readAnsiValueSync(lengthBytes: 1);
      case tds.NVARCHARTYPE:
      case tds.NCHARTYPE:
        return _readUnicodeValueSync(lengthBytes: 2);
      case tds.SYBNVARCHAR:
        return _readUnicodeValueSync(lengthBytes: 1);
      case tds.BIGVARBINTYPE:
      case tds.BIGBINARYTYPE:
        return _readBinaryValueSync(lengthBytes: 2);
      case tds.SYBVARBINARY:
      case tds.BINARYTYPE:
        return _readBinaryValueSync(lengthBytes: 1);
      case tds.TEXTTYPE:
        return _readTextValueSync(typeInfo, unicode: false);
      case tds.NTEXTTYPE:
        return _readTextValueSync(typeInfo, unicode: true);
      case tds.XMLTYPE:
        return _readXmlValueSync();
      default:
        throw tds.NotSupportedError(
          'Leitura de valores para o tipo ${typeInfo.typeId} ainda não foi portada',
        );
    }
  }

  dynamic _readIntnValueSync() {
    final length = _reader.getByte();
    if (length == 0) {
      return null;
    }
    switch (length) {
      case 1:
        return _reader.getByte();
      case 2:
        return _reader.getSmallInt();
      case 4:
        return _reader.getInt();
      case 8:
        return _reader.getInt8();
      default:
        throw tds.InterfaceError('Comprimento inválido para INTN: $length');
    }
  }

  dynamic _readAnsiValueSync({required int lengthBytes}) {
    final length = lengthBytes == 2 ? _reader.getUSmallInt() : _reader.getByte();
    if ((lengthBytes == 2 && length == 0xFFFF) ||
        (lengthBytes == 1 && length == 0xFF)) {
      return null;
    }
    final data = _reader.readBytes(length);
    return data;
  }

  dynamic _readBinaryValueSync({required int lengthBytes}) {
    final length = lengthBytes == 2 ? _reader.getUSmallInt() : _reader.getByte();
    if ((lengthBytes == 2 && length == 0xFFFF) ||
        (lengthBytes == 1 && length == 0xFF)) {
      return null;
    }
    return _reader.readBytes(length);
  }

  dynamic _readUnicodeValueSync({required int lengthBytes}) {
    if (lengthBytes == 1) {
      final charCount = _reader.getByte();
      if (charCount == 0xFF) {
        return null;
      }
      final data = _reader.readBytes(charCount * 2);
      return _bytesToUnicode ? ucs2Codec.decode(data) : data;
    }
    final byteLength = _reader.getUSmallInt();
    if (byteLength == 0xFFFF) {
      return null;
    }
    final data = _reader.readBytes(byteLength);
    return _bytesToUnicode ? ucs2Codec.decode(data) : data;
  }

  void _bufferRowSnapshot() {
    final hasResults = _results != null && _currentRow.isNotEmpty;
    if (!hasResults) {
      return;
    }
    final snapshot = List<dynamic>.from(_currentRow, growable: false);
    final materialized = _rowConvertor(snapshot);
    _rowBuffer.add(materialized);
  }

  double _readFloat32ValueSync() {
    final bytes = _reader.readBytes(4);
    return ByteData.sublistView(bytes).getFloat32(0, Endian.little);
  }

  double _readFloat64ValueSync() {
    final bytes = _reader.readBytes(8);
    return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
  }

  double? _readFloatnValueSync() {
    final length = _reader.getByte();
    if (length == 0) {
      return null;
    }
    switch (length) {
      case 4:
        return _readFloat32ValueSync();
      case 8:
        return _readFloat64ValueSync();
      default:
        throw tds.InterfaceError('Comprimento inválido para FLOATN: $length');
    }
  }

  double _readMoneyValueSync(int length) {
    if (length == 4) {
      return _reader.getInt() / 10000.0;
    }
    if (length == 8) {
      return _reader.getInt8() / 10000.0;
    }
    throw tds.InterfaceError('Comprimento inválido para MONEY: $length');
  }

  double? _readMoneynValueSync() {
    final length = _reader.getByte();
    if (length == 0) {
      return null;
    }
    return _readMoneyValueSync(length);
  }

  DateTime _readDateTimeValueSync() {
    final days = _reader.getInt();
    final ticks = _reader.getUInt();
    final base = _baseDate1900.add(Duration(days: days));
    final micros = (ticks * 1000000) ~/ 300;
    return base.add(Duration(microseconds: micros));
  }

  DateTime _readSmallDateTimeValueSync() {
    final days = _reader.getUSmallInt();
    final minutes = _reader.getUSmallInt();
    return _baseDate1900.add(
      Duration(days: days, minutes: minutes),
    );
  }

  DateTime? _readDateTimenValueSync() {
    final length = _reader.getByte();
    if (length == 0) {
      return null;
    }
    if (length == 4) {
      return _readSmallDateTimeValueSync();
    }
    if (length == 8) {
      return _readDateTimeValueSync();
    }
    throw tds.InterfaceError('Comprimento inválido para DATETIMN: $length');
  }

  DateTime? _readDateValueSync() {
    final length = _reader.getByte();
    if (length == 0) {
      return null;
    }
    if (length != 3) {
      throw tds.InterfaceError('Comprimento inválido para DATE: $length');
    }
    final days = _decodeLittleEndianInt(_reader.readBytes(3));
    return _baseDate0001.add(Duration(days: days));
  }

  Duration? _readTimeValueSync(_TypeInfo typeInfo) {
    final length = _reader.getByte();
    if (length == 0) {
      return null;
    }
    final precision = typeInfo.precision ?? 7;
    return _readTimeDurationFromBytes(length, precision);
  }

  DateTime? _readDateTime2ValueSync(_TypeInfo typeInfo) {
    final size = _reader.getByte();
    if (size == 0) {
      return null;
    }
    if (size < 3) {
      throw tds.InterfaceError('Comprimento inválido para DATETIME2: $size');
    }
    final precision = typeInfo.precision ?? 7;
    final timeSize = size - 3;
    final time = _readTimeDurationFromBytes(timeSize, precision);
    final days = _decodeLittleEndianInt(_reader.readBytes(3));
    return _baseDate0001.add(Duration(days: days)).add(time);
  }

  DateTimeOffsetValue? _readDateTimeOffsetValueSync(_TypeInfo typeInfo) {
    final size = _reader.getByte();
    if (size == 0) {
      return null;
    }
    if (size < 5) {
      throw tds.InterfaceError(
        'Comprimento inválido para DATETIMEOFFSET: $size',
      );
    }
    final precision = typeInfo.precision ?? 7;
    final timeSize = size - 5;
    final time = _readTimeDurationFromBytes(timeSize, precision);
    final days = _decodeLittleEndianInt(_reader.readBytes(3));
    final offsetMinutes = _reader.getSmallInt();
    final utcDate = _baseDate0001.add(Duration(days: days)).add(time);
    final utcValue = DateTime.fromMicrosecondsSinceEpoch(
      utcDate.microsecondsSinceEpoch,
      isUtc: true,
    );
    return DateTimeOffsetValue(utc: utcValue, offsetMinutes: offsetMinutes);
  }

  DecimalValue? _readDecimalValueSync(_TypeInfo typeInfo) {
    final size = _reader.getByte();
    if (size == 0) {
      return null;
    }
    if (size < 1) {
      throw tds.InterfaceError('Comprimento inválido para DECIMAL: $size');
    }
    final isPositive = _reader.getByte() == 1;
    final magnitude = _decodeLittleEndianBigInt(_reader.readBytes(size - 1));
    final raw = isPositive ? magnitude : -magnitude;
    return DecimalValue(unscaledValue: raw, scale: typeInfo.scale ?? 0);
  }

  String? _readGuidValueSync() {
    final size = _reader.getByte();
    if (size == 0) {
      return null;
    }
    if (size != 16) {
      throw tds.InterfaceError('GUID inválido com $size bytes');
    }
    return _formatGuid(_reader.readBytes(16));
  }

  dynamic _readTextValueSync(_TypeInfo typeInfo, {required bool unicode}) {
    final textPtrSize = _reader.getByte();
    if (textPtrSize == 0) {
      return null;
    }
    if (textPtrSize > 0) {
      _reader.readBytes(textPtrSize);
    }
    _reader.readBytes(8); // timestamp
    final length = _reader.getInt();
    if (length <= 0) {
      return unicode && _bytesToUnicode ? '' : Uint8List(0);
    }
    final data = _reader.readBytes(length);
    if (!unicode) {
      return _bytesToUnicode
          ? _decodeWithCollation(data, typeInfo.collation)
          : data;
    }
    if (!_bytesToUnicode) {
      return data;
    }
    return ucs2Codec.decode(data);
  }

  dynamic _readXmlValueSync() {
    final payload = _readPlpBytesSync();
    if (payload == null) {
      return null;
    }
    if (_bytesToUnicode) {
      return ucs2Codec.decode(payload);
    }
    return payload;
  }

  Duration _readTimeDurationFromBytes(int size, int precision) {
    final data = _reader.readBytes(size);
    var ticks = _decodeLittleEndianInt(data);
    final scaleDiff = (7 - precision).clamp(0, 7);
    for (var i = 0; i < scaleDiff; i++) {
      ticks *= 10;
    }
    final nanoseconds = ticks * 100;
    return Duration(microseconds: nanoseconds ~/ 1000);
  }

  Uint8List? _readPlpBytesSync() {
    final declaredLength = _reader.getUInt8();
    if (declaredLength == tds.PLP_NULL) {
      return null;
    }
    final builder = BytesBuilder(copy: false);
    var remaining = declaredLength;
    while (true) {
      final chunkLength = _reader.getUInt();
      if (chunkLength == 0) {
        break;
      }
      builder.add(_reader.readBytes(chunkLength));
      if (remaining != tds.PLP_UNKNOWN) {
        remaining -= chunkLength;
      }
    }
    return builder.takeBytes();
  }

  String _formatGuid(List<int> bytes) {
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final part1 = data.getUint32(0, Endian.little).toRadixString(16).padLeft(8, '0');
    final part2 = data.getUint16(4, Endian.little).toRadixString(16).padLeft(4, '0');
    final part3 = data.getUint16(6, Endian.little).toRadixString(16).padLeft(4, '0');
    final part4 = _formatBytes(bytes.sublist(8, 10));
    final part5 = _formatBytes(bytes.sublist(10));
    return '$part1-$part2-$part3-$part4-$part5';
  }

  String _formatBytes(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  dynamic _decodeWithCollation(List<int> data, Collation? collation) {
    if (!_bytesToUnicode) {
      return Uint8List.fromList(data);
    }
    final codec = collation?.get_codec() ??
        _connectionCollation?.get_codec() ??
        latin1;
    return codec.decode(data);
  }

  BigInt _decodeLittleEndianBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i] & 0xFF);
    }
    return result;
  }

  void _readColumnMetadata(
    tds.Column column,
    List<List<dynamic>> description,
  ) {
    column.columnUserType =
        tds.isTds72Plus(this) ? _reader.getUInt() : _reader.getUSmallInt();
    column.flags = _reader.getUSmallInt();
    final typeId = _reader.getByte();
    final typeInfo = _readTypeInfoPayload(typeId);
    column.serializer = typeInfo;
    column.type = typeId;
    final nameLength = _reader.getByte();
    column.columnName = nameLength > 0 ? _reader.readUcs2(nameLength) : '';
    final nullable = (column.flags & tds.Column.fNullable) != 0;
    description.add([
      column.columnName,
      typeId,
      null,
      typeInfo.maxLength,
      typeInfo.precision,
      typeInfo.scale,
      nullable,
    ]);
  }

  _TypeInfo _readTypeInfoPayload(int typeId) {
    switch (typeId) {
      case tds.BITTYPE:
        return const _TypeInfo(typeId: tds.BITTYPE, maxLength: 1);
      case tds.INT1TYPE:
        return const _TypeInfo(typeId: tds.INT1TYPE, maxLength: 1);
      case tds.INT2TYPE:
        return const _TypeInfo(typeId: tds.INT2TYPE, maxLength: 2);
      case tds.INT4TYPE:
        return const _TypeInfo(typeId: tds.INT4TYPE, maxLength: 4);
      case tds.INT8TYPE:
        return const _TypeInfo(typeId: tds.INT8TYPE, maxLength: 8);
      case tds.FLT4TYPE:
        return const _TypeInfo(typeId: tds.FLT4TYPE, maxLength: 4);
      case tds.FLT8TYPE:
        return const _TypeInfo(typeId: tds.FLT8TYPE, maxLength: 8);
      case tds.MONEYTYPE:
        return const _TypeInfo(typeId: tds.MONEYTYPE, maxLength: 8);
      case tds.MONEY4TYPE:
        return const _TypeInfo(typeId: tds.MONEY4TYPE, maxLength: 4);
      case tds.DATETIMETYPE:
        return const _TypeInfo(typeId: tds.DATETIMETYPE, maxLength: 8);
      case tds.DATETIM4TYPE:
        return const _TypeInfo(typeId: tds.DATETIM4TYPE, maxLength: 4);
      case tds.GUIDTYPE:
        return const _TypeInfo(typeId: tds.GUIDTYPE, maxLength: 16);
      case tds.DATENTYPE:
        return const _TypeInfo(typeId: tds.DATENTYPE, maxLength: 3);
      case tds.INTNTYPE:
      case tds.BITNTYPE:
      case tds.MONEYNTYPE:
      case tds.DATETIMNTYPE:
      case tds.FLTNTYPE:
        final length = _reader.getByte();
        return _TypeInfo(typeId: typeId, maxLength: length);
      case tds.DECIMALNTYPE:
      case tds.NUMERICNTYPE:
        final storage = _reader.getByte();
        final precision = _reader.getByte();
        final scale = _reader.getByte();
        return _TypeInfo(
          typeId: typeId,
          maxLength: storage,
          precision: precision,
          scale: scale,
        );
      case tds.BIGVARBINTYPE:
      case tds.BIGBINARYTYPE:
        final length = _reader.getUSmallInt();
        return _TypeInfo(typeId: typeId, maxLength: length);
      case tds.SYBVARBINARY:
      case tds.BINARYTYPE:
        final byteLen = _reader.getByte();
        return _TypeInfo(typeId: typeId, maxLength: byteLen);
      case tds.BIGVARCHRTYPE:
      case tds.BIGCHARTYPE:
        final length = _reader.getUSmallInt();
        final collation = _reader.getCollation();
        return _TypeInfo(
          typeId: typeId,
          maxLength: length,
          collation: collation,
        );
      case tds.SYBVARCHAR:
      case tds.SYBCHAR:
        final lenByte = _reader.getByte();
        final collation = _reader.getCollation();
        return _TypeInfo(
          typeId: typeId,
          maxLength: lenByte,
          collation: collation,
        );
      case tds.NVARCHARTYPE:
      case tds.NCHARTYPE:
        final length = _reader.getUSmallInt();
        final collation = _reader.getCollation();
        return _TypeInfo(
          typeId: typeId,
          maxLength: length,
          collation: collation,
        );
      case tds.TEXTTYPE:
      case tds.NTEXTTYPE:
        final size = _reader.getInt();
        final collation = _reader.getCollation();
        final parts = _readMultipartIdentifier();
        return _TypeInfo(
          typeId: typeId,
          maxLength: size,
          collation: collation,
          schema: parts,
        );
      case tds.XMLTYPE:
        final hasSchema = _reader.getByte();
        if (hasSchema == 0) {
          return const _TypeInfo(typeId: tds.XMLTYPE);
        }
        final dbName = _reader.readUcs2(_reader.getByte());
        final owner = _reader.readUcs2(_reader.getByte());
        final collection = _reader.readUcs2(_reader.getSmallInt());
        return _TypeInfo(
          typeId: typeId,
          schema: [dbName, owner, collection],
        );
      case tds.UDTTYPE:
        final maxByteSize = _reader.getUSmallInt();
        final dbName = _reader.readUcs2(_reader.getByte());
        final schemaName = _reader.readUcs2(_reader.getByte());
        final typeName = _reader.readUcs2(_reader.getByte());
        final asmName = _reader.readUcs2(_reader.getSmallInt());
        return _TypeInfo(
          typeId: typeId,
          maxLength: maxByteSize,
          schema: [dbName, schemaName, typeName, asmName],
        );
      case tds.TIMENTYPE:
      case tds.DATETIME2NTYPE:
      case tds.DATETIMEOFFSETNTYPE:
        final precision = _reader.getByte();
        return _TypeInfo(typeId: typeId, precision: precision);
      default:
        throw tds.NotSupportedError(
          'TYPE_INFO para o tipo $typeId ainda não foi portado',
        );
    }
  }

  List<String> _readMultipartIdentifier() {
    if (!tds.isTds72Plus(this)) {
      final len = _reader.getSmallInt();
      if (len <= 0) {
        return const <String>[];
      }
      return <String>[_reader.readUcs2(len)];
    }
    final parts = <String>[];
    final count = _reader.getByte();
    for (var i = 0; i < count; i++) {
      final len = _reader.getSmallInt();
      parts.add(len > 0 ? _reader.readUcs2(len) : '');
    }
    return parts;
  }

  @override
  void updateTypeSystem(
    SerializerFactory factory, {
    Collation? collation,
    bool? bytesToUnicode,
  }) {
    _typeFactory = factory;
    if (collation != null) {
      _connectionCollation = collation;
      _collation ??= collation;
    }
    if (bytesToUnicode != null) {
      _bytesToUnicode = bytesToUnicode;
    }
  }

  @override
  void updateRowStrategy(RowStrategy strategy) {
    _setRowStrategy(strategy);
  }

  void _startQuery() {
    final data = ByteData(22)
      ..setUint32(0, 0x16, Endian.little)
      ..setUint32(4, 0x12, Endian.little)
      ..setUint16(8, 2, Endian.little)
      ..setUint64(10, 0, Endian.little)
      ..setUint32(18, 1, Endian.little);
    _writer.write(data.buffer.asUint8List());
    _trace('query.start', {'tran': _env.isolationLevel});
  }

  int _decodeLittleEndianInt(List<int> bytes) {
    var result = 0;
    for (var i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | (bytes[i] & 0xFF);
    }
    return result;
  }

  void _setRowStrategy(RowStrategy strategy, [List<String>? columnNames]) {
    _rowStrategy = strategy;
    _rebuildRowFactory(columnNames: columnNames);
  }

  void _rebuildRowFactory({List<String>? columnNames}) {
    final names = columnNames ??
        (_results?.columns.map((c) => c.columnName).toList() ??
            const <String>[]);
    _rowConvertor = _rowStrategy(names);
    _rowConvertor(const <dynamic>[]);
  }

  int _nextTokenId() {
    _state = tds.TDS_READING;
    try {
      final marker = _reader.getByte();
      _trace('token', {
        'marker': marker,
        'name': _tokenNames[marker] ?? '0x${marker.toRadixString(16)}',
      });
      return marker;
    } on tds.TimeoutError {
      _state = tds.TDS_PENDING;
      rethrow;
    }
  }

  void _sendCancel() {
    if (_inCancel) {
      return;
    }
    _writer.beginPacket(tds.PacketType.CANCEL);
    _writer.flush();
    _inCancel = true;
  }

  void _badStream(String message) {
    close();
    throw tds.InterfaceError(message);
  }

  void close() => _transport.close();

  @override
  tds.AuthProtocol? get authentication => _authentication;

  @override
  set authentication(tds.AuthProtocol? value) {
    _authentication = value;
  }

  @override
  int get state => _state;

  @override
  set state(int value) {
    _state = value;
  }

  @override
  int get tdsVersion => _tdsVersion;

  set tdsVersion(int value) {
    _tdsVersion = value;
  }
}

class _TypeInfo {
  final int typeId;
  final int? maxLength;
  final int? precision;
  final int? scale;
  final Collation? collation;
  final List<String>? schema;

  const _TypeInfo({
    required this.typeId,
    this.maxLength,
    this.precision,
    this.scale,
    this.collation,
    this.schema,
  });
}

const Map<int, String> _tokenNames = {
  tds.TDS_DONE_TOKEN: 'DONE',
  tds.TDS_DONEPROC_TOKEN: 'DONEPROC',
  tds.TDS_DONEINPROC_TOKEN: 'DONEINPROC',
  tds.TDS_ENVCHANGE_TOKEN: 'ENVCHANGE',
  tds.TDS_ERROR_TOKEN: 'ERROR',
  tds.TDS_INFO_TOKEN: 'INFO',
  tds.TDS_RETURNSTATUS_TOKEN: 'RETURNSTATUS',
  tds.TDS_ROW_TOKEN: 'ROW',
  tds.TDS_NBC_ROW_TOKEN: 'NBCROW',
  tds.TDS_ORDERBY_TOKEN: 'ORDERBY',
  tds.TDS_PARAM_TOKEN: 'RETURNVALUE',
  tds.TDS_TABNAME_TOKEN: 'TABNAME',
  tds.TDS_COLINFO_TOKEN: 'COLINFO',
  tds.TDS_AUTH_TOKEN: 'AUTH',
  tds.TDS_CAPABILITY_TOKEN: 'CAPABILITY',
  tds.TDS7_RESULT_TOKEN: 'COLMETADATA',
};
