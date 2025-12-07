import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_dart/src/async_tds_session.dart';
import 'package:mssql_dart/src/session_link.dart';
import 'package:mssql_dart/src/tds_base.dart' as tds;
import 'package:mssql_dart/src/tds_types.dart';
import 'package:mssql_dart/src/transport_tls.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncTdsSession TLS negotiation', () {
    test('não faz nada quando transporte já está seguro', () async {
      final transport = _FakeTlsTransport(isSecure: true);
      final session = _buildSession(transport);
      final login = _buildLogin(encFlag: tds.PreLoginEnc.ENCRYPT_REQ);

      await session.debugHandleEncryptionNegotiation(
        login,
        tds.PreLoginEnc.ENCRYPT_ON,
      );
    });

    test('lança erro quando servidor exige TLS mas transporte é plaintext', () async {
      final transport = _FakeTlsTransport(isSecure: false);
      final session = _buildSession(transport);
      final login = _buildLogin(encFlag: tds.PreLoginEnc.ENCRYPT_OFF);

      expect(
        () => session.debugHandleEncryptionNegotiation(
          login,
          tds.PreLoginEnc.ENCRYPT_ON,
        ),
        throwsA(isA<tds.OperationalError>()),
      );
    });

    test('plaintext segue permitido quando servidor responde ENCRYPT_OFF', () async {
      final transport = _FakeTlsTransport(isSecure: false);
      final session = _buildSession(transport);
      final login = _buildLogin(encFlag: tds.PreLoginEnc.ENCRYPT_OFF);

      await session.debugHandleEncryptionNegotiation(
        login,
        tds.PreLoginEnc.ENCRYPT_OFF,
      );
    });
  });
}

AsyncTdsSession _buildSession(tds.AsyncTransportProtocol transport) {
  final context = AsyncSessionBuildContext(
    transport: transport,
    bufsize: 512,
    env: tds.TdsEnv(),
    typeFactory: SerializerFactory(tds.TDS74),
  );
  return AsyncTdsSession.fromContext(context);
}

tds.TdsLogin _buildLogin({required int encFlag}) {
  final login = tds.TdsLogin()
    ..serverName = ''
    ..encFlag = encFlag
    ..validateHost = true;
  return login;
}

class _FakeTlsTransport implements tds.AsyncTransportProtocol, AsyncTlsTransport {
  _FakeTlsTransport({this.isSecure = false});

  @override
  bool get isConnected => true;

  @override
  Duration? timeout;

  @override
  Future<void> close() async {}

  @override
  Future<Uint8List> recv(int size) {
    throw UnimplementedError('recv não deve ser chamado nos testes');
  }

  @override
  Future<Uint8List> recvAvailable(int maxSize) {
    throw UnimplementedError('recvAvailable não deve ser chamado nos testes');
  }

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) {
    throw UnimplementedError('recvInto não deve ser chamado nos testes');
  }

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) {
    throw UnimplementedError('sendAll não deve ser chamado nos testes');
  }

  @override
  String? remoteHost;

  @override
  final bool isSecure;

  @override
  Future<void> upgradeToSecureSocket({
    required SecurityContext context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    String? host,
    bool loginOnly = false,
  }) async {
    throw UnimplementedError('upgradeToSecureSocket não deve ser usado nos testes');
  }
}
