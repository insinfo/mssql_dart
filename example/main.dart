// Run against a local server, e.g. the official Docker image:
//   docker run -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='Your_password1' \
//     -p 1433:1433 mcr.microsoft.com/mssql/server:2022-latest
//   MSSQL_PASSWORD='Your_password1' dart run example/main.dart
import 'dart:io';

import 'package:mssql_dart/mssql_dart.dart';

Future<void> main() async {
  final settings = MssqlConnectionSettings(
    host: Platform.environment['MSSQL_HOST'] ?? 'localhost',
    username: Platform.environment['MSSQL_USER'] ?? 'sa',
    password: Platform.environment['MSSQL_PASSWORD'] ?? 'Your_password1',
    database: 'master',
    // The Docker image uses a self-signed certificate. In production point
    // caFile at your CA instead, so the server is authenticated too.
    trustServerCertificate: true,
  );

  final conn = await MssqlConnection.connect(settings);
  try {
    await conn.execute('''
      CREATE TABLE #books (
        id int IDENTITY PRIMARY KEY,
        title nvarchar(200) NOT NULL,
        price decimal(10, 2),
        published date
      )''');

    // Parameters travel as binary RPC values, never inside the SQL text.
    await conn.executeMany(
      'INSERT INTO #books (title, price, published) VALUES (@p0, @p1, @p2)',
      [
        ['Dart in Action', DecimalValue.parse('39.90'), DateTime(2024, 3, 1)],
        [
          'SQL Server Internals',
          DecimalValue.parse('59.00'),
          DateTime(2023, 9, 15)
        ],
      ],
    );

    // Named parameters, or `?` placeholders like JDBC/PDO.
    final cheap = await conn.query(
      'SELECT id, title, price FROM #books WHERE price < @max ORDER BY price',
      parameters: {'max': 50},
    );
    for (final row in cheap) {
      print('${row['id']}: ${row['title']} (${row['price']})');
    }

    final byTitle = await conn.query(
      'SELECT published FROM #books WHERE title = ?',
      parameters: ['SQL Server Internals'],
      placeholder: PlaceholderIdentifier.onlyQuestionMark,
    );
    print('published: ${byTitle.first[0]}');

    // COMMIT on success, ROLLBACK if the callback throws.
    await conn.transaction((tx) async {
      await tx.execute('UPDATE #books SET price = price * 0.9');
      await tx
          .execute('DELETE FROM #books WHERE price > @p0', parameters: [100]);
    });

    // Large results can be streamed row by row.
    await for (final row in conn.stream('SELECT title FROM #books')) {
      print(row[0]);
    }
  } on DatabaseException catch (e) {
    print('SQL Server error ${e.number}: ${e.message}');
  } finally {
    await conn.close();
  }
}
