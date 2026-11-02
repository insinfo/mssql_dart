import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:mssql_dart/src/sql_browser.dart';
import 'package:test/test.dart';

/// Builds an SVR_RESP response containing [text].
Uint8List svrResp(String text) {
  final body = latin1.encode(text);
  return Uint8List.fromList(
      [0x05, body.length & 0xff, body.length >> 8, ...body]);
}

/// Fake SQL Browser: answers each datagram with [reply] (or does not answer).
class FakeBrowser {
  FakeBrowser._(this.socket, this.reply) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      requests.add(datagram.data);
      final response = reply(datagram.data);
      if (response != null) {
        socket.send(response, datagram.address, datagram.port);
      }
    });
  }

  static Future<FakeBrowser> start(
          Uint8List? Function(Uint8List request) reply) async =>
      FakeBrowser._(
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0), reply);

  final RawDatagramSocket socket;
  final Uint8List? Function(Uint8List request) reply;
  final List<Uint8List> requests = [];

  int get port => socket.port;
  void close() => socket.close();
}

void main() {
  group('SqlBrowser.parseResponse', () {
    test('one instance (reply to CLNT_UCAST_INST)', () {
      final instances = SqlBrowser.parseResponse(svrResp(
          'ServerName;SRV01;InstanceName;SQLEXPRESS;IsClustered;No;'
          'Version;15.0.2000.5;tcp;49172;np;\\\\SRV01\\pipe\\MSSQL\$SQLEXPRESS\\sql\\query;;'));
      expect(instances, hasLength(1));
      final i = instances.single;
      expect(i.serverName, 'SRV01');
      expect(i.instanceName, 'SQLEXPRESS');
      expect(i.isClustered, isFalse);
      expect(i.version, '15.0.2000.5');
      expect(i.tcpPort, 49172);
      expect(i.pipeName, r'\\SRV01\pipe\MSSQL$SQLEXPRESS\sql\query');
      expect(i.properties['Version'], '15.0.2000.5');
    });

    test('several instances (reply to CLNT_UCAST_EX)', () {
      final instances = SqlBrowser.parseResponse(
          svrResp('ServerName;SRV;InstanceName;MSSQLSERVER;IsClustered;No;'
              'Version;16.0.1000.6;tcp;1433;;'
              'ServerName;SRV;InstanceName;DEV;IsClustered;Yes;'
              'Version;16.0.1000.6;np;\\\\SRV\\pipe\\sql\\query;;'));
      expect(instances.map((i) => i.instanceName), ['MSSQLSERVER', 'DEV']);
      expect(instances[0].tcpPort, 1433);
      expect(instances[1].tcpPort, isNull);
      expect(instances[1].isClustered, isTrue);
    });

    test('ignores bytes past the announced length', () {
      final data = [
        ...svrResp('ServerName;S;InstanceName;I;tcp;1500;;'),
        0,
        0,
        0
      ];
      expect(SqlBrowser.parseResponse(data).single.tcpPort, 1500);
    });

    test('invalid responses', () {
      expect(
          () => SqlBrowser.parseResponse([0x04, 0, 0]), throwsFormatException);
      expect(() => SqlBrowser.parseResponse([0x05, 50, 0, 65]),
          throwsFormatException);
      expect(() => SqlBrowser.parseResponse(svrResp('ServerName;S;tcp;1;;')),
          throwsFormatException);
    });
  });

  group('SqlBrowser with a fake UDP responder', () {
    test('sends CLNT_UCAST_INST and resolves the port', () async {
      final browser = await FakeBrowser.start((_) =>
          svrResp('ServerName;FAKE;InstanceName;SQLEXPRESS;IsClustered;No;'
              'Version;16.0.1000.6;tcp;41433;;'));
      addTearDown(browser.close);
      final port = await SqlBrowser.resolvePort('127.0.0.1', 'SQLEXPRESS',
          port: browser.port);
      expect(port, 41433);
      expect(
          browser.requests.first, [0x04, ...ascii.encode('SQLEXPRESS'), 0x00]);
    });

    test('compares the instance name case-insensitively', () async {
      final browser = await FakeBrowser.start(
          (_) => svrResp('ServerName;F;InstanceName;SQLEXPRESS;tcp;1600;;'));
      addTearDown(browser.close);
      final instance = await SqlBrowser.lookupInstance(
          '127.0.0.1', 'sqlexpress',
          port: browser.port);
      expect(instance.tcpPort, 1600);
    });

    test('listInstances envia CLNT_UCAST_EX', () async {
      final browser = await FakeBrowser.start((_) => svrResp(
          'ServerName;F;InstanceName;A;tcp;1;;ServerName;F;InstanceName;B;tcp;2;;'));
      addTearDown(browser.close);
      final list =
          await SqlBrowser.listInstances('127.0.0.1', port: browser.port);
      expect(list.map((i) => i.tcpPort), [1, 2]);
      expect(browser.requests.first, [0x03]);
    });

    test('no response: clear OperationalException after the timeout', () async {
      final browser = await FakeBrowser.start((_) => null);
      addTearDown(browser.close);
      final watch = Stopwatch()..start();
      await expectLater(
        SqlBrowser.lookupInstance('127.0.0.1', 'NADA',
            port: browser.port, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<OperationalException>().having(
            (e) => e.toString(), 'message', contains('SQL Server Browser'))),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      // Resends once halfway through the timeout.
      expect(browser.requests.length, 2);
    });

    test('instance without TCP enabled', () async {
      final browser = await FakeBrowser.start((_) => svrResp(
          'ServerName;F;InstanceName;SQLEXPRESS;np;\\\\F\\pipe\\sql\\query;;'));
      addTearDown(browser.close);
      await expectLater(
        SqlBrowser.resolvePort('127.0.0.1', 'SQLEXPRESS', port: browser.port),
        throwsA(isA<OperationalException>()
            .having((e) => e.toString(), 'message', contains('TCP'))),
      );
    });

    test('response for a different instance', () async {
      final browser = await FakeBrowser.start(
          (_) => svrResp('ServerName;F;InstanceName;OUTRA;tcp;1;;'));
      addTearDown(browser.close);
      await expectLater(
        SqlBrowser.lookupInstance('127.0.0.1', 'SQLEXPRESS',
            port: browser.port),
        throwsA(isA<OperationalException>()),
      );
    });

    test('invalid instance name', () {
      expect(() => SqlBrowser.lookupInstance('127.0.0.1', ''),
          throwsArgumentError);
      expect(() => SqlBrowser.lookupInstance('127.0.0.1', 'x' * 33),
          throwsArgumentError);
    });
  });

  test('short timeout leaves no pending timers', () async {
    final browser = await FakeBrowser.start((_) => null);
    addTearDown(browser.close);
    await expectLater(
      SqlBrowser.resolvePort('127.0.0.1', 'X',
          port: browser.port, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<OperationalException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(browser.requests.length, lessThanOrEqualTo(2));
  });
}
