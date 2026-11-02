import 'package:mssql_dart/src/connect.dart';
import 'package:mssql_dart/src/tds_base.dart' as tds;
import 'package:test/test.dart';

void main() {
  group('buildLoginForTesting', () {
    test('encrypts by default and validates the certificate', () {
      final login = buildLoginForTesting(
          host: 'localhost', user: 'user', password: 'pass');
      expect(login.encFlag, tds.PreLoginEnc.ENCRYPT_REQ);
      expect(login.trustServerCertificate, isFalse);
      expect(login.validateHost, isTrue);
      expect(login.cafile, isNull);
    });

    test('encrypt: false does not negotiate TLS', () {
      final login = buildLoginForTesting(
          host: 'h', user: 'u', password: 'p', encrypt: false);
      expect(login.encFlag, tds.PreLoginEnc.ENCRYPT_NOT_SUP);
      expect(login.encLoginOnly, isFalse);
    });

    test('TLS options require encrypt', () {
      expect(
        () => buildLoginForTesting(
            host: 'h',
            user: 'u',
            password: 'p',
            encrypt: false,
            trustServerCertificate: true),
        throwsArgumentError,
      );
    });

    test('missing cafile fails early', () {
      expect(
        () => buildLoginForTesting(
            host: 'h', user: 'u', password: 'p', cafile: '/nao/existe.pem'),
        throwsArgumentError,
      );
    });
  });
}
