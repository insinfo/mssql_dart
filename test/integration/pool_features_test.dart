import 'dart:async';
import 'dart:io';

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

/// Waits for [condition] to become true (or fails after [timeout]).
Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Whether [MssqlConnection] already calls `onQuery`; the pool's SET
/// detection depends on it.
Future<bool> queryHookFires() async {
  final conn = await MssqlConnection.connect(settings);
  var fired = false;
  conn.onQuery = (_) => fired = true;
  try {
    await conn.query('SELECT 1');
  } finally {
    await conn.close();
  }
  return fired;
}

void main() {
  late bool hookFires;
  setUpAll(() async => hookFires = await queryHookFires());

  void requireHook() {
    if (!hookFires) {
      markTestSkipped('MssqlConnection does not call onQuery yet');
    }
  }

  group('minConnections', () {
    test('opens the minimum connections in the background', () async {
      final pool = MssqlPool(settings, minConnections: 2, maxConnections: 4);
      addTearDown(pool.close);
      expect(pool.totalConnections, 0); // the constructor does not block
      await eventually(() => pool.idleConnections == 2);
      expect(pool.totalConnections, 2);
      expect(pool.stats.opened, 2);
      expect((await pool.query('SELECT 1')).single[0], 1);
      expect(pool.stats.opened, 2); // reused a warm connection
    });

    test('replaces a lost minimum connection', () async {
      final pool = MssqlPool(settings, minConnections: 1, maxConnections: 1);
      addTearDown(pool.close);
      await eventually(() => pool.idleConnections == 1);
      await pool.withConnection((conn) => conn.close());
      await eventually(() => pool.idleConnections == 1);
      expect(pool.stats.opened, 2);
      expect(pool.stats.closed, 1);
    });

    test('server down: does not throw and retries with growing backoff',
        () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      final pool = MssqlPool(
        MssqlConnectionSettings(
          host: '127.0.0.1',
          port: deadPort,
          username: 'x',
          password: 'y',
          encrypt: false,
        ),
        minConnections: 1,
      );
      await eventually(() => pool.stats.failedConnects >= 2,
          timeout: const Duration(seconds: 5));
      expect(pool.totalConnections, 0);
      final failures = pool.stats.failedConnects;
      // The backoff doubles: few new attempts fit into 300 ms.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(pool.stats.failedConnects, lessThanOrEqualTo(failures + 1));
      await pool.close();
    });

    test('minConnections greater than maxConnections is rejected', () {
      expect(() => MssqlPool(settings, minConnections: 3, maxConnections: 2),
          throwsArgumentError);
    });
  });

  group('callbacks', () {
    test('onConnect runs on each new connection', () async {
      var calls = 0;
      final pool =
          MssqlPool(settings, maxConnections: 2, onConnect: (conn) async {
        calls++;
        await conn.execute('SET LOCK_TIMEOUT 1234');
      });
      addTearDown(pool.close);
      expect((await pool.query('SELECT @@LOCK_TIMEOUT')).single[0], 1234);
      expect((await pool.query('SELECT @@LOCK_TIMEOUT')).single[0], 1234);
      expect(calls, 1);
    });

    test('a failure in onConnect closes the connection and reaches the caller',
        () async {
      final pool = MssqlPool(settings,
          onConnect: (_) => throw StateError('setup failed'));
      addTearDown(pool.close);
      await expectLater(pool.query('SELECT 1'), throwsStateError);
      expect(pool.totalConnections, 0);
      expect(pool.stats.failedConnects, 1);
    });

    test('onQuery is installed on the pool connections', () async {
      requireHook();
      if (!hookFires) return;
      final events = <MssqlQueryEvent>[];
      final pool = MssqlPool(settings, onQuery: events.add);
      addTearDown(pool.close);
      await pool.query('SELECT @p0 AS x', parameters: [1]);
      final other = <MssqlQueryEvent>[];
      pool.onQuery = other.add;
      await pool.query('SELECT 2');
      expect(events.map((e) => e.sql), contains(contains('SELECT @p0')));
      expect(other.map((e) => e.sql), contains('SELECT 2'));
    });
  });

  group('session reset', () {
    test('a database switch with USE is undone', () async {
      final pool = MssqlPool(settings, maxConnections: 1);
      addTearDown(pool.close);
      await pool.withConnection((conn) => conn.execute('USE master'));
      expect((await pool.query('SELECT DB_NAME()')).single[0], testDatabase);
    });

    test('session SET does not leak to the next user', () async {
      requireHook();
      if (!hookFires) return;
      final pool = MssqlPool(settings, maxConnections: 1);
      addTearDown(pool.close);
      await pool.withConnection((conn) =>
          conn.execute('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; '
              'SET LOCK_TIMEOUT 999'));
      final row = (await pool.query('SELECT @@LOCK_TIMEOUT, '
              'transaction_isolation_level FROM sys.dm_exec_sessions '
              'WHERE session_id = @@SPID'))
          .single;
      expect(row[0], -1);
      expect(row[1], 2); // READ COMMITTED
    });

    test('a connection flagged by the hook is reset or discarded', () async {
      // Simulates the event MssqlConnection delivers to the pool hook, so as
      // not to depend on which execution path fires it.
      final pool = MssqlPool(settings, maxConnections: 1);
      addTearDown(pool.close);
      await pool.withConnection((conn) async {
        const sql = 'SET LOCK_TIMEOUT 999';
        await conn.execute(sql);
        conn.onQuery!(const MssqlQueryEvent(
            sql: sql, parameters: null, elapsed: Duration.zero));
      });
      expect((await pool.query('SELECT @@LOCK_TIMEOUT')).single[0], -1);
      expect(pool.stats.closed + pool.stats.resets, 1);
    });

    test('resetSessionState: false keeps the connection as is', () async {
      final pool =
          MssqlPool(settings, maxConnections: 1, resetSessionState: false);
      addTearDown(pool.close);
      await pool.withConnection((conn) => conn.execute('SET LOCK_TIMEOUT 999'));
      expect((await pool.query('SELECT @@LOCK_TIMEOUT')).single[0], 999);
      expect(pool.stats.closed, 0);
    });
  });

  group('close', () {
    test('waits for in-use connections to be returned', () async {
      final pool = MssqlPool(settings, maxConnections: 2);
      final hold = Completer<void>();
      final acquired = Completer<MssqlConnection>();
      final busy = pool.withConnection((conn) async {
        acquired.complete(conn);
        await hold.future;
        return conn.query('SELECT 1');
      });
      final conn = await acquired.future;
      var closed = false;
      final closing = pool.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(closed, isFalse);
      expect(pool.inUseConnections, 1);
      await expectLater(pool.query('SELECT 1'),
          throwsA(isA<InterfaceException>())); // rejects new ones
      hold.complete();
      expect((await busy).single[0], 1); // the ongoing operation finishes
      await closing;
      expect(pool.totalConnections, 0);
      expect(conn.isOpen, isFalse);
    });

    test('with a timeout, force-closes those not returned', () async {
      final pool = MssqlPool(settings);
      final acquired = Completer<MssqlConnection>();
      final never = Completer<void>();
      unawaited(pool.withConnection((conn) async {
        acquired.complete(conn);
        await never.future;
      }));
      final conn = await acquired.future;
      final watch = Stopwatch()..start();
      await pool.close(timeout: const Duration(milliseconds: 200));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(conn.isOpen, isFalse);
      expect(pool.totalConnections, 0);
      expect(pool.inUseConnections, 0);
    });
  });

  test('statistics', () async {
    final pool = MssqlPool(settings,
        maxConnections: 2, acquireTimeout: const Duration(milliseconds: 150));
    addTearDown(pool.close);
    await Future.wait([
      for (var i = 0; i < 6; i++)
        pool.query("WAITFOR DELAY '00:00:00.02'; SELECT @p0", parameters: [i]),
    ]);
    var stats = pool.stats;
    expect(stats.total, lessThanOrEqualTo(2));
    expect(stats.idle, stats.total);
    expect(stats.inUse, 0);
    expect(stats.waiting, 0);
    expect(stats.opened, stats.total);

    final hold = Completer<void>();
    final busy = [
      for (var i = 0; i < 2; i++) pool.withConnection((_) => hold.future)
    ];
    await eventually(() => pool.inUseConnections == 2);
    await expectLater(
        pool.query('SELECT 1'), throwsA(isA<OperationalException>()));
    stats = pool.stats;
    expect(stats.acquireTimeouts, 1);
    expect(stats.inUse, 2);
    hold.complete();
    await Future.wait(busy);
    expect(pool.stats.toString(), contains('acquireTimeouts: 1'));
  });
}
