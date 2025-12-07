/// encrypted_socket.dart
///
/// Implementação de socket encriptado para TLS mid-stream.
/// encrypted_socket.dart
///
/// Implementação de transporte TLS capaz de realizar o handshake
/// encapsulado do SQL Server (TLS sobre pacotes PRELOGIN).

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tlslite/tlslite.dart' as tlslite;

import '../tds_base.dart' as tds;
import 'tls_transport.dart';
import 'tls_io_bridge.dart';

/// Implementação baseada no tlslite puro-Dart.
class PureDartEncryptedSocket implements EncryptedTransport {
  PureDartEncryptedSocket._({
    required this.underlyingTransport,
    required tlslite.TlsConnection tlsConnection,
    required TdsTlsIoBridge ioBridge,
  })  : _tlsConnection = tlsConnection,
        _ioBridge = ioBridge;

  final tds.AsyncTransportProtocol underlyingTransport;
  final tlslite.TlsConnection _tlsConnection;
  final TdsTlsIoBridge _ioBridge;
  Duration? _timeout;

  @override
  bool get isConnected => underlyingTransport.isConnected;

  @override
  Duration? get timeout => _timeout;

  @override
  set timeout(Duration? value) {
    _timeout = value;
    underlyingTransport.timeout = value;
  }

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) async {
    if (data.isEmpty) {
      return;
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    await _tlsConnection.write(bytes);
  }

  @override
  Future<Uint8List> recv(int size) async {
    if (size <= 0) {
      return Uint8List(0);
    }
    final chunks = <Uint8List>[];
    var remaining = size;
    while (remaining > 0) {
      final chunk = await _tlsConnection.read(max: remaining);
      if (chunk.isEmpty) {
        throw tds.ClosedConnectionError();
      }
      chunks.add(chunk);
      remaining -= chunk.length;
    }
    if (chunks.length == 1) {
      return chunks.first;
    }
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<Uint8List> recvAvailable(int maxSize) async {
    if (maxSize <= 0) {
      return Uint8List(0);
    }
    final chunk = await _tlsConnection.read(max: maxSize);
    if (chunk.isEmpty) {
      throw tds.ClosedConnectionError();
    }
    return chunk;
  }

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) async {
    final target = buffer.asUint8List();
    final desired = size <= 0 || size > target.length ? target.length : size;
    if (desired == 0) {
      return 0;
    }
    final bytes = await recv(desired);
    target.setRange(0, bytes.length, bytes);
    return bytes.length;
  }

  @override
  Future<void> shutdown() async {
    await _tlsConnection.close();
  }

  @override
  Future<void> close() async {
    await shutdown();
    await _ioBridge.closeUnderlying();
  }

  /// Estabelece o canal TLS encapsulado via PRELOGIN.
  static Future<PureDartEncryptedSocket> establish(
    TlsChannelContext context,
  ) async {
    final bridge = TdsTlsIoBridge(
      transport: context.transport,
      sendPreloginPacket: context.sendPreloginPacket,
      receivePreloginPacket: context.receivePreloginPacket,
    );
    final input = _TdsTlsBinaryInput(bridge);
    final output = _TdsTlsBinaryOutput(bridge);

    final tlsConn = tlslite.TlsConnection.custom(input, output);
    final settings = tlslite.HandshakeSettings(
      minVersion: (3, 1),
      maxVersion: (3, 4),
    );

    await tlsConn.handshakeClient(
      settings: settings,
      serverName: context.serverName,
    );

    bridge.enterStreamingMode();
    input.enterStreamingMode();
    output.enterStreamingMode();

    return PureDartEncryptedSocket._(
      underlyingTransport: context.transport,
      tlsConnection: tlsConn,
      ioBridge: bridge,
    );
  }
}

class _TdsTlsBinaryInput implements tlslite.BinaryInput {
  _TdsTlsBinaryInput(this._bridge);

  final TdsTlsIoBridge _bridge;
  final Queue<Uint8List> _chunks = Queue();
  int _offset = 0;
  int _buffered = 0;
  bool _streamingMode = false;

  void enterStreamingMode() {
    _streamingMode = true;
  }

  @override
  Future<void> ensureBytes(int count) async {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'deve ser não negativo');
    }
    while (_buffered < count) {
      final chunk = await _bridge.readChunk(count - _buffered);
      if (chunk.isEmpty) {
        throw StateError(
          'EOF durante ${_streamingMode ? 'streaming' : 'handshake'} TLS',
        );
      }
      _chunks.addLast(chunk);
      _buffered += chunk.length;
    }
  }

  @override
  int readUint8() {
    _requireAvailable(1);
    final chunk = _chunks.first;
    final value = chunk[_offset];
    _consume(1);
    return value;
  }

  @override
  int readInt16() {
    final bytes = _takeBytes(2);
    return ByteData.sublistView(bytes).getInt16(0, Endian.big);
  }

  @override
  int readInt32() {
    final bytes = _takeBytes(4);
    return ByteData.sublistView(bytes).getInt32(0, Endian.big);
  }

  @override
  List<int> readBytes(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'deve ser não negativo');
    }
    if (length == 0) {
      return Uint8List(0);
    }
    return _takeBytes(length);
  }

  void _requireAvailable(int count) {
    if (count <= 0) {
      return;
    }
    if (_buffered < count) {
      throw StateError('Dados insuficientes no buffer interno');
    }
  }

  Uint8List _takeBytes(int length) {
    _requireAvailable(length);
    final out = Uint8List(length);
    var written = 0;
    while (written < length) {
      final chunk = _chunks.first;
      final available = chunk.length - _offset;
      final toCopy = math.min(available, length - written);
      out.setRange(written, written + toCopy, chunk, _offset);
      written += toCopy;
      _consume(toCopy);
    }
    return out;
  }

  void _consume(int length) {
    _buffered -= length;
    _offset += length;
    while (_chunks.isNotEmpty && _offset >= _chunks.first.length) {
      _offset -= _chunks.first.length;
      _chunks.removeFirst();
    }
    if (_chunks.isEmpty) {
      _offset = 0;
    }
  }
}

class _TdsTlsBinaryOutput implements tlslite.BinaryOutput {
  _TdsTlsBinaryOutput(this._bridge, {int initialCapacity = 1024})
      : _buffer = Uint8List(initialCapacity);

  final TdsTlsIoBridge _bridge;
  Uint8List _buffer;
  int _writeOffset = 0;

  void enterStreamingMode() {
    // Nenhuma ação adicional é necessária neste modo.
  }

  @override
  int get length => _writeOffset;

  @override
  void ensureCapacity(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'deve ser não negativo');
    }
    final needed = _writeOffset + count;
    if (needed <= _buffer.length) {
      return;
    }
    var newCapacity = _buffer.length * 2;
    if (newCapacity < needed) {
      newCapacity = needed;
    }
    final newBuf = Uint8List(newCapacity)
      ..setRange(0, _writeOffset, _buffer);
    _buffer = newBuf;
  }

  @override
  void writeUint8(int value) {
    if (value < 0 || value > 0xFF) {
      throw RangeError.range(value, 0, 0xFF, 'value');
    }
    ensureCapacity(1);
    _buffer[_writeOffset++] = value;
  }

  @override
  void writeInt16(int value) {
    ensureCapacity(2);
    final view = ByteData.sublistView(_buffer, _writeOffset, _writeOffset + 2);
    view.setInt16(0, value, Endian.big);
    _writeOffset += 2;
  }

  @override
  void writeInt32(int value) {
    ensureCapacity(4);
    final view = ByteData.sublistView(_buffer, _writeOffset, _writeOffset + 4);
    view.setInt32(0, value, Endian.big);
    _writeOffset += 4;
  }

  @override
  void writeBytes(List<int> bytes) {
    if (bytes.isEmpty) {
      return;
    }
    ensureCapacity(bytes.length);
    _buffer.setRange(_writeOffset, _writeOffset + bytes.length, bytes);
    _writeOffset += bytes.length;
  }

  @override
  Future<void> flush() async {
    if (_writeOffset == 0) {
      return;
    }
    final payload = Uint8List(_writeOffset)
      ..setRange(0, _writeOffset, _buffer);
    _writeOffset = 0;
    await _bridge.send(payload);
  }
}
