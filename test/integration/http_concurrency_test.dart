// A real HttpServer handles simultaneous requests; each one runs a
// transaction with a savepoint, a partial rollback and, in some cases, a
// total failure. The final database state shows whether any request leaked
// into another one's transaction.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

final settings = MssqlConnectionSettings(
  host: testHost,
  port: testPort,
  username: testUser,
  password: testPassword,
  database: testDatabase,
  caFile: testCa,
  trustServerCertificate: testTrustServerCertificate,
);

const requests = 100;

/// Rows each request must leave in the database.
List<String> expectedSteps(int id) {
  if (id % 5 == 0) return const []; // request fails: all rolled back
  if (id.isEven)
    return const ['header', 'item']; // 'temp' undone by the savepoint
  return const ['header', 'temp', 'item'];
}

/// Body of a request: an order with a savepoint, as in a real backend.
Future<void> placeOrder(MssqlConnection tx, String table, int id) async {
  await tx
      .execute("INSERT INTO $table VALUES (@p0, N'header')", parameters: [id]);
  await tx.execute('SAVE TRANSACTION sp1');
  await tx
      .execute("INSERT INTO $table VALUES (@p0, N'temp')", parameters: [id]);
  // Yields on purpose so other requests try to interleave.
  await Future<void>.delayed(Duration(milliseconds: Random().nextInt(5)));
  if (id.isEven) {
    await tx.execute('ROLLBACK TRANSACTION sp1');
  }
  await tx
      .execute("INSERT INTO $table VALUES (@p0, N'item')", parameters: [id]);
  if (id % 5 == 0) {
    throw StateError('simulated failure in order $id');
  }
}

Future<HttpServer> startServer(
    Future<void> Function(int id) handleOrder) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final id = int.parse(request.uri.pathSegments.last);
    try {
      await handleOrder(id);
      request.response.statusCode = HttpStatus.ok;
      request.response.write(jsonEncode({'id': id}));
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'id': id, 'error': '$error'}));
    }
    await request.response.close();
  });
  return server;
}

/// Fires all requests at once and returns the status codes by id.
Future<Map<int, int>> fireRequests(HttpServer server) async {
  final client = HttpClient()..maxConnectionsPerHost = requests;
  try {
    final responses = await Future.wait([
      for (var id = 1; id <= requests; id++)
        () async {
          final request = await client
              .postUrl(Uri.parse('http://127.0.0.1:${server.port}/order/$id'));
          final response = await request.close();
          await response.drain<void>();
          return MapEntry(id, response.statusCode);
        }(),
    ]);
    return Map.fromEntries(responses);
  } finally {
    client.close(force: true);
  }
}

Future<void> verifyTable(
    MssqlConnection conn, String table, Map<int, int> status) async {
  for (var id = 1; id <= requests; id++) {
    expect(status[id], id % 5 == 0 ? 500 : 200, reason: 'status of order $id');
  }
  final rows = await conn.query('SELECT request_id, step FROM $table');
  final byId = <int, List<String>>{};
  for (final row in rows) {
    byId.putIfAbsent(row[0] as int, () => []).add(row[1] as String);
  }
  for (var id = 1; id <= requests; id++) {
    final expected = expectedSteps(id);
    expect([...?byId[id]]..sort(), [...expected]..sort(),
        reason: 'rows of order $id');
  }
  expect(rows.length,
      [for (var id = 1; id <= requests; id++) ...expectedSteps(id)].length);
}

void main() {
  late MssqlConnection admin;
  late String table;

  setUp(() async {
    admin = await MssqlConnection.connect(settings);
    // Real table (not #temp): the pool uses several connections.
    table = 'dbo.http_concurrency_${DateTime.now().microsecondsSinceEpoch}';
    await admin.execute(
        'CREATE TABLE $table (request_id int NOT NULL, step nvarchar(20) NOT NULL)');
  });

  tearDown(() async {
    await admin.execute('DROP TABLE IF EXISTS $table');
    await admin.close();
  });

  test('HttpServer with a pool: transactions with savepoints do not mix',
      () async {
    final pool = MssqlPool(settings, maxConnections: 8);
    final server = await startServer(
        (id) => pool.transaction((tx) => placeOrder(tx, table, id)));
    try {
      final status = await fireRequests(server);
      await verifyTable(admin, table, status);
      expect(pool.inUseConnections, 0);
      expect(pool.totalConnections, lessThanOrEqualTo(8));
    } finally {
      await server.close(force: true);
      await pool.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('HttpServer with a single shared connection: transaction() serializes',
      () async {
    final shared = await MssqlConnection.connect(settings);
    final server = await startServer(
        (id) => shared.transaction((tx) => placeOrder(tx, table, id)));
    try {
      final status = await fireRequests(server);
      await verifyTable(admin, table, status);
      expect(shared.hasOpenTransaction, isFalse);
      expect((await shared.query('SELECT @@TRANCOUNT')).single[0], 0);
    } finally {
      await server.close(force: true);
      await shared.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
