import 'dart:io';

/// Interface for asynchronous transports that can be upgraded to TLS.
abstract class AsyncTlsTransport {
  Future<void> upgradeToSecureSocket({
    required SecurityContext context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    String? host,
    bool loginOnly = false,
  });

  bool get isSecure;
  String? get remoteHost;
}
