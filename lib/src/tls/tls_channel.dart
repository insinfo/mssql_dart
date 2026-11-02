/// tls_channel.dart
///
/// TLS channel establishment for TDS.
/// Ported from pytds/tls.py establish_channel and revert_to_clear.
///
/// TDS uses a special mechanism in which TLS data is encapsulated in
/// PRELOGIN packets during the handshake, before switching to direct TLS
/// communication.

import 'dart:async';
import 'dart:typed_data';

import '../tds_base.dart' as tds;
import '../tds_reader.dart' show ResponseMetadata;
import 'tls_base.dart';
import 'encrypted_socket.dart';
import 'tls_transport.dart';
import 'tls_providers.dart';
import 'open_ssl_encrypted_socket.dart';

/// Establishes a TLS channel over a TDS session.
///
/// Implements the TDS-specific TLS handshake, in which the handshake data is
/// encapsulated in PRELOGIN packets.
///
/// [session] is the current TDS session, [login] holds the TLS settings, and
/// [backend] selects the TLS implementation.
///
/// Once established, the session's transport is replaced by the encrypted
/// transport.
Future<void> establishChannel({
  required TdsSessionForTls session,
  required tds.TdsLogin login,
  TlsBackend backend = TlsBackend.tlslite,
}) async {
  final provider = await resolveProvider(backend);
  if (backend == TlsBackend.openSsl && !login.trustServerCertificate) {
    throw tds.OperationalException(
      'TlsBackend.openSsl does not validate the server certificate. Use the '
      'default backend (TlsBackend.tlslite) or pass trustServerCertificate: true.',
    );
  }
  if (provider is OpenSslTlsProvider && backend == TlsBackend.openSsl) {
    final available = await OpenSslTlsProvider.isAvailable();
    if (!available) {
      throw tds.OperationalException(
        'TlsBackend.openSsl selected, but the OpenSSL libraries could not be loaded. '
        'Set OPENSSL_LIBSSL_PATH/OPENSSL_LIBCRYPTO_PATH or use tlsBackend=pureDart.',
      );
    }
  }

  switch (provider) {
    case PureDartTlsProvider():
      await _establishWithPureDart(session, login);
      break;
    case OpenSslTlsProvider():
      await _establishWithOpenSsl(session, login);
      break;
    default:
      throw tds.OperationalException(
          'Unsupported TLS provider: ${provider.id}');
  }
}

/// Reverts the connection to unencrypted mode.
///
/// Used when the client sent ENCRYPT_OFF and must return to plaintext after
/// the encrypted login.
///
/// [session] is the current TDS session.
void revertToClear(TdsSessionForTls session) {
  final currentTransport = session.currentTransport;

  if (currentTransport is EncryptedTransport) {
    final clearTransport = currentTransport.underlyingTransport;

    // Shut down TLS (sends close_notify)
    currentTransport.shutdown();

    // Restore the original transport
    session.replaceTransport(clearTransport);
  }
}

/// Interface a TDS session must implement to support mid-stream TLS.
abstract class TdsSessionForTls {
  /// Current transport.
  tds.AsyncTransportProtocol get currentTransport;

  /// Writer used to send packets.
  TdsWriterForTls get writer;

  /// Reader used to receive packets.
  TdsReaderForTls get reader;

  /// Replaces the current transport with [newTransport].
  void replaceTransport(tds.AsyncTransportProtocol newTransport);
}

/// Writer interface used by TLS.
abstract class TdsWriterForTls {
  /// Starts a PRELOGIN packet.
  void beginPacket(int packetType);

  /// Writes [data] to the buffer.
  Future<void> write(List<int> data);

  /// Sends the packet.
  Future<void> flush();

  /// Current transport.
  tds.AsyncTransportProtocol get transport;

  /// Sets the transport.
  set transport(tds.AsyncTransportProtocol value);
}

/// Reader interface used by TLS.
abstract class TdsReaderForTls {
  /// Starts reading a response.
  Future<ResponseMetadata> beginResponse();

  /// Reads [size] bytes from the stream.
  Future<Uint8List> recv(int size);

  /// Whether the stream has ended.
  bool streamFinished();

  /// Current transport.
  tds.AsyncTransportProtocol get transport;

  /// Sets the transport.
  set transport(tds.AsyncTransportProtocol value);
}

/// Establishes TLS using OpenSSL FFI.
Future<void> _establishWithOpenSsl(
  TdsSessionForTls session,
  tds.TdsLogin login,
) async {
  final context = _buildTlsContext(
    session: session,
    login: login,
    backend: TlsBackend.openSsl,
  );
  final encrypted = await OpenSslEncryptedSocket.establish(context);
  session.replaceTransport(encrypted);
}

Future<void> _establishWithPureDart(
  TdsSessionForTls session,
  tds.TdsLogin login,
) async {
  final context = _buildTlsContext(
    session: session,
    login: login,
    backend: TlsBackend.tlslite,
  );
  final encrypted = await PureDartEncryptedSocket.establish(context);
  session.replaceTransport(encrypted);
}

TlsChannelContext _buildTlsContext({
  required TdsSessionForTls session,
  required tds.TdsLogin login,
  required TlsBackend backend,
}) {
  final writer = session.writer;
  final reader = session.reader;
  return TlsChannelContext(
    transport: session.currentTransport,
    serverName: login.serverName,
    tlsConfig: TlsConfig(
      backend: backend,
      cafile: login.cafile,
      validateHost: login.validateHost,
      encLoginOnly: login.encLoginOnly,
      trustServerCertificate: login.trustServerCertificate,
    ),
    sendPreloginPacket: (data) => _sendPreloginFragment(writer, data),
    receivePreloginPacket: () => _receivePreloginFragment(reader),
    onTransportChanged: session.replaceTransport,
  );
}

Future<void> _sendPreloginFragment(
  TdsWriterForTls writer,
  Uint8List data,
) async {
  writer.beginPacket(tds.PacketType.PRELOGIN);
  await writer.write(data);
  await writer.flush();
}

Future<Uint8List> _receivePreloginFragment(
  TdsReaderForTls reader,
) async {
  final response = await reader.beginResponse();
  if (response.type != tds.PacketType.PRELOGIN) {
    throw tds.OperationalException(
      'Expected a PRELOGIN packet during the TLS handshake, '
      'but the server responded with ${response.type}',
    );
  }
  final builder = BytesBuilder(copy: false);
  while (!reader.streamFinished()) {
    final chunk = await reader.recv(tlsBufferSize);
    if (chunk.isEmpty) {
      break;
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}
