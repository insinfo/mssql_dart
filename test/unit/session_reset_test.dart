import 'dart:typed_data';

import 'package:mssql_dart/src/async_tds_session.dart';
import 'package:mssql_dart/src/session_link.dart';
import 'package:mssql_dart/src/session_reset.dart';
import 'package:mssql_dart/src/tds_base.dart' as tds;
import 'package:mssql_dart/src/tds_types.dart';
import 'package:test/test.dart';

AsyncTdsSession _session(_RecordingTransport transport) =>
    AsyncTdsSession.fromContext(AsyncSessionBuildContext(
      transport: transport,
      bufsize: 512,
      env: tds.TdsEnv(),
      typeFactory: SerializerFactory(tds.TDS74),
    ));

void main() {
  test('RESETCONNECTION goes only on the first packet of the next request',
      () async {
    final transport = _RecordingTransport();
    final session = _session(transport);
    expect(session, isA<ResettableSession>());

    session.resetConnectionOnNextRequest();
    // Large enough to span several 512-byte packets.
    await session.submitPlainQuery('SELECT ${'1' * 1000}');
    final first = List.of(transport.sent);
    expect(first.length, greaterThan(1));
    expect(first.first[1], 0x08); // RESETCONNECTION, no EOM
    expect(first.skip(1).every((packet) => packet[1] & 0x08 == 0), isTrue);
    expect(first.last[1], 0x01); // EOM

    transport.sent.clear();
    session.state = tds.TDS_IDLE;
    await session.submitExecSql('SELECT @p0', {'p0': 1});
    expect(transport.sent.single[0], tds.PacketType.RPC);
    expect(transport.sent.single[1], 0x01);

    transport.sent.clear();
    session.state = tds.TDS_IDLE;
    session.resetConnectionOnNextRequest();
    await session.submitExecSql('SELECT @p0', {'p0': 1});
    expect(transport.sent.single[1], 0x09); // EOM | RESETCONNECTION
  });

  test('requestCancel without a pending request sends nothing', () async {
    final transport = _RecordingTransport();
    final session = _session(transport);
    expect(await session.requestCancel(tds.MssqlCancelledException()), isFalse);
    expect(transport.sent, isEmpty);
  });
}

class _RecordingTransport implements tds.AsyncTransportProtocol {
  final List<Uint8List> sent = [];

  @override
  bool get isConnected => true;

  @override
  Duration? timeout;

  @override
  Future<void> close() async {}

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) async =>
      sent.add(Uint8List.fromList(data));

  @override
  Future<Uint8List> recv(int size) => Future.value(Uint8List(0));

  @override
  Future<Uint8List> recvAvailable(int maxSize) => Future.value(Uint8List(0));

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) =>
      Future.value(0);
}
