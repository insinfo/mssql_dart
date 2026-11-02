import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'collate.dart';
import 'tds_base.dart' as tds;

const _tdsHeaderSize = 8;

/// Minimal metadata of a TDS response packet.
class ResponseMetadata {
  final int type;
  final int spid;
  const ResponseMetadata({required this.type, required this.spid});
}

/// Helper that exposes a slice of the internal buffer without copying.
class ReadBuffer {
  final Uint8List buffer;
  final int offset;
  final int length;
  const ReadBuffer(this.buffer, this.offset, this.length);

  ByteData asByteData() =>
      ByteData.sublistView(buffer, offset, offset + length);
}

/// TDS packet reader (a direct port of pytds).
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
        'beginResponse called before the previous packet was consumed',
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
    throw UnsupportedError('TdsReader is read-only');
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
        throw tds.ClosedConnectionException();
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
    // Copy: the next packet is read into the same buffer and would overwrite
    // a view of the bytes already collected.
    final builder = BytesBuilder(copy: true);
    var remaining = size;
    while (remaining > 0) {
      if (_pos >= _size) {
        if (_status == 1) {
          throw tds.ClosedConnectionException();
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

/// Asynchronous TDS packet reader.
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

  /// The current transport.
  tds.AsyncTransportProtocol get transport => _transport;

  /// Replaces the transport (used for the TLS upgrade).
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
        'beginResponse called before the previous packet was consumed',
      );
    }
    await _readPacket();
    return ResponseMetadata(type: _type ?? 0, spid: _spid);
  }

  int? get packetType => _type;
  int get status => _status;
  int get spid => _spid;

  Future<ReadBuffer> readFast(int size) => _readExact(size);

  /// Reads [size] bytes. The result is always a copy, because the packet
  /// buffer is reused for the next packet.
  Future<Uint8List> readBytes(int size) async {
    final slice = await _readExact(size);
    if (!identical(slice.buffer, _buf)) {
      return slice.buffer;
    }
    return slice.buffer.sublist(slice.offset, slice.offset + slice.length);
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
    throw UnsupportedError('AsyncTdsReader is read-only');
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
      throw tds.ClosedConnectionException();
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
        throw tds.ClosedConnectionException();
      }
      _buf.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _pos = _tdsHeaderSize;
    if (payloadLength == 0 && _status == 0) {
      await _readPacket();
    }
  }

  /// Buffer of the current packet, for synchronous decoding ([ByteCursor]).
  Uint8List get rawBuffer => _buf;

  /// Read position within [rawBuffer].
  int get position => _pos;
  set position(int value) => _pos = value;

  /// End of the valid data in [rawBuffer].
  int get limit => _size;

  /// Reads the next packet of the same message and appends it to the bytes
  /// not yet consumed, which are moved to the start of the buffer. Earlier
  /// views of [rawBuffer] become invalid.
  Future<void> appendNextPacket() async {
    if (_status == 1) {
      throw tds.InterfaceException(
          'Server response ended in the middle of a token');
    }
    final header = await _transport.recv(_tdsHeaderSize);
    if (header.length < _tdsHeaderSize) {
      throw tds.ClosedConnectionException();
    }
    final headerView = ByteData.sublistView(header);
    final packetSize = headerView.getUint16(2, Endian.big);
    final payload = packetSize - _tdsHeaderSize;
    if (payload < 0) {
      throw tds.InterfaceException('Invalid packet size: $packetSize');
    }
    final remaining = _size - _pos;
    if (remaining + payload > _buf.length) {
      final grown = Uint8List(math.max(remaining + payload, _buf.length * 2));
      grown.setRange(0, remaining, _buf, _pos);
      _buf = grown;
    } else if (_pos > 0) {
      _buf.setRange(0, remaining, _buf, _pos);
    }
    _pos = 0;
    _size = remaining;
    _type = headerView.getUint8(0);
    _status = headerView.getUint8(1);
    _spid = headerView.getUint16(4, Endian.big);
    while (_size < remaining + payload) {
      final chunk = await _transport.recv(remaining + payload - _size);
      if (chunk.isEmpty) {
        throw tds.ClosedConnectionException();
      }
      _buf.setRange(_size, _size + chunk.length, chunk);
      _size += chunk.length;
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
    // Copy: the next packet is read into the same buffer and would overwrite
    // a view of the bytes already collected.
    final builder = BytesBuilder(copy: true);
    var remaining = size;
    while (remaining > 0) {
      if (_pos >= _size) {
        if (_status == 1) {
          throw tds.ClosedConnectionException();
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
