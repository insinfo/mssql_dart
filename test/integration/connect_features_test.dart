import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:mssql_dart/src/async_socket_transport.dart';
import 'package:mssql_dart/src/connect.dart';
import 'package:test/test.dart';

import 'fake_routing_server.dart';
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

/// Fake SQL Browser: answers CLNT_UCAST_INST with [port].
Future<RawDatagramSocket> fakeBrowser(int port, List<List<int>> requests,
    {String instance = 'SQLEXPRESS'}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    requests.add(datagram.data);
    final body = latin1.encode('ServerName;FAKE;InstanceName;$instance;'
        'IsClustered;No;Version;16.0.1000.6;tcp;$port;;');
    socket.send([0x05, body.length & 0xff, body.length >> 8, ...body],
        datagram.address, datagram.port);
  });
  return socket;
}

void main() {
  group('named instance', () {
    test('resolves the port through SQL Browser and connects', () async {
      final requests = <List<int>>[];
      final browser = await fakeBrowser(testPort, requests);
      addTearDown(browser.close);
      final named = MssqlConnectionSettings(
        host: '127.0.0.1',
        instanceName: 'SQLEXPRESS',
        username: testUser,
        password: testPassword,
        database: testDatabase,
        encrypt: false,
      );
      final conn = MssqlConnection.fromSocket(
          await connectWithSettings(named, browserPort: browser.port));
      addTearDown(conn.close);
      expect((await conn.query('SELECT DB_NAME()')).single[0], testDatabase);
      expect(requests.single, [0x04, ...ascii.encode('SQLEXPRESS'), 0]);
    });

    test('host\\instance in the connection string', () async {
      final requests = <List<int>>[];
      final browser = await fakeBrowser(testPort, requests, instance: 'DEV');
      addTearDown(browser.close);
      final parsed = MssqlConnectionSettings.parse(
          'Server=127.0.0.1\\DEV;UID=$testUser;PWD=$testPassword;'
          'Encrypt=false');
      final socket =
          await connectWithSettings(parsed, browserPort: browser.port);
      addTearDown(socket.close);
      expect(socket.isConnected, isTrue);
      expect(requests, hasLength(1));
    });

    test('an explicit port skips SQL Browser', () async {
      final requests = <List<int>>[];
      final browser = await fakeBrowser(1, requests);
      addTearDown(browser.close);
      final socket = await connectWithSettings(
          settings.copyWith(instanceName: 'SQLEXPRESS'),
          browserPort: browser.port);
      addTearDown(socket.close);
      expect(requests, isEmpty);
    });

    test('silent Browser: clear error', () async {
      final silent =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      await expectLater(
        connectWithSettings(
          MssqlConnectionSettings(
            host: '127.0.0.1',
            instanceName: 'NADA',
            username: testUser,
            password: testPassword,
            encrypt: false,
            connectTimeout: const Duration(seconds: 1),
          ),
          browserPort: silent.port,
        ),
        throwsA(isA<OperationalException>().having(
            (e) => e.toString(), 'message', contains('SQL Server Browser'))),
      );
    });
  });

  group('redirection (Azure SQL)', () {
    test('reconnects once to the server named by ENVCHANGE 20', () async {
      final gateway = await FakeRoutingServer.start(
          routeHost: testHost, routePort: testPort);
      addTearDown(gateway.close);
      final conn = await MssqlConnection.connect(MssqlConnectionSettings(
        host: '127.0.0.1',
        port: gateway.port,
        username: testUser,
        password: testPassword,
        database: testDatabase,
        encrypt: false,
      ));
      addTearDown(conn.close);
      expect(gateway.logins, 1);
      expect(gateway.loginServerNames.single, '127.0.0.1');
      expect((await conn.query('SELECT DB_NAME()')).single[0], testDatabase);
    });

    test('a second redirect is refused', () async {
      final loop = await FakeRoutingServer.start(routeHost: '', routePort: 0);
      addTearDown(loop.close);
      loop
        ..routeHost = '127.0.0.1'
        ..routePort = loop.port;
      await expectLater(
        MssqlConnection.connect(MssqlConnectionSettings(
          host: '127.0.0.1',
          port: loop.port,
          username: testUser,
          password: testPassword,
          encrypt: false,
        )),
        throwsA(isA<OperationalException>().having(
            (e) => e.toString(), 'message', contains('more than once'))),
      );
      expect(loop.logins, 2);
    });
  });

  test('keepAlive enables SO_KEEPALIVE on the connection socket', () async {
    final socket = await connectWithSettings(MssqlConnectionSettings(
      host: testHost,
      port: testPort,
      username: testUser,
      password: testPassword,
      encrypt: false,
      keepAlive: const Duration(seconds: 25),
    ));
    addTearDown(socket.close);
    final transport = socket.mainSession.transport;
    expect(transport, isA<AsyncSocketTransport>());
    final raw = (transport as AsyncSocketTransport).rawSocket;
    final level = RawSocketOption.levelSocket;
    final option = Platform.isLinux || Platform.isAndroid ? 9 : 0x0008;
    final value =
        raw.getRawOption(RawSocketOption(level, option, Uint8List(4)));
    expect(ByteData.sublistView(value).getInt32(0, Endian.host), isNot(0));
  }, testOn: 'mac-os || linux');
}
