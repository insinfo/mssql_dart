import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

MssqlConnectionSettings parse(String text) =>
    MssqlConnectionSettings.parse(text);

void main() {
  group('ADO.NET/ODBC', () {
    test('basic fields and defaults', () {
      final s = parse('Server=db.example.com;Database=app;User Id=u;'
          'Password=p');
      expect(s.host, 'db.example.com');
      expect(s.port, isNull);
      expect(s.instanceName, isNull);
      expect(s.database, 'app');
      expect(s.username, 'u');
      expect(s.password, 'p');
      expect(s.encrypt, isTrue);
      expect(s.trustServerCertificate, isFalse);
      expect(s.applicationName, 'mssql_dart');
      expect(s.connectTimeout, const Duration(seconds: 15));
      expect(s.readOnlyIntent, isFalse);
    });

    test('tcp:, port after a comma, and options', () {
      final s = parse('Server=tcp:10.0.0.5,14330;Initial Catalog=vendas;'
          'UID=sa;PWD=x;Encrypt=false;TrustServerCertificate=true;'
          'Connect Timeout=30;Application Name=minha api');
      expect(s.host, '10.0.0.5');
      expect(s.port, 14330);
      expect(s.database, 'vendas');
      expect(s.username, 'sa');
      expect(s.password, 'x');
      expect(s.encrypt, isFalse);
      expect(s.trustServerCertificate, isTrue);
      expect(s.connectTimeout, const Duration(seconds: 30));
      expect(s.applicationName, 'minha api');
    });

    test('server synonyms and case-insensitive keys', () {
      for (final key in [
        'Data Source',
        'DATA SOURCE',
        'datasource',
        'Address',
        'Addr',
        'Network Address',
        'server'
      ]) {
        final s = parse('$key=h1;user id=u;password=p');
        expect(s.host, 'h1', reason: key);
      }
      expect(parse('Server=h;USER=u;Pwd=p').username, 'u');
      expect(parse('Server=h;UserName=u;Pwd=p').username, 'u');
    });

    test('named instance, with and without a port', () {
      final a = parse(r'Server=srv01\SQLEXPRESS;User Id=u;Password=p');
      expect(a.host, 'srv01');
      expect(a.instanceName, 'SQLEXPRESS');
      expect(a.port, isNull);
      final b = parse(r'Data Source=tcp:srv01\SQLEXPRESS,1500;UID=u;PWD=p');
      expect(b.host, 'srv01');
      expect(b.instanceName, 'SQLEXPRESS');
      expect(b.port, 1500);
      final c = parse('Server=srv01;Instance Name=INST2;UID=u;PWD=p');
      expect(c.instanceName, 'INST2');
    });

    test('(local), "." and bracketed IPv6', () {
      expect(parse('Server=(local);UID=u;PWD=p').host, 'localhost');
      expect(parse(r'Server=.\SQLEXPRESS;UID=u;PWD=p').host, 'localhost');
      final v6 = parse('Server=[::1],1444;UID=u;PWD=p');
      expect(v6.host, '::1');
      expect(v6.port, 1444);
    });

    test('host:port is accepted', () {
      final s = parse('Server=localhost:1435;UID=u;PWD=p');
      expect(s.host, 'localhost');
      expect(s.port, 1435);
    });

    test('explicit Port', () {
      expect(parse('Server=h;Port=2000;UID=u;PWD=p').port, 2000);
    });

    test('quoted and braced values with ; and escapes', () {
      final a = parse('Server=h;UID=u;Password="a;b""c"');
      expect(a.password, 'a;b"c');
      final b = parse("Server=h;UID=u;Password='x;''y'");
      expect(b.password, "x;'y");
      final c = parse('Server=h;UID=u;PWD={p;}}w=d}');
      expect(c.password, 'p;}w=d');
      final d = parse('Server=h;UID=u;Password=a=b');
      expect(d.password, 'a=b');
    });

    test('whitespace, extra ; and repeated key (last one wins)', () {
      final s = parse('  Server = h ; ; UID = u ;PWD= p ;Database=a;'
          'Database=b;;');
      expect(s.host, 'h');
      expect(s.username, 'u');
      expect(s.password, 'p');
      expect(s.database, 'b');
    });

    test('Encrypt accepts synonyms and rejects Strict', () {
      expect(parse('Server=h;UID=u;Encrypt=yes').encrypt, isTrue);
      expect(parse('Server=h;UID=u;Encrypt=Mandatory').encrypt, isTrue);
      expect(parse('Server=h;UID=u;Encrypt=Optional').encrypt, isFalse);
      expect(parse('Server=h;UID=u;Encrypt=no').encrypt, isFalse);
      expect(
          () => parse('Server=h;UID=u;Encrypt=Strict'),
          throwsA(isFormatException.having(
              (e) => e.message, 'message', contains('Strict'))));
      expect(
          () => parse('Server=h;UID=u;Encrypt=talvez'), throwsFormatException);
    });

    test('ApplicationIntent, KeepAlive, CAFile and ValidateHostName', () {
      final s = parse('Server=h;UID=u;ApplicationIntent=ReadOnly;'
          'KeepAlive=0;CAFile=/etc/ca.pem;ValidateHostName=false');
      expect(s.readOnlyIntent, isTrue);
      expect(s.keepAlive, Duration.zero);
      expect(s.caFile, '/etc/ca.pem');
      expect(s.validateHostName, isFalse);
      expect(
          parse('Server=h;UID=u;Application Intent=ReadWrite').readOnlyIntent,
          isFalse);
    });

    test('pool keys and keys from other drivers are ignored', () {
      final s = parse('Driver={ODBC Driver 18 for SQL Server};Server=h;UID=u;'
          'PWD=p;Pooling=true;Max Pool Size=100;Min Pool Size=1;'
          'MultipleActiveResultSets=false;Packet Size=8192;'
          'Persist Security Info=False;MultiSubnetFailover=True;'
          'Integrated Security=false;Authentication=SqlPassword');
      expect(s.host, 'h');
    });

    test('unknown keys are listed', () {
      expect(
        () => parse('Server=h;UID=u;Foo=1;Bar Baz=2'),
        throwsA(isFormatException.having((e) => e.message, 'message',
            allOf(contains('Foo'), contains('Bar Baz')))),
      );
    });

    test('unsupported features', () {
      expect(() => parse('Server=h;UID=u;MultipleActiveResultSets=True'),
          throwsFormatException);
      expect(() => parse('Server=h;Integrated Security=SSPI'),
          throwsFormatException);
      expect(() => parse('Server=h;UID=u;Trusted_Connection=yes'),
          throwsFormatException);
      expect(
          () => parse('Server=h;UID=u;Authentication=ActiveDirectoryPassword'),
          throwsFormatException);
      expect(() => parse('Server=np:\\\\h\\pipe\\sql\\query;UID=u'),
          throwsFormatException);
    });

    test('syntax errors and required fields', () {
      expect(() => parse(''), throwsFormatException);
      expect(() => parse('Server=h;UID'), throwsFormatException);
      expect(() => parse('Server=h;UID=u;PWD="aberta'), throwsFormatException);
      expect(() => parse('Server=h;UID=u;PWD="a"b'), throwsFormatException);
      expect(() => parse('UID=u;PWD=p'), throwsFormatException);
      expect(() => parse('Server=h;PWD=p'), throwsFormatException);
      expect(() => parse('Server=h,porta;UID=u'), throwsFormatException);
      expect(() => parse('Server=h;UID=u;Connect Timeout=0'),
          throwsFormatException);
      expect(() => parse('Server=h;UID=u;Connect Timeout=abc'),
          throwsFormatException);
    });
  });

  group('URI', () {
    test('full mssql:// with percent-encoding', () {
      final s = parse('mssql://app%40corp:p%40ss%3Aw%2Fd@db.example.com:1444/'
          'vendas?encrypt=true&trustServerCertificate=true&'
          'connectTimeout=5&applicationName=api');
      expect(s.username, 'app@corp');
      expect(s.password, 'p@ss:w/d');
      expect(s.host, 'db.example.com');
      expect(s.port, 1444);
      expect(s.database, 'vendas');
      expect(s.encrypt, isTrue);
      expect(s.trustServerCertificate, isTrue);
      expect(s.connectTimeout, const Duration(seconds: 5));
      expect(s.applicationName, 'api');
    });

    test('sqlserver://, without port or database', () {
      final s = parse('sqlserver://u:p@localhost');
      expect(s.host, 'localhost');
      expect(s.port, isNull);
      expect(s.database, '');
      expect(s.password, 'p');
    });

    test('instance via parameter or %5C in the host', () {
      expect(parse('mssql://u:p@srv/db?instanceName=SQLEXPRESS').instanceName,
          'SQLEXPRESS');
      final s = parse('mssql://u:p@srv%5CSQLEXPRESS/db');
      expect(s.host, 'srv');
      expect(s.instanceName, 'SQLEXPRESS');
    });

    test('IPv6 and encrypt=false', () {
      final s = parse('mssql://u:p@[::1]:1433/db?encrypt=false');
      expect(s.host, '::1');
      expect(s.port, 1433);
      expect(s.encrypt, isFalse);
    });

    test('errors', () {
      expect(() => parse('mssql://u:p@h/db/extra'), throwsFormatException);
      expect(() => parse('mssql://u:p@h/db?foo=1'), throwsFormatException);
      expect(() => parse('mssql://h/db'), throwsFormatException);
    });
  });

  group('JDBC', () {
    test('jdbc:sqlserver:// with properties', () {
      final s = parse('jdbc:sqlserver://db.local:1450;databaseName=app;'
          'user=u;password={a;b};encrypt=true;trustServerCertificate=true;'
          'loginTimeout=7');
      expect(s.host, 'db.local');
      expect(s.port, 1450);
      expect(s.database, 'app');
      expect(s.username, 'u');
      expect(s.password, 'a;b');
      expect(s.trustServerCertificate, isTrue);
      expect(s.connectTimeout, const Duration(seconds: 7));
    });

    test('instance in the host or in instanceName', () {
      final a = parse(r'jdbc:sqlserver://srv\INST;user=u;password=p');
      expect(a.host, 'srv');
      expect(a.instanceName, 'INST');
      final b = parse(
          'jdbc:sqlserver://;serverName=srv;instanceName=X;user=u;password=p');
      expect(b.host, 'srv');
      expect(b.instanceName, 'X');
    });
  });

  test('toString hides the password', () {
    final s = parse(r'Server=srv\INST,1500;Database=db;UID=u;PWD=segredo123');
    final text = s.toString();
    expect(text, isNot(contains('segredo123')));
    expect(text, contains('***'));
    expect(text, contains(r'u@srv\INST:1500/db'));
  });

  test('copyWith keeps the new fields', () {
    final s = parse(r'Server=srv\INST;UID=u;PWD=p;ApplicationIntent=ReadOnly')
        .copyWith(password: 'q');
    expect(s.instanceName, 'INST');
    expect(s.readOnlyIntent, isTrue);
    expect(s.password, 'q');
    expect(s.port, isNull);
  });
}
