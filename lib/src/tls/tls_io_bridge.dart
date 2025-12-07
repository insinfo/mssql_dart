import 'dart:math' as math;
import 'dart:typed_data';
import 'package:logging/logging.dart';

import '../tds_base.dart' as tds;

final _logger = Logger('TdsTlsIoBridge');

/// Bridge that multiplexes TLS ciphertext over PRELOGIN packets during the
/// handshake and switches to the raw transport afterward.
/// 
/// During PRELOGIN mode, multiple TLS records (e.g., ClientKeyExchange + 
/// ChangeCipherSpec + Finished) are buffered and sent as a single PRELOGIN 
/// packet to comply with SQL Server's TLS-over-TDS requirements.
class TdsTlsIoBridge {
  TdsTlsIoBridge({
    required this.transport,
    required this.sendPreloginPacket,
    required this.receivePreloginPacket,
  });

  final tds.AsyncTransportProtocol transport;
  final Future<void> Function(Uint8List data) sendPreloginPacket;
  final Future<Uint8List> Function() receivePreloginPacket;

  bool _preloginMode = true;
  
  /// Buffer to accumulate TLS records before sending as single PRELOGIN packet
  final BytesBuilder _preloginBuffer = BytesBuilder(copy: false);

  Future<void> closeUnderlying() => transport.close();

  void enterStreamingMode() {
    _preloginMode = false;
    _debug('Entered streaming mode; future send/read bypass PRELOGIN.');
  }

  Future<void> send(Uint8List data) async {
    if (data.isEmpty) {
      _debug('send called with empty payload; ignoring.');
      return;
    }
    if (_preloginMode) {
      // Accumulate TLS records in buffer - will be sent when readChunk is called
      _preloginBuffer.add(data);
      _debug('send (PRELOGIN) buffered ${data.length} bytes, total=${_preloginBuffer.length}');
      return;
    }
    _debug('send (stream) len=${data.length}');
    await transport.sendAll(data);
  }
  
  /// Flush any accumulated PRELOGIN data as a single packet
  Future<void> _flushPreloginBuffer() async {
    if (_preloginBuffer.isEmpty) {
      return;
    }
    final data = _preloginBuffer.takeBytes();
    _debug('flushing PRELOGIN buffer: ${data.length} bytes');
    await sendPreloginPacket(data);
  }

  Future<Uint8List> readChunk(int minBytes) async {
    _debug('readChunk request minBytes=$minBytes mode=${_preloginMode ? 'PRELOGIN' : 'stream'}');
    if (_preloginMode) {
      // Flush any accumulated TLS records before waiting for response
      await _flushPreloginBuffer();
      
      final packet = await receivePreloginPacket();
      _debug('readChunk PRELOGIN received ${packet.length} bytes');
      return packet;
    }
    final size = math.max(1, minBytes);
    final chunk = await transport.recvAvailable(size);
    _debug('readChunk stream received ${chunk.length} bytes (requested $size)');
    return chunk;
  }

  void _debug(String message) {
    _logger.fine(message);
  }
}
