// Measures read throughput and the latency of simple queries and parameterized RPC.
//   dart compile exe benchmark/throughput.dart -o /tmp/bench && /tmp/bench
import 'dart:io';

import 'package:mssql_dart/mssql_dart.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final conn = await MssqlConnection.connect(MssqlConnectionSettings(
    host: env['MSSQL_HOST'] ?? 'localhost',
    port: int.parse(env['MSSQL_PORT'] ?? '1433'),
    username: env['MSSQL_USER'] ?? 'dart',
    password: env['MSSQL_PASSWORD'] ?? 'dart',
    database: env['MSSQL_DATABASE'] ?? 'dart',
    encrypt: args.contains('--tls'),
    trustServerCertificate: args.contains('--tls'),
  ));

  const rowsSql = '''
    SELECT TOP (100000) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS int) AS id,
           CAST(N'nome do cliente' AS nvarchar(50)) AS nome,
           CAST(12345.67 AS decimal(12,2)) AS valor,
           SYSDATETIME() AS criado, CAST(1 AS bit) AS ativo
    FROM sys.all_objects a CROSS JOIN sys.all_objects b''';

  for (var round = 0; round < 3; round++) {
    final sw = Stopwatch()..start();
    final rows = await conn.query(rowsSql);
    sw.stop();
    print('100k rows x 5 columns: ${sw.elapsedMilliseconds} ms '
        '(${(rows.length / sw.elapsed.inMicroseconds * 1e6).round()} rows/s)');
  }

  Future<void> loop(String label, Future<void> Function(int i) body) async {
    const n = 2000;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await body(i);
    }
    sw.stop();
    print('$label: ${(n / sw.elapsed.inMicroseconds * 1e6).round()} queries/s '
        '(${(sw.elapsed.inMicroseconds / n).toStringAsFixed(0)} µs each)');
  }

  await loop('SELECT 1', (_) async {
    await conn.query('SELECT 1');
  });
  await loop('SELECT @p0 (RPC)', (i) async {
    await conn.query('SELECT @p0, @p1', parameters: [i, 'texto $i']);
  });
  await conn.close();
}
