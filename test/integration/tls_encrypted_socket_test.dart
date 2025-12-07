/// Testes de integração para TLS encrypted socket.
///
/// Estes testes requerem um SQL Server rodando localmente.
/// Configuração esperada:
/// - Host: localhost
/// - Port: 1433
/// - Database: dart
/// - User: dart
/// - Password: dart
///
/// Para rodar testes TLS, o SQL Server deve estar configurado com:
/// - Certificado TLS válido
/// - Force Encryption = Yes (ou aceitar conexões encriptadas)
///
/// Os cenários TLS e sem TLS foram separados em grupos independentes para
/// facilitar a execução direcionada de acordo com o ambiente disponível.

import 'dart:io';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('TLS Connection Tests', () {
    test('connectAsync com TLS usando SecureSocket nativo (TLS-first)', () async {
      // Este teste usa o SecureSocket nativo do Dart
      // Requer que o servidor suporte TLS
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false, // localhost geralmente não tem certificado válido
      );
      addTearDown(() => socket.close());

      expect(socket.isConnected, isTrue);
      expect(socket.env.database?.toLowerCase(), equals(database));

      // Executa uma query para verificar que TLS funciona
      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT @@VERSION AS sql_version');
        await session.processSimpleRequest();
      });

      expect(socket.hasBufferedRows, isTrue);
      final row = socket.takeRow() as List<dynamic>?;
      expect(row, isNotNull);
      expect(row!.first.toString(), contains('Microsoft SQL Server'));
    });

    test('dbConnectAsync com TLS', () async {
      // Teste usando a API de alto nível dbConnectAsync
      final conn = await dbConnectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
      );
      addTearDown(() => conn.close());

      // Executa uma query usando a API de cursor
      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      await cursor.execute('SELECT 42 AS answer');
      final rows = await cursor.fetchall();

      expect(rows, hasLength(1));
      final firstRow = rows.first;
      final answer = firstRow is Map<String, dynamic>
          ? firstRow['answer']
          : (firstRow as List)[0];
      expect(answer, equals(42));
    });
  });

  group('TLS Error Handling', () {
    test('connectAsync com host inválido falha graciosamente', () async {
      expect(
        () => connectAsync(
          host: 'host-que-nao-existe.invalid',
          port: port,
          user: user,
          password: password,
          database: database,
          encrypt: true,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(
          predicate((e) =>
              e is Exception &&
              e.toString().contains('Falha ao conectar a host-que-nao-existe.invalid')),
        ),
      );
    });

    test('connectAsync com porta errada falha graciosamente', () async {
      expect(
        () => connectAsync(
          host: host,
          port: 9999, // Porta incorreta
          user: user,
          password: password,
          database: database,
          encrypt: true,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(
          predicate((e) =>
              e is Exception &&
              e.toString().contains('Falha ao conectar a localhost:9999')),
        ),
      );
    });
  });

  group('TLS with SecurityContext', () {
    test('connectAsync com SecurityContext customizado', () async {
      // Cria um SecurityContext que aceita certificados self-signed
      final context = SecurityContext(withTrustedRoots: true);
      // Em produção, você carregaria certificados específicos aqui:
      // context.setTrustedCertificates('path/to/ca.pem');

      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
        securityContext: context,
      );
      addTearDown(() => socket.close());

      expect(socket.isConnected, isTrue);

      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT 1');
        await session.processSimpleRequest();
      });

      expect(socket.hasBufferedRows, isTrue);
    });
  });

  group('Multiple TLS Queries', () {
    test('múltiplas queries em conexão TLS', () async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
      );
      addTearDown(() => socket.close());

      // Query 1
      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT 1 AS q1');
        await session.processSimpleRequest();
      });
      expect(socket.takeRow(), equals([1]));

      // Query 2
      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT 2 AS q2');
        await session.processSimpleRequest();
      });
      expect(socket.takeRow(), equals([2]));

      // Query 3 - com múltiplas linhas
      await socket.runSerial((session) async {
        await session.submitPlainQuery(
          'SELECT n FROM (VALUES (1), (2), (3)) AS t(n)',
        );
        await session.processSimpleRequest();
      });
      final rows = socket.takeAllRows();
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.first), containsAll([1, 2, 3]));
    });

    test('transação em conexão TLS', () async {
      final conn = await dbConnectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
      );
      addTearDown(() => conn.close());

      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      // Cria tabela temporária
      await cursor.execute('''
        CREATE TABLE #tls_test (
          id INT PRIMARY KEY,
          value NVARCHAR(100)
        )
      ''');

      // Insert com transação
      await cursor.execute('BEGIN TRANSACTION');
      await cursor.execute("INSERT INTO #tls_test VALUES (1, 'test TLS')");
      await cursor.execute('COMMIT');

      // Verifica
      await cursor.execute('SELECT * FROM #tls_test');
      final rows = await cursor.fetchall();

          expect(rows, hasLength(1));
          final firstRow = rows.first;
          final id = firstRow is Map<String, dynamic>
            ? firstRow['id']
            : (firstRow as List)[0];
          final value = firstRow is Map<String, dynamic>
            ? firstRow['value']
            : (firstRow as List)[1];
          expect(id, equals(1));
          expect(value, equals('test TLS'));
    });
  });
}
