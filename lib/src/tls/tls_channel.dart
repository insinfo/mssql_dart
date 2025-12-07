/// tls_channel.dart
///
/// Implementação do estabelecimento de canal TLS para TDS.
/// Portado do pytds/tls.py establish_channel e revert_to_clear.
///
/// O TDS usa um mecanismo especial onde os dados TLS são encapsulados
/// em pacotes PRELOGIN durante o handshake, antes de trocar para
/// comunicação TLS direta.

import 'dart:async';
import 'dart:typed_data';

import '../tds_base.dart' as tds;
import '../tds_reader.dart' show ResponseMetadata;
import 'tls_base.dart';
import 'encrypted_socket.dart';
import 'tls_transport.dart';
import 'tls_providers.dart';
import 'open_ssl_encrypted_socket.dart';

/// Estabelece um canal TLS sobre uma sessão TDS.
/// 
/// Esta função implementa o handshake TLS especial do TDS, onde os dados
/// do handshake são encapsulados em pacotes PRELOGIN.
/// 
/// [session] é a sessão TDS atual.
/// [login] contém as configurações de TLS.
/// [provider] especifica qual implementação TLS usar.
/// 
/// Após o estabelecimento, o transporte da sessão é substituído pelo
/// transporte encriptado.
Future<void> establishChannel({
  required TdsSessionForTls session,
  required tds.TdsLogin login,
  TlsBackend backend = TlsBackend.tlslite,
}) async {
  final provider = await resolveProvider(backend);
  if (provider is OpenSslTlsProvider && backend == TlsBackend.openSsl) {
    final available = await OpenSslTlsProvider.isAvailable();
    if (!available) {
      throw tds.OperationalError(
        'TlsBackend.openSsl selecionado, mas as bibliotecas OpenSSL não foram carregadas. '
        'Defina OPENSSL_LIBSSL_PATH/OPENSSL_LIBCRYPTO_PATH ou use tlsBackend=pureDart.',
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
      throw tds.OperationalError('Provedor TLS não suportado: ${provider.id}');
  }
}

/// Reverte a conexão para modo não-encriptado.
/// 
/// Usado quando o cliente enviou ENCRYPT_OFF e precisa voltar para
/// plaintext após o login encriptado.
/// 
/// [session] é a sessão TDS atual.
void revertToClear(TdsSessionForTls session) {
  final currentTransport = session.currentTransport;
  
  if (currentTransport is EncryptedTransport) {
    final clearTransport = currentTransport.underlyingTransport;
    
    // Faz shutdown do TLS (envia close_notify)
    currentTransport.shutdown();
    
    // Restaura o transporte original
    session.replaceTransport(clearTransport);
  }
}

/// Interface que a sessão TDS deve implementar para suportar TLS mid-stream.
abstract class TdsSessionForTls {
  /// Transporte atual.
  tds.AsyncTransportProtocol get currentTransport;
  
  /// Writer para enviar pacotes.
  TdsWriterForTls get writer;
  
  /// Reader para receber pacotes.
  TdsReaderForTls get reader;
  
  /// Substitui o transporte atual por um novo.
  void replaceTransport(tds.AsyncTransportProtocol newTransport);
}

/// Interface do writer para TLS.
abstract class TdsWriterForTls {
  /// Inicia um pacote PRELOGIN.
  void beginPacket(int packetType);
  
  /// Escreve dados no buffer.
  Future<void> write(List<int> data);
  
  /// Envia o pacote.
  Future<void> flush();
  
  /// Transporte atual.
  tds.AsyncTransportProtocol get transport;
  
  /// Define o transporte.
  set transport(tds.AsyncTransportProtocol value);
}

/// Interface do reader para TLS.
abstract class TdsReaderForTls {
  /// Inicia leitura de resposta.
  Future<ResponseMetadata> beginResponse();
  
  /// Lê bytes do stream.
  Future<Uint8List> recv(int size);
  
  /// Verifica se o stream terminou.
  bool streamFinished();
  
  /// Transporte atual.
  tds.AsyncTransportProtocol get transport;
  
  /// Define o transporte.
  set transport(tds.AsyncTransportProtocol value);
}

/// Estabelece TLS usando OpenSSL FFI.
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
    ),
    sendPreloginPacket: (data) => _sendPreloginFragment(writer, data),
    receivePreloginPacket: () => _receivePreloginFragment(reader),
    onTransportChanged: session.replaceTransport,
    tlsContext: login.tlsCtx,
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
    throw tds.OperationalError(
      'Esperado pacote PRELOGIN durante o handshake TLS, '
      'mas o servidor respondeu com ${response.type}',
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
