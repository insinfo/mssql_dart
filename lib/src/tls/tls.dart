/// TLS for TDS connections, ported from pytds/tls.py.
///
/// In TDS 7.x the TLS handshake travels inside PRELOGIN packets; once it
/// completes, the session switches to TLS records directly on the socket.
/// Two backends implement this, chosen with [TlsBackend]:
///
/// - [TlsBackend.tlslite] (default): pure Dart (package:tlslite), with
///   certificate chain and host name validation.
/// - [TlsBackend.openSsl]: the system OpenSSL through FFI. It does not
///   validate the server certificate, so it requires
///   `trustServerCertificate: true`.
///
/// Applications configure TLS through `MssqlConnectionSettings` (`encrypt`,
/// `caFile`, `trustServerCertificate`, `validateHostName`, `tlsBackend`).
library mssql_dart.tls;

export 'tls_base.dart';
export 'tls_transport.dart';
export 'tls_channel.dart'
    show establishChannel, revertToClear, TdsSessionForTls;
