/// tls_transport.dart
///
/// Abstract interface for TLS transports that support a dynamic mid-stream
/// upgrade. Ported from pytds/tls.py.

import 'dart:async';
import 'dart:typed_data';

import '../tds_base.dart' as tds;
import 'tls_base.dart';

/// Interface for encrypted TLS transports.
///
/// Abstracts the different TLS implementations (OpenSSL, pure Dart) so the
/// TDS code works with any of them.
abstract class EncryptedTransport implements tds.AsyncTransportProtocol {
  /// The underlying (unencrypted) transport.
  tds.AsyncTransportProtocol get underlyingTransport;

  /// Closes the TLS connection and releases its resources.
  Future<void> shutdown();
}

/// Callback notified when the transport changes.
typedef TransportChangeCallback = void Function(
    tds.AsyncTransportProtocol newTransport);

/// Context for establishing a TLS channel.
///
/// Holds everything needed to perform the TDS-style TLS handshake (data
/// encapsulated in PRELOGIN packets).
class TlsChannelContext {
  TlsChannelContext({
    required this.transport,
    required this.serverName,
    required this.tlsConfig,
    required this.sendPreloginPacket,
    required this.receivePreloginPacket,
    this.onTransportChanged,
  });

  /// Current (plaintext) transport.
  final tds.AsyncTransportProtocol transport;

  /// Server name used for certificate validation.
  final String serverName;

  /// TLS configuration.
  final TlsConfig tlsConfig;

  /// Sends data encapsulated in a PRELOGIN packet.
  final Future<void> Function(Uint8List data) sendPreloginPacket;

  /// Receives data from a PRELOGIN packet.
  final Future<Uint8List> Function() receivePreloginPacket;

  /// Called when the transport is replaced.
  final TransportChangeCallback? onTransportChanged;
}

/// Factory that creates TLS transports for the configured provider.
abstract class TlsTransportFactory {
  /// Creates an encrypted TLS transport on top of the existing transport.
  ///
  /// [context] holds everything needed for the handshake. Returns the new
  /// encrypted transport.
  Future<EncryptedTransport> establishChannel(TlsChannelContext context);

  /// Backend supported by this factory.
  TlsBackend get backend;
}
