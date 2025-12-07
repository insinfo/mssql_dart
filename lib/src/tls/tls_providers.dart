import '../tds_base.dart' as tds;
import 'tls_transport.dart';
import 'encrypted_socket.dart';
import 'open_ssl_encrypted_socket.dart';

/// Abstração de provedor TLS (handshake via PRELOGIN + streaming).
abstract class TlsProvider {
  /// Identificador legível do backend.
  String get id;

  /// Estabelece o transporte TLS encapsulado.
  Future<EncryptedTransport> establish(TlsChannelContext context);
}

/// Provider baseado no engine puro Dart (tlslite).
class PureDartTlsProvider implements TlsProvider {
  const PureDartTlsProvider();

  @override
  String get id => 'pure-dart';

  @override
  Future<EncryptedTransport> establish(TlsChannelContext context) {
    return PureDartEncryptedSocket.establish(context);
  }
}

/// Provider baseado em OpenSSL via FFI.
class OpenSslTlsProvider implements TlsProvider {
  const OpenSslTlsProvider();

  @override
  String get id => 'openssl';

  @override
  Future<EncryptedTransport> establish(TlsChannelContext context) {
    return OpenSslEncryptedSocket.establish(context);
  }

  /// Verifica se as bibliotecas OpenSSL podem ser carregadas no ambiente.
  static Future<bool> isAvailable() {
    return OpenSslEncryptedSocket.isAvailable();
  }
}

/// Resolve um provider a partir do backend configurado.
Future<TlsProvider> resolveProvider(tds.TlsBackend backend) async {
  switch (backend) {
    case tds.TlsBackend.openSsl:
      return const OpenSslTlsProvider();
    case tds.TlsBackend.tlslite:
      return const PureDartTlsProvider();
    case tds.TlsBackend.dartSecureSocket:
      // Não suporta upgrade mid-stream.
      throw tds.OperationalError(
        'TlsBackend.dartSecureSocket não suporta upgrade TLS mid-stream. '
        'Use encrypt=true para TLS-first ou selecione pureDart/openSsl.',
      );
  }
}
