/// tls_transport.dart
///
/// Interface abstrata para transportes TLS que suportam upgrade dinâmico mid-stream.
/// Portado do pytds/tls.py.

import 'dart:async';
import 'dart:typed_data';

import '../tds_base.dart' as tds;
import 'tls_base.dart';

/// Interface para transportes TLS encriptados.
/// 
/// Esta interface abstrai diferentes implementações de TLS (OpenSSL, Pure Dart)
/// permitindo que o código TDS funcione com qualquer uma delas.
abstract class EncryptedTransport implements tds.AsyncTransportProtocol {
  /// O transporte subjacente (não encriptado).
  tds.AsyncTransportProtocol get underlyingTransport;
  
  /// Fecha a conexão TLS e libera recursos.
  Future<void> shutdown();
}

/// Callback para notificar mudanças de transporte.
typedef TransportChangeCallback = void Function(tds.AsyncTransportProtocol newTransport);

/// Contexto para estabelecer canal TLS.
/// 
/// Contém todas as informações necessárias para realizar o handshake TLS
/// no estilo do TDS (dados encapsulados em pacotes PRELOGIN).
class TlsChannelContext {
  TlsChannelContext({
    required this.transport,
    required this.serverName,
    required this.tlsConfig,
    required this.sendPreloginPacket,
    required this.receivePreloginPacket,
    this.onTransportChanged,
    this.tlsContext,
  });
  
  /// Transporte atual (plaintext).
  final tds.AsyncTransportProtocol transport;
  
  /// Nome do servidor para validação de certificado.
  final String serverName;
  
  /// Configuração TLS.
  final TlsConfig tlsConfig;
  
  /// Função para enviar dados encapsulados em pacote PRELOGIN.
  final Future<void> Function(Uint8List data) sendPreloginPacket;
  
  /// Função para receber dados de pacote PRELOGIN.
  final Future<Uint8List> Function() receivePreloginPacket;
  
  /// Callback chamado quando o transporte é alterado.
  final TransportChangeCallback? onTransportChanged;

  /// Contexto TLS específico do backend (ex.: SecurityContext para OpenSSL).
  final Object? tlsContext;
}

/// Factory para criar transportes TLS baseado no provider configurado.
abstract class TlsTransportFactory {
  /// Cria um transporte TLS encriptado sobre o transporte existente.
  /// 
  /// [context] contém todas as informações necessárias para o handshake.
  /// Retorna o novo transporte encriptado.
  Future<EncryptedTransport> establishChannel(TlsChannelContext context);
  
  /// Backend suportado por esta factory.
  TlsBackend get backend;
}
