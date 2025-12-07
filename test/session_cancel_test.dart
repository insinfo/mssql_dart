import 'dart:typed_data';

import 'package:mssql_dart/src/session_link.dart';
import 'package:mssql_dart/src/tds_base.dart' as tds;
import 'package:mssql_dart/src/async_tds_session.dart';
import 'package:mssql_dart/src/tds_types.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncTdsSession.cancel', () {
    test('envia pacote CANCEL', () async {
      final transport = _FakeAsyncTransport();
      final session = AsyncTdsSession.fromContext(
        AsyncSessionBuildContext(
          transport: transport,
          bufsize: 512,
          env: tds.TdsEnv(),
          typeFactory: SerializerFactory(tds.TDS74),
        ),
      );

      await session.cancel();

      expect(transport.sentBuffers, isNotEmpty);
      expect(transport.sentBuffers.first.first, equals(tds.PacketType.CANCEL));
    });
  });
}

class _FakeAsyncTransport implements tds.AsyncTransportProtocol {
  final List<List<int>> sentBuffers = [];
  bool _connected = true;
  Duration? _timeout;

  @override
  bool get isConnected => _connected;

  @override
  Duration? get timeout => _timeout;

  @override
  set timeout(Duration? value) {
    _timeout = value;
  }

  @override
  Future<void> close() async {
    _connected = false;
  }

  @override
  Future<void> sendAll(List<int> data, {int flags = 0}) async {
    sentBuffers.add(List<int>.from(data));
  }

  @override
  Future<Uint8List> recv(int size) async => Uint8List(0);

  @override
  Future<Uint8List> recvAvailable(int maxSize) async => Uint8List(0);

  @override
  Future<int> recvInto(ByteBuffer buffer, {int size = 0, int flags = 0}) async => 0;
}
