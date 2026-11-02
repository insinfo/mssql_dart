// A real REST API (dart:io HttpServer + MssqlPool) exercised like a
// production backend: CRUD, pagination, JSON, streaming, timeouts, concurrent
// load, connections killed mid-load and graceful shutdown.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

final _baseSettings = MssqlConnectionSettings(
  host: testHost,
  port: testPort,
  username: testUser,
  password: testPassword,
  database: testDatabase,
  caFile: testCa,
  trustServerCertificate: testTrustServerCertificate,
);

/// The application: REST routes over a products table.
class ProductApi {
  ProductApi(this.pool, this.table);

  final MssqlPool pool;
  final String table;
  late final HttpServer server;
  final _inFlight = <Future<void>>{};

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    // High backlog, as in a real server: the macOS default (128) refuses
    // connections during a burst of hundreds of requests.
    server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, backlog: 1024);
    server.listen((request) {
      final done = _handle(request);
      _inFlight.add(done);
      done.whenComplete(() => _inFlight.remove(done));
    });
  }

  /// Stops accepting requests, waits for in-flight ones and closes the pool.
  Future<void> shutdown() async {
    await server.close();
    await Future.wait(_inFlight.toList());
    await pool.close(timeout: const Duration(seconds: 10));
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final segments = request.uri.pathSegments;
    try {
      if (segments.length == 1 && segments[0] == 'products') {
        if (request.method == 'GET') return await _list(request);
        if (request.method == 'POST') return await _create(request);
      }
      if (segments.length == 2 && segments[0] == 'products') {
        if (segments[1] == 'export') return await _export(request);
        if (segments[1] == 'slow') return await _slow(request);
        final id = int.tryParse(segments[1]);
        if (id == null) return _json(res, 400, {'error': 'invalid id'});
        if (request.method == 'GET') return await _get(res, id);
        if (request.method == 'PUT') return await _update(request, id);
        if (request.method == 'DELETE') return await _delete(res, id);
      }
      _json(res, 404, {'error': 'not found'});
    } on IntegrityException catch (e) {
      _json(res, 409, {'error': 'conflict', 'number': e.number});
    } on MssqlTimeoutException {
      _json(res, 504, {'error': 'database timeout'});
    } on InterfaceException catch (e) {
      // Pool closed or connection lost.
      _json(res, 503, {'error': '$e'});
    } catch (e) {
      _json(res, 500, {'error': '$e'});
    } finally {
      await res.close().catchError((_) {});
    }
  }

  void _json(HttpResponse res, int status, Object? body) {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  Future<void> _list(HttpRequest request) async {
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
    final size = int.tryParse(request.uri.queryParameters['size'] ?? '') ?? 20;
    final q = request.uri.queryParameters['q'];
    final filter = {'like': q == null ? null : '%$q%'};
    final total = await pool.queryScalar<int>(
        'SELECT COUNT(*) FROM $table WHERE @like IS NULL OR name LIKE @like',
        parameters: filter);
    final items = await pool.query('''
        SELECT id, sku, name, price, created_at FROM $table
        WHERE @like IS NULL OR name LIKE @like
        ORDER BY id OFFSET @offset ROWS FETCH NEXT @size ROWS ONLY''',
        parameters: {...filter, 'offset': (page - 1) * size, 'size': size});
    _json(request.response, 200,
        {'total': total, 'page': page, 'items': items.toJson()});
  }

  Future<void> _get(HttpResponse res, int id) async {
    final row = await pool.queryFirst(
        'SELECT id, sku, name, price, created_at FROM $table WHERE id = @p0',
        parameters: [id]);
    row == null
        ? _json(res, 404, {'error': 'not found'})
        : _json(res, 200, row.toJson());
  }

  Future<void> _create(HttpRequest request) async {
    final body = jsonDecode(await utf8.decodeStream(request)) as Map;
    final id = await pool.queryScalar<int>(
        'INSERT INTO $table (sku, name, price) OUTPUT INSERTED.id '
        'VALUES (@sku, @name, @price)',
        parameters: {
          'sku': body['sku'],
          'name': body['name'],
          'price': DecimalValue.parse('${body['price']}'),
        });
    request.response.headers.set('location', '/products/$id');
    _json(request.response, 201, {'id': id});
  }

  Future<void> _update(HttpRequest request, int id) async {
    final body = jsonDecode(await utf8.decodeStream(request)) as Map;
    final affected = await pool.execute(
        'UPDATE $table SET name = @name, price = @price WHERE id = @id',
        parameters: {
          'id': id,
          'name': body['name'],
          'price': DecimalValue.parse('${body['price']}'),
        });
    affected == 0
        ? _json(request.response, 404, {'error': 'not found'})
        : request.response.statusCode = 204;
  }

  Future<void> _delete(HttpResponse res, int id) async {
    final affected = await pool
        .execute('DELETE FROM $table WHERE id = @p0', parameters: [id]);
    affected == 0
        ? _json(res, 404, {'error': 'not found'})
        : res.statusCode = 204;
  }

  /// NDJSON with backpressure: reads from the database only what the client consumes.
  Future<void> _export(HttpRequest request) async {
    final res = request.response
      ..headers.contentType = ContentType('application', 'x-ndjson');
    await res.addStream(pool
        .stream(
            'SELECT id, sku, name, price, created_at FROM $table ORDER BY id')
        .map((row) => utf8.encode('${jsonEncode(row.toJson())}\n')));
  }

  Future<void> _slow(HttpRequest request) async {
    final seconds = request.uri.queryParameters['seconds'] ?? '5';
    final timeoutMs =
        int.tryParse(request.uri.queryParameters['timeoutMs'] ?? '') ?? 300;
    await pool.execute("WAITFOR DELAY '00:00:0$seconds'",
        timeout: Duration(milliseconds: timeoutMs));
    _json(request.response, 200, {'ok': true});
  }
}

void main() {
  late MssqlConnection admin;
  late String table;
  late String appName;
  late ProductApi api;
  late HttpClient client;

  Future<(int, Object?)> call(String method, String path,
      [Object? body]) async {
    final request = await client.openUrl(method, api.uri(path));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  setUp(() async {
    admin = await MssqlConnection.connect(_baseSettings);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    table = 'dbo.rest_products_$suffix';
    appName = 'rest_api_test_$suffix';
    await admin.execute('''
      CREATE TABLE $table (
        id int IDENTITY PRIMARY KEY,
        sku nvarchar(40) NOT NULL UNIQUE,
        name nvarchar(200) NOT NULL,
        price decimal(10, 2) NOT NULL,
        created_at datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME())''');
    await admin.executeMany(
        'INSERT INTO $table (sku, name, price) VALUES (@p0, @p1, @p2)', [
      for (var i = 1; i <= 500; i++)
        [
          'SKU-$i',
          i.isEven ? 'Caneta azul $i' : 'Caderno $i',
          DecimalValue.parse('$i.99')
        ],
    ]);
    api = ProductApi(
        MssqlPool(_baseSettings.copyWith(applicationName: appName),
            maxConnections: 10),
        table);
    await api.start();
    client = HttpClient()..maxConnectionsPerHost = 64;
  });

  tearDown(() async {
    client.close(force: true);
    if (!api.pool.isClosed) await api.shutdown();
    await admin.execute('DROP TABLE IF EXISTS $table');
    await admin.close();
  });

  test(
      'full CRUD with correct HTTP status codes and JSON straight from the result',
      () async {
    var (status, body) = await call('POST', '/products',
        {'sku': 'NOVO-1', 'name': 'Lápis 2B', 'price': '3.50'});
    expect(status, 201);
    final id = (body as Map)['id'] as int;

    (status, body) = await call('GET', '/products/$id');
    expect(status, 200);
    expect(body, containsPair('name', 'Lápis 2B'));
    expect((body as Map)['price'], '3.50'); // decimal as text, lossless
    expect(DateTime.parse(body['created_at'] as String).isUtc, isTrue);

    (status, body) = await call('POST', '/products',
        {'sku': 'NOVO-1', 'name': 'duplicado', 'price': '1'});
    expect(status, 409);
    expect((body as Map)['number'], anyOf(2627, 2601)); // unique key

    (status, _) = await call(
        'PUT', '/products/$id', {'name': 'Lápis HB', 'price': '4.10'});
    expect(status, 204);
    (status, body) = await call('GET', '/products/$id');
    expect((body as Map)['price'], '4.10');

    (status, _) = await call('DELETE', '/products/$id');
    expect(status, 204);
    (status, _) = await call('GET', '/products/$id');
    expect(status, 404);
    (status, _) = await call('DELETE', '/products/$id');
    expect(status, 404);
  });

  test('parameterized pagination and filtering (no SQL injection)', () async {
    var (status, body) = await call('GET', '/products?page=3&size=50');
    expect(status, 200);
    final page = body as Map;
    expect(page['total'], 500);
    final items = page['items'] as List;
    expect(items, hasLength(50));
    expect((items.first as Map)['id'], 101);

    (status, body) = await call('GET', '/products?q=Caneta&size=1000');
    expect((body as Map)['total'], 250);

    final evil = Uri.encodeQueryComponent("x'; DROP TABLE $table; --");
    (status, body) = await call('GET', '/products?q=$evil');
    expect(status, 200);
    expect((body as Map)['total'], 0);
    expect(await admin.queryScalar<int>('SELECT COUNT(*) FROM $table'), 500);
  });

  test('streaming NDJSON export and a client that gives up midway', () async {
    final request = await client.getUrl(api.uri('/products/export'));
    final response = await request.close();
    final lines = await response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    expect(lines, hasLength(500));
    expect(jsonDecode(lines.last), containsPair('sku', 'SKU-500'));

    // The client reads a few lines and drops the HTTP connection.
    final socket = await Socket.connect('127.0.0.1', api.server.port);
    socket.write('GET /products/export HTTP/1.1\r\nHost: x\r\n\r\n');
    await socket.first;
    socket.destroy();

    // The database connection returns to the pool and the server keeps serving.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (api.pool.inUseConnections > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(api.pool.inUseConnections, 0);
    final (status, _) = await call('GET', '/products/1');
    expect(status, 200);
  });

  test('a slow query becomes 504 and the connection stays usable', () async {
    final pool = MssqlPool(_baseSettings, maxConnections: 1);
    addTearDown(pool.close);
    final slowApi = ProductApi(pool, table);
    await slowApi.start();
    addTearDown(() => slowApi.server.close(force: true));
    final sw = Stopwatch()..start();
    final request = await client
        .getUrl(slowApi.uri('/products/slow?seconds=5&timeoutMs=300'));
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 504);
    expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
    // The pool's only connection: had it been stuck, this would hang.
    expect(await pool.queryScalar<int>('SELECT COUNT(*) FROM $table'), 500);
    expect(pool.totalConnections, 1);
  });

  test('concurrent mixed load: consistent reads and writes', () async {
    final rng = Random(7);
    final latencies = <int>[];
    final created = <int>[];
    var conflicts = 0;
    Future<void> one(int i) async {
      final sw = Stopwatch()..start();
      switch (i % 5) {
        case 0:
          final (s, b) = await call('POST', '/products', {
            'sku': 'LOAD-${(i ~/ 5) % 40}',
            'name': 'Carga $i',
            'price': '9.90'
          });
          if (s == 201) {
            created.add((b as Map)['id'] as int);
          } else {
            expect(s, 409);
            conflicts++;
          }
        case 1:
          final (s, _) = await call(
              'GET', '/products?page=${1 + rng.nextInt(10)}&size=25');
          expect(s, 200);
        case 2:
          final id = 1 + rng.nextInt(500);
          final (s, _) = await call(
              'PUT', '/products/$id', {'name': 'Upd $i', 'price': '1.00'});
          expect(s, 204);
        default:
          final (s, _) = await call('GET', '/products/${1 + rng.nextInt(500)}');
          expect(s, 200);
      }
      latencies.add(sw.elapsedMilliseconds);
    }

    await Future.wait([for (var i = 0; i < 300; i++) one(i)]);
    latencies.sort();
    print('300 requests: p50=${latencies[150]} ms, '
        'p95=${latencies[285]} ms, max=${latencies.last} ms');
    // 60 POSTs with 40 distinct SKUs: exactly 40 created, 20 conflicts.
    expect(created, hasLength(40));
    expect(conflicts, 20);
    expect(await admin.queryScalar<int>('SELECT COUNT(*) FROM $table'), 540);
    expect(api.pool.totalConnections, lessThanOrEqualTo(10));
    expect(api.pool.inUseConnections, 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('connections killed on the server (KILL) mid-load: the pool recovers',
      () async {
    final statuses = <int>[];
    var stop = false;
    Future<void> worker() async {
      final rng = Random();
      while (!stop) {
        final (s, _) = await call('GET', '/products/${1 + rng.nextInt(500)}');
        statuses.add(s);
      }
    }

    final workers = [for (var i = 0; i < 20; i++) worker()];
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final killed = await admin.query(
        'SELECT session_id FROM sys.dm_exec_sessions WHERE program_name = @p0',
        parameters: [appName]);
    expect(killed, isNotEmpty);
    for (final row in killed) {
      await admin.execute('KILL ${row[0] as int}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final beforeStop = statuses.length;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    stop = true;
    await Future.wait(workers);

    final afterKill = statuses.sublist(beforeStop);
    final failed = statuses.where((s) => s != 200).length;
    print('${statuses.length} requests, ${killed.length} sessions killed, '
        '$failed failed during the KILL');
    // Once the KILL is over, everything answers 200 again.
    expect(afterKill, isNotEmpty);
    expect(afterKill.every((s) => s == 200), isTrue, reason: '$afterKill');
    // Only requests that were on a killed connection may have failed.
    expect(failed, lessThanOrEqualTo(killed.length));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('graceful shutdown: in-flight requests finish', () async {
    final slow = [
      for (var i = 0; i < 5; i++)
        call('GET', '/products/slow?seconds=1&timeoutMs=10000'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await api.shutdown();
    final results = await Future.wait(slow);
    expect(results.map((r) => r.$1), everyElement(200));
    expect(api.pool.isClosed, isTrue);
    expect(api.pool.totalConnections, 0);
  });
}
