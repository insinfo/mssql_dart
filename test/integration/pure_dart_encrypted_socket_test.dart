/// Testes específicos para o backend `PureDartEncryptedSocket`.
///
/// Estes cenários exercitam o handshake TLS mid-stream realizado pela
/// implementação pura em Dart (tlslite) utilizada pelo driver.
import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

/// Recupera valores de uma linha retornada pelo driver, seja ela baseada
/// em `Map<String, dynamic>` ou em listas posicionais.
dynamic _field(dynamic row, {String? name, int? index}) {
  if (row is Map<String, dynamic>) {
    if (name == null) {
      throw ArgumentError('name é obrigatório para linhas baseadas em Map');
    }
    return row[name];
  }
  final listRow = row as List;
  final resolvedIndex = index ?? 0;
  return listRow[resolvedIndex];
}

void main() {
  const host = 'localhost';
  const port = 1433;
  const database = 'dart';
  const user = 'dart';
  const password = 'dart';

  group('Pure Dart TLS mid-stream', () {
    test('connectAsync executa handshake e SELECT simples', () async {
      final socket = await connectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
        tlsBackend: TlsBackend.tlslite,
      );
      addTearDown(() => socket.close());

      expect(socket.isConnected, isTrue);
      expect(socket.env.database?.toLowerCase(), equals(database));

      await socket.runSerial((session) async {
        await session.submitPlainQuery('SELECT DB_NAME() AS current_db');
        await session.processSimpleRequest();
      });

      expect(socket.hasBufferedRows, isTrue);
      final row = socket.takeRow();
      expect(row, isNotNull);
      final currentDb = row is Map<String, dynamic>
          ? row['current_db']
          : (row as List).first;
      expect(currentDb.toString().toLowerCase(), equals(database));
    });

    test('dbConnectAsync com backend Pure Dart', () async {
      final conn = await dbConnectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
        tlsBackend: TlsBackend.tlslite,
      );
      addTearDown(() => conn.close());

      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      await cursor.execute('SELECT 42 AS answer');
      final rows = await cursor.fetchall();

      expect(rows, hasLength(1));
      final answer = _field(rows.first, name: 'answer', index: 0);
      expect(answer, equals(42));
    });

    test('transação completa usando Pure Dart TLS', () async {
      final conn = await dbConnectAsync(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
        encrypt: true,
        validateHost: false,
        tlsBackend: TlsBackend.tlslite,
      );
      addTearDown(() => conn.close());

      final cursor = conn.cursor();
      addTearDown(() => cursor.close());

      await cursor.execute('''
        CREATE TABLE #tls_pure_dart (
          id INT PRIMARY KEY,
          value NVARCHAR(100)
        )
      ''');

      await cursor.execute('BEGIN TRANSACTION');
      await cursor.execute("INSERT INTO #tls_pure_dart VALUES (1, 'pure dart tls')");
      await cursor.execute('COMMIT');

      await cursor.execute('SELECT * FROM #tls_pure_dart');
      final rows = await cursor.fetchall();

      expect(rows, hasLength(1));
      final firstRow = rows.first;
      final id = _field(firstRow, name: 'id', index: 0);
      final value = _field(firstRow, name: 'value', index: 1);
      expect(id, equals(1));
      expect(value, equals('pure dart tls'));
    });
  });
}
