import '../tds_base.dart' as tds;
import 'tls_transport.dart';
import 'encrypted_socket.dart';
import 'open_ssl_encrypted_socket.dart';

/// TLS provider abstraction (handshake over PRELOGIN, then streaming).
abstract class TlsProvider {
  /// Human-readable backend identifier.
  String get id;

  /// Establishes the encapsulated TLS transport.
  Future<EncryptedTransport> establish(TlsChannelContext context);
}

/// Provider backed by the pure Dart engine (tlslite).
class PureDartTlsProvider implements TlsProvider {
  const PureDartTlsProvider();

  @override
  String get id => 'pure-dart';

  @override
  Future<EncryptedTransport> establish(TlsChannelContext context) {
    return PureDartEncryptedSocket.establish(context);
  }
}

/// Provider backed by OpenSSL via FFI.
class OpenSslTlsProvider implements TlsProvider {
  const OpenSslTlsProvider();

  @override
  String get id => 'openssl';

  @override
  Future<EncryptedTransport> establish(TlsChannelContext context) {
    return OpenSslEncryptedSocket.establish(context);
  }

  /// Whether the OpenSSL libraries can be loaded in this environment.
  static Future<bool> isAvailable() {
    return OpenSslEncryptedSocket.isAvailable();
  }
}

/// Resolves the provider for the configured backend.
Future<TlsProvider> resolveProvider(tds.TlsBackend backend) async {
  switch (backend) {
    case tds.TlsBackend.openSsl:
      return const OpenSslTlsProvider();
    case tds.TlsBackend.tlslite:
      return const PureDartTlsProvider();
  }
}
