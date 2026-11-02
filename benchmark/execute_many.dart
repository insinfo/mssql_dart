// Measures executeMany: inserts 5,000 rows into a temporary table.
//   dart run benchmark/execute_many.dart [--tls]
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
  await conn.execute(
      'CREATE TABLE #bench (id int, nome nvarchar(50), valor float, criado datetime2)');
  const n = 5000;
  final rows = [
    for (var i = 0; i < n; i++)
      [
        i,
        'nome $i',
        i * 1.5,
        DateTime.utc(2024, 1, 1).add(Duration(minutes: i))
      ]
  ];
  for (var round = 0; round < 3; round++) {
    await conn.execute('TRUNCATE TABLE #bench');
    final sw = Stopwatch()..start();
    final count = await conn.executeMany(
        'INSERT INTO #bench (id, nome, valor, criado) VALUES (@p0, @p1, @p2, @p3)',
        rows);
    sw.stop();
    print('executeMany $n rows: ${sw.elapsedMilliseconds} ms '
        '($count affected, ${(n / sw.elapsed.inMicroseconds * 1e6).round()} rows/s)');
  }
  await conn.close();
}
