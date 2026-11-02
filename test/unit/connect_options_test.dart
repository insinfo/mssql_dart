import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:mssql_dart/src/async_socket_transport.dart';
import 'package:mssql_dart/src/connect.dart';
import 'package:mssql_dart/src/pool.dart' show changesSessionState;
import 'package:test/test.dart';

void main() {
  group('splitInstance', () {
    test('splits host\\instance', () {
      final r = splitInstance(r'srv\SQLEXPRESS', null);
      expect(r.host, 'srv');
      expect(r.instance, 'SQLEXPRESS');
    });

    test('explicit instanceName takes precedence', () {
      final r = splitInstance(r'srv\A', 'B');
      expect(r.host, 'srv');
      expect(r.instance, 'B');
    });

    test('no instance', () {
      final r = splitInstance(' srv ', '');
      expect(r.host, 'srv');
      expect(r.instance, isNull);
    });
  });

  group('RoutingTarget.fromRoute', () {
    test('no redirect', () {
      expect(RoutingTarget.fromRoute(null), isNull);
    });

    test('server and port from ENVCHANGE 20', () {
      final t = RoutingTarget.fromRoute({
        'protocol': 0,
        'port': 11003,
        'server': 'abc.tr1.westeurope1-a.worker.database.windows.net',
      })!;
      expect(t.host, 'abc.tr1.westeurope1-a.worker.database.windows.net');
      expect(t.port, 11003);
    });

    test('drops the instance from the name', () {
      final t = RoutingTarget.fromRoute(
          {'protocol': 0, 'port': 1500, 'server': r'replica2\INST'})!;
      expect(t.host, 'replica2');
      expect(t.port, 1500);
    });

    test('invalid protocol or target', () {
      expect(
          () => RoutingTarget.fromRoute(
              {'protocol': 1, 'port': 1, 'server': 'x'}),
          throwsA(isA<OperationalException>()));
      expect(
          () => RoutingTarget.fromRoute(
              {'protocol': 0, 'port': 0, 'server': 'x'}),
          throwsA(isA<OperationalException>()));
      expect(
          () =>
              RoutingTarget.fromRoute({'protocol': 0, 'port': 1, 'server': ''}),
          throwsA(isA<OperationalException>()));
    });
  });

  group('login', () {
    test('the instance goes to PRELOGIN and the host to the certificate', () {
      final login = buildLoginForTesting(
          host: 'srv',
          instanceName: 'SQLEXPRESS',
          user: 'u',
          password: 'p',
          readOnlyIntent: true);
      expect(login.serverName, 'srv');
      expect(login.instanceName, 'SQLEXPRESS');
      expect(login.readonly, isTrue);
    });
  });

  group('TCP keepalive', () {
    test('enables SO_KEEPALIVE and sets the idle time', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((s) => s.listen(null, onDone: s.destroy));
      final socket =
          await RawSocket.connect(InternetAddress.loopbackIPv4, server.port);
      addTearDown(socket.close);

      expect(
          AsyncSocketTransport.enableKeepAlive(
              socket, const Duration(seconds: 42)),
          isTrue);

      int readInt(int level, int option) {
        final bytes =
            socket.getRawOption(RawSocketOption(level, option, Uint8List(4)));
        return ByteData.sublistView(bytes).getInt32(0, Endian.host);
      }

      if (Platform.isMacOS) {
        expect(readInt(RawSocketOption.levelSocket, 0x0008), isNot(0));
        expect(readInt(RawSocketOption.levelTcp, 0x10), 42);
        expect(readInt(RawSocketOption.levelTcp, 0x101), 10);
        expect(readInt(RawSocketOption.levelTcp, 0x102), 3);
      } else if (Platform.isLinux) {
        expect(readInt(RawSocketOption.levelSocket, 9), isNot(0));
        expect(readInt(RawSocketOption.levelTcp, 4), 42);
      }
    });
  });

  group('changesSessionState', () {
    bool plain(String sql) => changesSessionState(sql, null);

    test('detects session SETs in a batch without parameters', () {
      expect(plain('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE'), isTrue);
      expect(plain('set nocount on; insert into t values (1)'), isTrue);
      expect(plain('SET LANGUAGE Portuguese'), isTrue);
      expect(plain('SET XACT_ABORT ON'), isTrue);
      expect(plain('SET IDENTITY_INSERT dbo.t ON'), isTrue);
      expect(plain('EXECUTE AS USER = \'x\''), isTrue);
      expect(plain('CREATE TABLE #tmp (id int)'), isTrue);
      expect(plain('SELECT * INTO #copia FROM t'), isTrue);
    });

    test('ignores UPDATE ... SET column = value and ordinary queries', () {
      expect(plain("UPDATE t SET language = 'pt', nocount = 1"), isFalse);
      expect(plain('UPDATE t SET rowcount += 1'), isFalse);
      expect(plain('SELECT 1'), isFalse);
      expect(plain('BEGIN TRANSACTION'), isFalse);
      expect(plain('SELECT @var_SET'), isFalse);
    });

    test('with parameters, only state that survives sp_executesql', () {
      expect(changesSessionState('SET NOCOUNT ON; SELECT @p0', [1]), isFalse);
      expect(
          changesSessionState('CREATE TABLE #t (id int)', {'a': 1}), isFalse);
      expect(
          changesSessionState("EXEC sp_set_session_context N'k', @p0", ['v']),
          isTrue);
      expect(
          changesSessionState('CREATE TABLE ##global (id int)', [1]), isTrue);
      expect(changesSessionState('SET NOCOUNT ON', const []), isTrue);
    });
  });
}
