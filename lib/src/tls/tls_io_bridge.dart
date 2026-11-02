import 'dart:math' as math;
import 'dart:typed_data';

import '../tds_base.dart' as tds;

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
  }

  Future<void> send(Uint8List data) async {
    if (data.isEmpty) return;
    if (_preloginMode) {
      // Accumulate TLS records in buffer - will be sent when readChunk is called
      _preloginBuffer.add(data);
      return;
    }
    await transport.sendAll(data);
  }

  /// Flush any accumulated PRELOGIN data as a single packet
  Future<void> _flushPreloginBuffer() async {
    if (_preloginBuffer.isEmpty) return;
    await sendPreloginPacket(_preloginBuffer.takeBytes());
  }

  Future<Uint8List> readChunk(int minBytes) async {
    if (_preloginMode) {
      // Flush any accumulated TLS records before waiting for response
      await _flushPreloginBuffer();
      return receivePreloginPacket();
    }
    return transport.recvAvailable(math.max(1, minBytes));
  }
}
