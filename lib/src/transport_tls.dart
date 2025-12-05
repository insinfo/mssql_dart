import 'dart:io';

/// Interface para transportes assíncronos capazes de realizar upgrade para TLS.
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
