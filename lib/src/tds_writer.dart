import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'collate.dart';
import 'tds_base.dart' as tds;

const _tdsHeaderSize = 8;

/// Escritor de fluxos TDS inspirado em `pytds.tds_writer`.
class TdsWriter {
  TdsWriter({
    required tds.TransportProtocol transport,
    required this.session,
    int bufsize = 4096,
  })  : _transport = transport,
        _buf = Uint8List(bufsize),
        _pos = _tdsHeaderSize;

  final tds.TransportProtocol _transport;
  final tds.TdsSessionContract session;

  Uint8List _buf;
  int _pos;
  int _packetNo = 0;
  int _packetType = tds.PacketType.QUERY;
  final Uint8List _scratch = Uint8List(8);

  tds.TransportProtocol get transport => _transport;

  int get bufsize => _buf.length;
  set bufsize(int size) {
    if (size == _buf.length || size < _tdsHeaderSize) {
      return;
    }
    final newBuf = Uint8List(size);
    final toCopy = math.min(size, _pos);
    newBuf.setRange(0, toCopy, _buf);
    _buf = newBuf;
    if (_pos > _buf.length) {
      _pos = _buf.length;
    }
  }

  int get lastPacketType => _packetType;
  List<int> get pendingPayload =>
      Uint8List.sublistView(_buf, _tdsHeaderSize, _pos).toList();

  void beginPacket(int packetType) {
    _packetType = packetType;
    _pos = _tdsHeaderSize;
  }

  void write(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var offset = 0;
    while (offset < bytes.length) {
      final left = _buf.length - _pos;
      if (left <= 0) {
        _writePacket(finalPacket: false);
        continue;
      }
      final toWrite = math.min(left, bytes.length - offset);
      _buf.setRange(_pos, _pos + toWrite, bytes, offset);
      _pos += toWrite;
      offset += toWrite;
    }
  }

  void writeBVarchar(String value) {
    putByte(value.length);
    writeUcs2(value);
  }

  void writeUcs2(String value) {
    writeString(value, ucs2Codec);
  }

  void writeString(String value, Encoding codec) {
    if (value.isEmpty) {
      return;
    }
    for (var i = 0; i < value.length; i += bufsize) {
      final chunk = value.substring(i, math.min(value.length, i + bufsize));
      write(codec.encode(chunk));
    }
  }

  void putByte(int value) {
    _scratch[0] = value & 0xFF;
    write(Uint8List.sublistView(_scratch, 0, 1));
  }

  void putSmallInt(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setInt16(0, value, Endian.little);
    write(Uint8List.sublistView(_scratch, 0, 2));
  }

  void putUSmallInt(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setUint16(0, value, Endian.little);
    write(Uint8List.sublistView(_scratch, 0, 2));
  }

  void putUSmallIntBe(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setUint16(0, value, Endian.big);
    write(Uint8List.sublistView(_scratch, 0, 2));
  }

  void putInt(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setInt32(0, value, Endian.little);
    write(Uint8List.sublistView(_scratch, 0, 4));
  }

  void putUInt(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setUint32(0, value, Endian.little);
    write(Uint8List.sublistView(_scratch, 0, 4));
  }

  void putUIntBe(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setUint32(0, value, Endian.big);
    write(Uint8List.sublistView(_scratch, 0, 4));
  }

  void putInt8(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setInt64(0, value, Endian.little);
    write(Uint8List.sublistView(_scratch, 0, 8));
  }

  void putUInt8(int value) {
    final data = ByteData.sublistView(_scratch);
    data.setUint64(0, value, Endian.little);
    write(Uint8List.sublistView(_scratch, 0, 8));
  }

  void putCollation(Collation collation) {
    write(collation.pack());
  }

  void flush() {
    _writePacket(finalPacket: true);
  }

  void _writePacket({required bool finalPacket}) {
    final header = ByteData(_tdsHeaderSize);
    header.setUint8(0, _packetType);
    header.setUint8(1, finalPacket ? 1 : 0);
    header.setUint16(2, _pos, Endian.big);
    header.setUint16(4, 0, Endian.big);
    header.setUint8(6, _packetNo);
    header.setUint8(7, 0);
    _packetNo = (_packetNo + 1) & 0xFF;
    _buf.setRange(0, _tdsHeaderSize, header.buffer.asUint8List());
    _transport.sendall(Uint8List.sublistView(_buf, 0, _pos));
    _pos = _tdsHeaderSize;
  }
}

/// Versão assíncrona do escritor de pacotes TDS.
class AsyncTdsWriter {
  AsyncTdsWriter({
    required tds.AsyncTransportProtocol transport,
    required this.session,
    int bufsize = 4096,
  })  : _transport = transport,
        _buf = Uint8List(bufsize),
        _pos = _tdsHeaderSize;

  tds.AsyncTransportProtocol _transport;
  final tds.TdsSessionContract session;

  Uint8List _buf;
  int _pos;
  int _packetNo = 0;
  int _packetType = tds.PacketType.QUERY;
  final Uint8List _scratch = Uint8List(8);

  /// Obtém o transporte atual.
  tds.AsyncTransportProtocol get transport => _transport;
  
  /// Define um novo transporte (usado para TLS upgrade).
  void setTransport(tds.AsyncTransportProtocol value) {
    _transport = value;
  }

  int get bufsize => _buf.length;
  set bufsize(int size) {
    if (size == _buf.length || size < _tdsHeaderSize) {
      return;
    }
    final newBuf = Uint8List(size);
    final toCopy = math.min(size, _pos);
    newBuf.setRange(0, toCopy, _buf);
    _buf = newBuf;
    if (_pos > _buf.length) {
      _pos = _buf.length;
    }
  }

  int get lastPacketType => _packetType;
  List<int> get pendingPayload =>
      Uint8List.sublistView(_buf, _tdsHeaderSize, _pos).toList();

  void beginPacket(int packetType) {
    _packetType = packetType;
    _pos = _tdsHeaderSize;
  }

  Future<void> write(List<int> data) async {
    if (data.isEmpty) {
      return;
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var offset = 0;
    while (offset < bytes.length) {
      final left = _buf.length - _pos;
      if (left <= 0) {
        await _writePacket(finalPacket: false);
        continue;
      }
      final toWrite = math.min(left, bytes.length - offset);
      _buf.setRange(_pos, _pos + toWrite, bytes, offset);
      _pos += toWrite;
      offset += toWrite;
    }
  }

  Future<void> writeBVarchar(String value) async {
    await putByte(value.length);
    await writeUcs2(value);
  }

  Future<void> writeUcs2(String value) async {
    await writeString(value, ucs2Codec);
  }

  Future<void> writeString(String value, Encoding codec) async {
    if (value.isEmpty) {
      return;
    }
    for (var i = 0; i < value.length; i += bufsize) {
      final chunk = value.substring(i, math.min(value.length, i + bufsize));
      await write(codec.encode(chunk));
    }
  }

  Future<void> putByte(int value) async {
    _scratch[0] = value & 0xFF;
    await write(Uint8List.sublistView(_scratch, 0, 1));
  }

  Future<void> putSmallInt(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setInt16(0, value, Endian.little);
    await write(Uint8List.sublistView(_scratch, 0, 2));
  }

  Future<void> putUSmallInt(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setUint16(0, value, Endian.little);
    await write(Uint8List.sublistView(_scratch, 0, 2));
  }

  Future<void> putUSmallIntBe(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setUint16(0, value, Endian.big);
    await write(Uint8List.sublistView(_scratch, 0, 2));
  }

  Future<void> putInt(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setInt32(0, value, Endian.little);
    await write(Uint8List.sublistView(_scratch, 0, 4));
  }

  Future<void> putUInt(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setUint32(0, value, Endian.little);
    await write(Uint8List.sublistView(_scratch, 0, 4));
  }

  Future<void> putUIntBe(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setUint32(0, value, Endian.big);
    await write(Uint8List.sublistView(_scratch, 0, 4));
  }

  Future<void> putInt8(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setInt64(0, value, Endian.little);
    await write(Uint8List.sublistView(_scratch, 0, 8));
  }

  Future<void> putUInt8(int value) async {
    final data = ByteData.sublistView(_scratch);
    data.setUint64(0, value, Endian.little);
    await write(Uint8List.sublistView(_scratch, 0, 8));
  }

  Future<void> putCollation(Collation collation) async {
    await write(collation.pack());
  }

  Future<void> flush() => _writePacket(finalPacket: true);

  Future<void> _writePacket({required bool finalPacket}) async {
    final header = ByteData(_tdsHeaderSize);
    header.setUint8(0, _packetType);
    header.setUint8(1, finalPacket ? 1 : 0);
    header.setUint16(2, _pos, Endian.big);
    header.setUint16(4, 0, Endian.big);
    header.setUint8(6, _packetNo);
    header.setUint8(7, 0);
    _packetNo = (_packetNo + 1) & 0xFF;
    _buf.setRange(0, _tdsHeaderSize, header.buffer.asUint8List());
    await _transport.sendAll(Uint8List.sublistView(_buf, 0, _pos));
    _pos = _tdsHeaderSize;
  }
}
