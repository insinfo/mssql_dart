import '../tds_base.dart' show TlsBackend;
export '../tds_base.dart' show TlsBackend;

/// tls_base.dart
///
/// Definições base para o módulo TLS do mssql_dart.
/// Portado do pytds/tls.py.

/// Tamanho do buffer para operações TLS.
const int tlsBufferSize = 65536;

/// Configuração de TLS para conexão.
class TlsConfig {
  const TlsConfig({
    this.backend = TlsBackend.tlslite,
    this.cafile,
    this.validateHost = true,
    this.encLoginOnly = false,
  });
  
  /// Backend TLS utilizado para o handshake.
  final TlsBackend backend;
  
  /// Caminho para o arquivo de certificados CA em formato PEM.
  final String? cafile;
  
  /// Se true, valida o hostname do servidor contra o certificado.
  final bool validateHost;
  
  /// Se true, criptografa apenas o login e reverte para plaintext depois.
  /// Isso é inseguro pois permite que observadores vejam as queries SQL.
  final bool encLoginOnly;
  
  /// Cria uma cópia com os valores especificados.
  TlsConfig copyWith({
    TlsBackend? backend,
    String? cafile,
    bool? validateHost,
    bool? encLoginOnly,
  }) {
    return TlsConfig(
      backend: backend ?? this.backend,
      cafile: cafile ?? this.cafile,
      validateHost: validateHost ?? this.validateHost,
      encLoginOnly: encLoginOnly ?? this.encLoginOnly,
    );
  }
}

/// Verifica se um Subject Alternative Name (SAN) corresponde ao hostname.
bool isSanMatching(String san, String hostName) {
  for (var item in san.split(',')) {
    var dnsEntry = item.trim();
    // SANs geralmente têm o formato: DNS:hostname
    if (dnsEntry.startsWith('DNS:')) {
      dnsEntry = dnsEntry.substring(4).trim();
    }
    if (dnsEntry == hostName) {
      return true;
    }
    // Suporte a wildcards, mas apenas na primeira posição
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

/// Valida o hostname contra o certificado.
/// 
/// [certCN] é o Common Name do certificado.
/// [certSAN] é o Subject Alternative Name (opcional).
/// [hostName] é o hostname usado para conexão.
bool validateHostCertificate({
  required String? certCN,
  String? certSAN,
  required String hostName,
}) {
  // Primeiro verifica o CN
  if (certCN == hostName) {
    return true;
  }
  
  // Verifica o SAN se disponível
  if (certSAN != null && certSAN.isNotEmpty) {
    if (isSanMatching(certSAN, hostName)) {
      return true;
    }
  }
  
  // Verifica se o CN é um wildcard
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

