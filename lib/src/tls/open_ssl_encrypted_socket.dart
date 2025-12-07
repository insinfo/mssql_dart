import 'dart:async';
import 'dart:typed_data';

import 'package:tlslite/tlslite.dart';
import 'package:tlslite/openssl.dart';

import '../tds_base.dart' as tds;
import 'tls_io_bridge.dart';
import 'tls_transport.dart';

/// Transporte TLS baseado em OpenSSL FFI usando o mesmo fluxo encapsulado via PRELOGIN.
class OpenSslEncryptedSocket implements EncryptedTransport {
  OpenSslEncryptedSocket._({
    required this.underlyingTransport,
    required SecureSocketOpenSSLAsync tlsEngine,
    required TdsTlsIoBridge ioBridge,
  })  : _tls = tlsEngine,
        _ioBridge = ioBridge;

  final tds.AsyncTransportProtocol underlyingTransport;
  final SecureSocketOpenSSLAsync _tls;
  final TdsTlsIoBridge _ioBridge;
  Duration? _timeout;

  static Future<bool> isAvailable() async {
    try {
      // Tenta carregar as libs; falha se não encontrar.
      OpenSslBindings.load();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Estabelece o handshake TLS encapsulado via PRELOGIN.
  static Future<OpenSslEncryptedSocket> establish(
    TlsChannelContext context,
  ) async {
    final bridge = TdsTlsIoBridge(
      transport: context.transport,
      sendPreloginPacket: context.sendPreloginPacket,
      receivePreloginPacket: context.receivePreloginPacket,
    );

    final tlsEngine = SecureSocketOpenSSLAsync.clientWithCallbacks(
      writer: (cipher) => bridge.send(cipher),
      reader: (preferred) async {
        final chunk = await bridge.readChunk(preferred);
        if (chunk.isEmpty) {
          return null;
        }
        return chunk;
      },
    );

    // Completa handshake.
    await tlsEngine.ensureHandshakeCompleted();

    // Passa para modo streaming: PRELOGIN -> TLS direto.
    bridge.enterStreamingMode();

    return OpenSslEncryptedSocket._(
      underlyingTransport: context.transport,
      tlsEngine: tlsEngine,
      ioBridge: bridge,
    );
  }

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
    await _tls.send(bytes);
  }

  @override
  Future<Uint8List> recv(int size) async {
    if (size <= 0) {
      return Uint8List(0);
    }
    final chunk = await _tls.recv(size);
    if (chunk.isEmpty) {
      throw tds.ClosedConnectionError();
    }
    return chunk;
  }

  @override
  Future<Uint8List> recvAvailable(int maxSize) async {
    if (maxSize <= 0) {
      return Uint8List(0);
    }
    final chunk = await _tls.recv(maxSize);
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
    final data = await recv(desired);
    target.setRange(0, data.length, data);
    return data.length;
  }

  @override
  Future<void> shutdown() async {
    await _tls.shutdown();
  }

  @override
  Future<void> close() async {
    await _tls.close();
    await _ioBridge.closeUnderlying();
  }
}
