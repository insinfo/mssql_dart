import '../tds_base.dart' show TlsBackend;
export '../tds_base.dart' show TlsBackend;

/// tls_base.dart
///
/// Base definitions for the mssql_dart TLS module.
/// Ported from pytds/tls.py.

/// Buffer size for TLS operations.
const int tlsBufferSize = 65536;

/// TLS configuration for a connection.
class TlsConfig {
  const TlsConfig({
    this.backend = TlsBackend.tlslite,
    this.cafile,
    this.validateHost = true,
    this.encLoginOnly = false,
    this.trustServerCertificate = false,
  });

  /// TLS backend used for the handshake.
  final TlsBackend backend;

  /// Path to the CA certificate file in PEM format.
  final String? cafile;

  /// If true, validates the server hostname against the certificate.
  final bool validateHost;

  /// If true, encrypts only the login and reverts to plaintext afterwards.
  /// This is insecure: observers can see the SQL queries.
  final bool encLoginOnly;

  /// If true, accepts any certificate (validates neither chain nor hostname).
  final bool trustServerCertificate;

  /// Creates a copy with the given values replaced.
  TlsConfig copyWith({
    TlsBackend? backend,
    String? cafile,
    bool? validateHost,
    bool? encLoginOnly,
    bool? trustServerCertificate,
  }) {
    return TlsConfig(
      backend: backend ?? this.backend,
      cafile: cafile ?? this.cafile,
      validateHost: validateHost ?? this.validateHost,
      encLoginOnly: encLoginOnly ?? this.encLoginOnly,
      trustServerCertificate:
          trustServerCertificate ?? this.trustServerCertificate,
    );
  }
}

/// Whether a Subject Alternative Name (SAN) matches the hostname.
bool isSanMatching(String san, String hostName) {
  for (var item in san.split(',')) {
    var dnsEntry = item.trim();
    // SANs usually have the form DNS:hostname
    if (dnsEntry.startsWith('DNS:')) {
      dnsEntry = dnsEntry.substring(4).trim();
    }
    if (dnsEntry == hostName) {
      return true;
    }
    // Wildcards are supported, but only in the first label
    if (dnsEntry.startsWith('*.')) {
      final afterStar = dnsEntry.substring(2);
      final hostParts = hostName.split('.');
      if (hostParts.length > 1) {
        final afterStarHost = hostParts.sublist(1).join('.');
        if (afterStar == afterStarHost) {
          return true;
        }
      }
    }
  }
  return false;
}

/// Validates the hostname against the certificate.
///
/// [certCN] is the certificate's Common Name, [certSAN] its (optional)
/// Subject Alternative Name, and [hostName] the hostname used to connect.
bool validateHostCertificate({
  required String? certCN,
  String? certSAN,
  required String hostName,
}) {
  // Check the CN first
  if (certCN == hostName) {
    return true;
  }

  // Then the SAN, if present
  if (certSAN != null && certSAN.isNotEmpty) {
    if (isSanMatching(certSAN, hostName)) {
      return true;
    }
  }

  // Finally, a wildcard CN
  if (certCN != null && certCN.startsWith('*.')) {
    final afterStar = certCN.substring(2);
    final hostParts = hostName.split('.');
    if (hostParts.length > 1) {
      final afterStarHost = hostParts.sublist(1).join('.');
      if (afterStar == afterStarHost) {
        return true;
      }
    }
  }

  return false;
}
