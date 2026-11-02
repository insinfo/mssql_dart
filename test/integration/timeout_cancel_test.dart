import 'dart:async';
import 'dart:io';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

MssqlConnectionSettings _settings(
        {String? host, int? port, bool encrypt = true}) =>
    MssqlConnectionSettings(
      host: host ?? testHost,
      port: port ?? testPort,
      username: testUser,
      password: testPassword,
      database: testDatabase,
      encrypt: encrypt,
      caFile: encrypt ? testCa : null,
      trustServerCertificate: encrypt && testTrustServerCertificate,
    );

/// Many rows, for a result that takes a while to finish.
const _bigSelect = 'SELECT TOP (3000000) a.object_id, b.name '
    'FROM sys.all_objects a CROSS JOIN sys.all_objects b';

void main() {
  late MssqlConnection conn;
  setUp(() async => conn = await MssqlConnection.connect(_settings()));
  tearDown(() => conn.close());

  group('per-command timeout', () {
    test(
        'WAITFOR with a short timeout throws MssqlTimeoutException and the '
        'connection stays usable', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        conn.execute("WAITFOR DELAY '00:00:05'",
            timeout: const Duration(milliseconds: 300)),
        throwsA(isA<MssqlTimeoutException>()
            .having(
                (e) => e.timeout, 'timeout', const Duration(milliseconds: 300))
            .having((e) => e.connectionClosed, 'connectionClosed', isFalse)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(conn.isOpen, isTrue);
      expect((await conn.query('SELECT 1')).single[0], 1);
    });

    test('query, stream and openCursor also accept a timeout', () async {
      const limit = Duration(milliseconds: 300);
      await expectLater(
          conn.query("WAITFOR DELAY '00:00:05'; SELECT 1", timeout: limit),
          throwsA(isA<MssqlTimeoutException>()));
      await expectLater(
          conn
              .stream("WAITFOR DELAY '00:00:05'; SELECT 1", timeout: limit)
              .toList(),
          throwsA(isA<MssqlTimeoutException>()));
      await expectLater(
          conn.openCursor("WAITFOR DELAY '00:00:05'; SELECT 1", timeout: limit),
          throwsA(isA<MssqlTimeoutException>()));
      final cursor = conn.cursor();
      await expectLater(
          cursor.execute("WAITFOR DELAY '00:00:05'", timeout: limit),
          throwsA(isA<MssqlTimeoutException>()));
      await cursor.close();
      expect(await conn.queryScalar<int>('SELECT 2'), 2);
    });

    test('commandTimeout applies when the call passes no timeout', () async {
      conn.commandTimeout = const Duration(milliseconds: 300);
      await expectLater(conn.execute("WAITFOR DELAY '00:00:05'"),
          throwsA(isA<MssqlTimeoutException>()));
      // The call's timeout takes precedence.
      expect(
          await conn.execute("WAITFOR DELAY '00:00:00.500'",
              timeout: const Duration(seconds: 10)),
          -1);
      conn.commandTimeout = null;
      expect(await conn.queryScalar<int>('SELECT 3'), 3);
    });

    test('a fast command is not affected by the timeout', () async {
      for (var i = 0; i < 20; i++) {
        expect(
            await conn.queryScalar<int>('SELECT @p0',
                parameters: [i], timeout: const Duration(seconds: 5)),
            i);
      }
    });

    test('timeout while reading a large result', () async {
      // Without TLS: after the ATTENTION the driver still reads what was
      // already in flight (megabytes in the TCP buffers), and with pure Dart
      // TLS that takes tens of seconds on this emulated server.
      final plain = await MssqlConnection.connect(_settings(encrypt: false));
      addTearDown(plain.close);
      final watch = Stopwatch()..start();
      await expectLater(
          plain.query(_bigSelect, timeout: const Duration(milliseconds: 500)),
          throwsA(isA<MssqlTimeoutException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
      expect(await plain.queryScalar<int>('SELECT 4'), 4);
    });

    test(
        'expires while waiting its turn without cancelling another flow\'s command',
        () async {
      final busy = conn.execute("WAITFOR DELAY '00:00:01.500'; SELECT 1");
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      await expectLater(
          conn.query('SELECT 5', timeout: const Duration(milliseconds: 200)),
          throwsA(isA<MssqlTimeoutException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      // The command that was running finishes normally.
      expect(await busy, 1);
      expect(await conn.queryScalar<int>('SELECT 6'), 6);
    });

    test(
        'a timeout inside transaction leaves the transaction open until '
        'transaction() rolls it back', () async {
      await conn.execute('CREATE TABLE #tt (id int)');
      int? trancountAfterTimeout;
      await expectLater(
        conn.transaction((tx) async {
          await tx.execute('INSERT INTO #tt VALUES (1)');
          try {
            await tx.execute("WAITFOR DELAY '00:00:05'",
                timeout: const Duration(milliseconds: 300));
          } on MssqlTimeoutException {
            // SQL Server does not roll back the transaction because of the ATTENTION.
            trancountAfterTimeout =
                await tx.queryScalar<int>('SELECT @@TRANCOUNT');
            rethrow;
          }
        }),
        throwsA(isA<MssqlTimeoutException>()),
      );
      expect(trancountAfterTimeout, 1);
      expect(await conn.queryScalar<int>('SELECT @@TRANCOUNT'), 0);
      expect(await conn.queryScalar<int>('SELECT COUNT(*) FROM #tt'), 0);
      expect(conn.hasOpenTransaction, isFalse);
    });

    test('onQuery receives the timeout error', () async {
      final events = <MssqlQueryEvent>[];
      conn.onQuery = events.add;
      await expectLater(
          conn.execute("WAITFOR DELAY '00:00:05'",
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<MssqlTimeoutException>()));
      expect(events.single.error, isA<MssqlTimeoutException>());
      expect(events.single.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('cancel()', () {
    test('cancels a command from another flow', () async {
      final running = conn.execute("WAITFOR DELAY '00:00:10'");
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await conn.cancel(), isTrue);
      await expectLater(
          running,
          throwsA(isA<MssqlCancelledException>()
              .having((e) => e, 'type', isNot(isA<MssqlTimeoutException>()))));
      expect(await conn.queryScalar<int>('SELECT 1'), 1);
    });

    test('returns false when no command is running', () async {
      expect(await conn.cancel(), isFalse);
      expect(await conn.queryScalar<int>('SELECT 1'), 1);
    });

    test('cancels a long running stream', () async {
      var received = 0;
      final watch = Stopwatch()..start();
      Object? error;
      final done = Completer<void>();
      conn.stream(_bigSelect).listen((_) {
        received++;
        if (received == 10) unawaited(conn.cancel());
      }, onError: (Object e) => error = e, onDone: done.complete);
      await done.future;
      expect(error, isA<MssqlCancelledException>());
      expect(received, greaterThanOrEqualTo(10));
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      expect(await conn.queryScalar<int>('SELECT 7'), 7);
    });

    test('cancels a cursor paused in the middle of the result', () async {
      final cursor = await conn.openCursor(_bigSelect);
      expect(await cursor.fetchOne(), isNotNull);
      expect(await conn.cancel(), isTrue);
      // The acknowledgement is consumed in the background; the next read
      // delivers the cancellation.
      Object? error;
      try {
        while (await cursor.fetchOne() != null) {}
      } catch (e) {
        error = e;
      }
      expect(error, isA<MssqlCancelledException>());
      await cursor.close();
      expect(await conn.queryScalar<int>('SELECT 8'), 8);
    });

    test('cancelling a stream subscription interrupts the command', () async {
      final watch = Stopwatch()..start();
      final rows = await conn.stream(_bigSelect).take(3).toList();
      expect(rows, hasLength(3));
      expect(await conn.queryScalar<int>('SELECT 9'), 9);
      // Without the ATTENTION, all 3 million rows would be read and discarded.
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
    });
  });

  group('server that does not acknowledge the cancellation', () {
    test('the connection is closed after the acknowledgement deadline',
        () async {
      final proxy = await _FreezableProxy.start(testHost, testPort);
      addTearDown(proxy.close);
      final proxied = await MssqlConnection.connect(
          _settings(host: 'localhost', port: proxy.port));
      addTearDown(proxied.close);
      proxied.tdsSocket.cursor().attentionGracePeriod =
          const Duration(milliseconds: 500);
      expect(await proxied.queryScalar<int>('SELECT 1'), 1);

      proxy.freezeServerToClient = true;
      final watch = Stopwatch()..start();
      await expectLater(
        proxied.execute("WAITFOR DELAY '00:00:03'",
            timeout: const Duration(milliseconds: 300)),
        throwsA(isA<MssqlTimeoutException>()
            .having((e) => e.connectionClosed, 'connectionClosed', isTrue)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(proxied.isOpen, isFalse);
      await expectLater(
          proxied.query('SELECT 1'), throwsA(isA<MssqlException>()));
    });
  });
}

/// TCP proxy that can stop forwarding what comes from the server, simulating
/// an unresponsive server.
class _FreezableProxy {
  _FreezableProxy._(this._server, this._host, this._port) {
    _server.listen(_handle);
  }

  static Future<_FreezableProxy> start(String host, int port) async =>
      _FreezableProxy._(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), host, port);

  final ServerSocket _server;
  final String _host;
  final int _port;
  final List<Socket> _sockets = [];
  bool freezeServerToClient = false;

  int get port => _server.port;

  Future<void> _handle(Socket client) async {
    final upstream = await Socket.connect(_host, _port);
    _sockets
      ..add(client)
      ..add(upstream);
    client.listen(upstream.add,
        onDone: () => upstream.destroy(), onError: (_) => upstream.destroy());
    upstream.listen((data) {
      if (!freezeServerToClient) client.add(data);
    }, onDone: () => client.destroy(), onError: (_) => client.destroy());
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}
