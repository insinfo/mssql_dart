import 'package:mssql_dart/src/connect.dart';
import 'package:mssql_dart/src/tds_base.dart' as tds;
import 'package:test/test.dart';

void main() {
  group('buildLoginForTesting', () {
    test('defaults to no encryption when TLS data is missing', () {
      final login = buildLoginForTesting(
        host: 'localhost',
        user: 'user',
        password: 'pass',
      );

      expect(login.encFlag, tds.PreLoginEnc.ENCRYPT_NOT_SUP);
      expect(login.encLoginOnly, isFalse);
      expect(login.cafile, isNull);
      expect(login.tlsCtx, isNull);
    });

    test('enables TLS when cafile is provided', () {
      final login = buildLoginForTesting(
        host: 'host',
        user: 'user',
        password: 'pass',
        cafile: 'certs/root.pem',
        validateHost: false,
      );

      expect(login.encFlag, tds.PreLoginEnc.ENCRYPT_ON);
      expect(login.encLoginOnly, isFalse);
      expect(login.cafile, equals('certs/root.pem'));
      expect(login.validateHost, isFalse);
    });

    test('supports login-only encryption semantics', () {
      final login = buildLoginForTesting(
        host: 'host',
        user: 'user',
        password: 'pass',
        cafile: 'certs/root.pem',
        encLoginOnly: true,
      );

      expect(login.encFlag, tds.PreLoginEnc.ENCRYPT_OFF);
      expect(login.encLoginOnly, isTrue);
    });

    test('throws when login-only encryption is requested without TLS data', () {
      expect(
        () => buildLoginForTesting(
          host: 'host',
          user: 'user',
          password: 'pass',
          encLoginOnly: true,
        ),
        throwsArgumentError,
      );
    });
  });
}
