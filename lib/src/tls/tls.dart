/// tls.dart
///
/// Módulo de TLS para mssql_dart, portado do pytds/tls.py.
/// 
/// Oferece três modos de TLS:
/// - SecureSocket nativo do Dart (TLS-first, requer conexão segura desde o início)
/// - OpenSSL via FFI (SecureSocketOpenSSLAsync): Permite upgrade mid-stream
/// - Pure Dart (TlsConnection do tlslite): Permite upgrade mid-stream sem dependências
///
/// O usuário pode escolher a implementação via [TlsBackend].
///
/// ## Uso básico
/// 
/// ```dart
/// // TLS-first (mais simples, recomendado)
/// final conn = await connectAsync(
///   host: 'servidor.exemplo.com',
///   user: 'usuario',
///   password: 'senha',
///   encrypt: true,
/// );
///  senha certificado SqlServer123
/// C:\MyDartProjects\tlslite\packages\mssql_dart\scripts\certificate\sqlserver.pfx 
/// 
/// // Com upgrade mid-stream (Pure Dart)
/// final conn = await connectAsync(
///   host: 'servidor.exemplo.com',
///   user: 'usuario',
///   password: 'senha',
///   encrypt: true,
///   tlsBackend: TlsBackend.pureDart,
///   encLoginOnly: true, // Apenas login encriptado
/// );
/// ```

library mssql_dart.tls;

export 'tls_base.dart';
export 'tls_transport.dart';
export 'tls_channel.dart' show establishChannel, revertToClear, TdsSessionForTls;
