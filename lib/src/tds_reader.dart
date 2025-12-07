import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'collate.dart';
import 'tds_base.dart' as tds;

const _tdsHeaderSize = 8;

/// Representa metadados mínimos de um pacote de resposta TDS.
class ResponseMetadata {
  final int type;
  final int spid;
  const ResponseMetadata({required this.type, required this.spid});
}

/// Estrutura auxiliar para retornar um pedaço do buffer interno sem cópia.
class ReadBuffer {
  final Uint8List buffer;
  final int offset;
  final int length;
  const ReadBuffer(this.buffer, this.offset, this.length);

  ByteData asByteData() => ByteData.sublistView(buffer, offset, offset + length);
}

/// Implementação do leitor de pacotes TDS (porta direta do pytds).
class TdsReader implements tds.TransportProtocol {
  TdsReader({
    required tds.TransportProtocol transport,
    required this.session,
    int bufsize = 4096,
  })  : _transport = transport,
        _buf = Uint8List(bufsize),
        _pos = bufsize,
        _size = bufsize,
        _status = 1;

  final tds.TransportProtocol _transport;
  final tds.TdsSessionContract session;

  Uint8List _buf;
  int _pos;
  int _size;
  int _status;
  int? _type;
  int _spid = 0;

  int get bufsize => _buf.length;
  int get blockSize => _buf.length;

  void setBlockSize(int size) {
    if (size <= 0 || size == _buf.length) {
      return;
    }
    final newBuf = Uint8List(size);
    final copyLen = math.min(size, _buf.length);
    newBuf.setRange(0, copyLen, _buf);
    _buf = newBuf;
    if (_pos > size) {
      _pos = size;
    }
    if (_size > size) {
      _size = size;
    }
  }

  bool streamFinished() {
    if (_pos >= _size) {
      return _status == 1;
    }
    return false;
  }

  ResponseMetadata beginResponse() {
    if (_status != 1 && _pos < _size) {
      throw StateError(
        'beginResponse chamado antes de consumir o pacote anterior',
      );
    }
    _readPacket();
    return ResponseMetadata(type: _type ?? 0, spid: _spid);
  }

  int? get packetType => _type;
  int get status => _status;
  int get spid => _spid;

  ReadBuffer readFast(int size) => _readExact(size);

  Uint8List readBytes(int size) {
    final slice = _readExact(size);
    if (slice.offset == 0 && slice.length == slice.buffer.length) {
      return slice.buffer;
    }
    return Uint8List.sublistView(
      slice.buffer,
      slice.offset,
      slice.offset + slice.length,
    );
  }

  int getByte() {
    final slice = _readExact(1);
    return slice.buffer[slice.offset];
  }

  int getSmallInt() {
    final slice = _readExact(2);
    return slice.asByteData().getInt16(0, Endian.little);
  }

  int getUSmallInt() {
    final slice = _readExact(2);
    return slice.asByteData().getUint16(0, Endian.little);
  }

  int getInt() {
    final slice = _readExact(4);
    return slice.asByteData().getInt32(0, Endian.little);
  }

  int getUInt() {
    final slice = _readExact(4);
    return slice.asByteData().getUint32(0, Endian.little);
  }

  int getUIntBe() {
    final slice = _readExact(4);
    return slice.asByteData().getUint32(0, Endian.big);
  }

  int getUInt8() {
    final slice = _readExact(8);
    return slice.asByteData().getUint64(0, Endian.little);
  }

  int getInt8() {
    final slice = _readExact(8);
    return slice.asByteData().getInt64(0, Endian.little);
  }

  String readUcs2(int charCount) {
    final bytes = readBytes(charCount * 2);
    return ucs2Codec.decode(bytes);
  }

  String readStr(int size, Encoding codec) {
    final bytes = readBytes(size);
    return codec.decode(bytes);
  }

  Collation getCollation() {
    final payload = readBytes(Collation.wire_size);
    return Collation.unpack(payload);
  }

  List<int> readWholePacket() {
    final payloadSize = _size - _tdsHeaderSize;
    if (payloadSize <= 0) {
      return const <int>[];
    }
    _pos = _tdsHeaderSize;
    return readBytes(payloadSize);
  }

  @override
  bool isConnected() => _transport.isConnected();

  @override
  void close() => _transport.close();

  @override
  double? get timeout => _transport.timeout;

  @override
  set timeout(double? value) => _transport.timeout = value;

  @override
  void sendall(List<int> buf, {int flags = 0}) {
    throw UnsupportedError('TdsReader é somente leitura');
  }

  @override
  List<int> recv(int size) {
    if (size <= 0) {
      return const <int>[];
    }
    if (_pos >= _size) {
      if (_status == 1) {
        return const <int>[];
      }
      _readPacket();
    }
    final available = _size - _pos;
    final toRead = math.min(size, available);
    final result = Uint8List.sublistView(_buf, _pos, _pos + toRead);
    _pos += toRead;
    return result;
  }

  @override
  int recvInto(ByteBuffer buf, {int size = 0, int flags = 0}) {
    final target = buf.asUint8List();
    final toFill = size == 0 ? target.length : math.min(size, target.length);
    if (toFill == 0) {
      return 0;
    }
    final chunk = recv(toFill);
    target.setRange(0, chunk.length, chunk);
    return chunk.length;
  }

  void _readPacket() {
    final headerBytes = tds.readall(_transport, _tdsHeaderSize);
    _ensureCapacity(_tdsHeaderSize);
    _buf.setRange(0, _tdsHeaderSize, headerBytes);
    final headerView = ByteData.sublistView(_buf, 0, _tdsHeaderSize);
    _type = headerView.getUint8(0);
    _status = headerView.getUint8(1);
    _size = headerView.getUint16(2, Endian.big);
    _spid = headerView.getUint16(4, Endian.big);
    final payloadLength = math.max(0, _size - _tdsHeaderSize);
    _ensureCapacity(_size);
    var offset = _tdsHeaderSize;
    while (offset < _size) {
      final chunk = _transport.recv(_size - offset);
      if (chunk.isEmpty) {
        throw tds.ClosedConnectionError();
      }
      _buf.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _pos = _tdsHeaderSize;
    if (payloadLength == 0 && _status == 0) {
      _readPacket();
    }
  }

  ReadBuffer _readExact(int size) {
    if (size <= 0) {
      return ReadBuffer(Uint8List(0), 0, 0);
    }
    if (_availableBytes >= size) {
      final offset = _pos;
      _pos += size;
      return ReadBuffer(_buf, offset, size);
    }
    final builder = BytesBuilder(copy: false);
    var remaining = size;
    while (remaining > 0) {
      if (_pos >= _size) {
        if (_status == 1) {
          throw tds.ClosedConnectionError();
        }
        _readPacket();
        continue;
      }
      final chunk = math.min(remaining, _size - _pos);
      builder.add(Uint8List.sublistView(_buf, _pos, _pos + chunk));
      _pos += chunk;
      remaining -= chunk;
    }
    final data = builder.toBytes();
    return ReadBuffer(data, 0, data.length);
  }

  int get _availableBytes => math.max(0, _size - _pos);

  void _ensureCapacity(int size) {
    if (_buf.length >= size) {
      return;
    }
    final newLength = math.max(size, _buf.length * 2);
    final newBuf = Uint8List(newLength);
    newBuf.setRange(0, _buf.length, _buf);
    _buf = newBuf;
  }
}

/// Versão assíncrona do leitor de pacotes TDS.
class AsyncTdsReader implements tds.AsyncTransportProtocol {
  AsyncTdsReader({
    required tds.AsyncTransportProtocol transport,
    required this.session,
    int bufsize = 4096,
  })  : _transport = transport,
        _buf = Uint8List(bufsize),
        _pos = bufsize,
        _size = bufsize,
        _status = 1;

  tds.AsyncTransportProtocol _transport;
  final tds.TdsSessionContract session;

  Uint8List _buf;
  int _pos;
  int _size;
  int _status;
  int? _type;
  int _spid = 0;

  /// Obtém o transporte atual.
  tds.AsyncTransportProtocol get transport => _transport;
  
  /// Define um novo transporte (usado para TLS upgrade).
  void setTransport(tds.AsyncTransportProtocol value) {
    _transport = value;
  }

  int get bufsize => _buf.length;
  int get blockSize => _buf.length;

  void setBlockSize(int size) {
    if (size <= 0 || size == _buf.length) {
      return;
    }
    final newBuf = Uint8List(size);
    final copyLen = math.min(size, _buf.length);
    newBuf.setRange(0, copyLen, _buf);
    _buf = newBuf;
    if (_pos > size) {
      _pos = size;
    }
    if (_size > size) {
      _size = size;
    }
  }

  bool streamFinished() {
    if (_pos >= _size) {
      return _status == 1;
    }
    return false;
  }

  Future<ResponseMetadata> beginResponse() async {
    if (_status != 1 && _pos < _size) {
      throw StateError(
        'beginResponse chamado antes de consumir o pacote anterior',
      );
    }
    await _readPacket();
    return ResponseMetadata(type: _type ?? 0, spid: _spid);
  }

  int? get packetType => _type;
  int get status => _status;
  int get spid => _spid;

  Future<ReadBuffer> readFast(int size) => _readExact(size);

  Future<Uint8List> readBytes(int size) async {
    final slice = await _readExact(size);
    if (slice.offset == 0 && slice.length == slice.buffer.length) {
      return slice.buffer;
    }
    return Uint8List.sublistView(
      slice.buffer,
      slice.offset,
      slice.offset + slice.length,
    );
  }

  Future<int> getByte() async {
    final slice = await _readExact(1);
    return slice.buffer[slice.offset];
  }

  Future<int> getSmallInt() async {
    final slice = await _readExact(2);
    return slice.asByteData().getInt16(0, Endian.little);
  }

  Future<int> getUSmallInt() async {
    final slice = await _readExact(2);
    return slice.asByteData().getUint16(0, Endian.little);
  }

  Future<int> getInt() async {
    final slice = await _readExact(4);
    return slice.asByteData().getInt32(0, Endian.little);
  }

  Future<int> getUInt() async {
    final slice = await _readExact(4);
    return slice.asByteData().getUint32(0, Endian.little);
  }

  Future<int> getUIntBe() async {
    final slice = await _readExact(4);
    return slice.asByteData().getUint32(0, Endian.big);
  }

  Future<int> getUInt8() async {
    final slice = await _readExact(8);
    return slice.asByteData().getUint64(0, Endian.little);
  }

  Future<int> getInt8() async {
    final slice = await _readExact(8);
    return slice.asByteData().getInt64(0, Endian.little);
  }

  Future<String> readUcs2(int charCount) async {
    final bytes = await readBytes(charCount * 2);
    return ucs2Codec.decode(bytes);
  }

  Future<String> readStr(int size, Encoding codec) async {
    final bytes = await readBytes(size);
    return codec.decode(bytes);
  }

  Future<Collation> getCollation() async {
    final payload = await readBytes(Collation.wire_size);
    return Collation.unpack(payload);
  }

  Future<Uint8List> readWholePacket() async {
    final payloadSize = _size - _tdsHeaderSize;
    if (payloadSize <= 0) {
      return Uint8List(0);
    }
    _pos = _tdsHeaderSize;
    return readBytes(payloadSize);
  }

  @override
  bool get isConnected => _transport.isConnected;

  @override
  Future<void> close() => _transport.close();

  @override
  Duration? get timeout => _transport.timeout;

  @override
  set timeout(Duration? value) => _transport.timeout = value;

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) async {
    throw UnsupportedError('AsyncTdsReader é somente leitura');
  }

  @override
  Future<Uint8List> recv(int size) async {
    if (size <= 0) {
      return Uint8List(0);
    }
    if (_pos >= _size) {
      if (_status == 1) {
        return Uint8List(0);
      }
      await _readPacket();
    }
    final available = _size - _pos;
    final toRead = math.min(size, available);
    final slice = Uint8List.sublistView(_buf, _pos, _pos + toRead);
    _pos += toRead;
    return slice;
  }

  @override
  Future<Uint8List> recvAvailable(int maxSize) {
    return recv(maxSize);
  }

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) async {
    final target = buffer.asUint8List();
    final toFill = (size <= 0 || size > target.length) ? target.length : size;
    if (toFill == 0) {
      return 0;
    }
    final chunk = await recv(toFill);
    target.setRange(0, chunk.length, chunk);
    return chunk.length;
  }

  Future<void> _readPacket() async {
    final headerBytes = await _transport.recv(_tdsHeaderSize);
    if (headerBytes.length < _tdsHeaderSize) {
      throw tds.ClosedConnectionError();
    }
    _ensureCapacity(_tdsHeaderSize);
    _buf.setRange(0, _tdsHeaderSize, headerBytes);
    final headerView = ByteData.sublistView(_buf, 0, _tdsHeaderSize);
    _type = headerView.getUint8(0);
    _status = headerView.getUint8(1);
    _size = headerView.getUint16(2, Endian.big);
    _spid = headerView.getUint16(4, Endian.big);
    final payloadLength = math.max(0, _size - _tdsHeaderSize);
    _ensureCapacity(_size);
    var offset = _tdsHeaderSize;
    while (offset < _size) {
      final chunk = await _transport.recv(_size - offset);
      if (chunk.isEmpty) {
        throw tds.ClosedConnectionError();
      }
      _buf.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _pos = _tdsHeaderSize;
    if (payloadLength == 0 && _status == 0) {
      await _readPacket();
    }
  }

  Future<ReadBuffer> _readExact(int size) async {
    if (size <= 0) {
      return ReadBuffer(Uint8List(0), 0, 0);
    }
    if (_availableBytes >= size) {
      final offset = _pos;
      _pos += size;
      return ReadBuffer(_buf, offset, size);
    }
    final builder = BytesBuilder(copy: false);
    var remaining = size;
    while (remaining > 0) {
      if (_pos >= _size) {
        if (_status == 1) {
          throw tds.ClosedConnectionError();
        }
        await _readPacket();
        continue;
      }
      final chunk = math.min(remaining, _size - _pos);
      builder.add(Uint8List.sublistView(_buf, _pos, _pos + chunk));
      _pos += chunk;
      remaining -= chunk;
    }
    final data = builder.takeBytes();
    return ReadBuffer(data, 0, data.length);
  }

  int get _availableBytes => math.max(0, _size - _pos);

  void _ensureCapacity(int size) {
    if (_buf.length >= size) {
      return;
    }
    final newLength = math.max(size, _buf.length * 2);
    final newBuf = Uint8List(newLength);
    newBuf.setRange(0, _buf.length, _buf);
    _buf = newBuf;
  }
}
