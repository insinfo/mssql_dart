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

    test('enables TLS-first when encrypt=true', () {
      final login = buildLoginForTesting(
        host: 'host',
        user: 'user',
        password: 'pass',
        encrypt: true,
        validateHost: false,
      );

      expect(login.encFlag, tds.PreLoginEnc.ENCRYPT_REQ);
      expect(login.encLoginOnly, isFalse);
      expect(login.validateHost, isFalse);
    });

    test('requires encrypt=true when TLS params are provided', () {
      expect(
        () => buildLoginForTesting(
          host: 'host',
          user: 'user',
          password: 'pass',
          cafile: 'certs/root.pem',
        ),
        throwsArgumentError,
      );
    });
  });

  group('connectSync TLS guard', () {
    test('rejects encrypt=true until sync TLS is implemented', () {
      expect(
        () => connectSync(
          host: 'localhost',
          user: 'user',
          password: 'pass',
          encrypt: true,
        ),
        throwsA(isA<tds.NotSupportedError>()),
      );
    });
  });
}
