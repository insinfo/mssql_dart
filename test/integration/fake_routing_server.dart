import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Minimal TDS server that mimics the Azure SQL gateway: answers PRELOGIN
/// without TLS and LOGIN7 with LOGINACK, a routing ENVCHANGE (type 20) to
/// [routeHost]:[routePort], and DONE.
class FakeRoutingServer {
  FakeRoutingServer._(this._server, this.routeHost, this.routePort) {
    _server.listen(_handle);
  }

  static Future<FakeRoutingServer> start({
    required String routeHost,
    required int routePort,
  }) async =>
      FakeRoutingServer._(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          routeHost,
          routePort);

  final ServerSocket _server;
  String routeHost;
  int routePort;

  /// Number of logins received.
  int logins = 0;

  /// ServerName sent in each LOGIN7.
  final List<String> loginServerNames = [];

  int get port => _server.port;

  Future<void> close() => _server.close();

  void _handle(Socket socket) {
    final buffer = BytesBuilder();
    final message = BytesBuilder();
    socket.listen((data) {
      buffer.add(data);
      var bytes = buffer.takeBytes();
      while (bytes.length >= 8) {
        final length = (bytes[2] << 8) | bytes[3];
        if (bytes.length < length) break;
        final type = bytes[0];
        final status = bytes[1];
        message.add(bytes.sublist(8, length));
        bytes = bytes.sublist(length);
        if (status & 0x01 != 0) _reply(socket, type, message.takeBytes());
      }
      buffer.add(bytes);
    }, onError: (_) => socket.destroy(), onDone: socket.destroy);
  }

  void _reply(Socket socket, int type, Uint8List payload) {
    switch (type) {
      case 0x12: // PRELOGIN
        socket.add(_packet([
          0x00, 0, 11, 0, 6, // VERSION
          0x01, 0, 17, 0, 1, // ENCRYPTION
          0xff,
          16, 0, 0x07, 0xd0, 0, 0, // 16.0.2000
          0x02, // ENCRYPT_NOT_SUP
        ]));
      case 0x10: // LOGIN7
        logins++;
        loginServerNames.add(_loginServerName(payload));
        socket.add(_packet(_loginReply()));
    }
  }

  String _loginServerName(Uint8List login) {
    final view = ByteData.sublistView(login);
    final offset = view.getUint16(52, Endian.little);
    final chars = view.getUint16(54, Endian.little);
    return String.fromCharCodes([
      for (var i = 0; i < chars; i++)
        view.getUint16(offset + i * 2, Endian.little)
    ]);
  }

  List<int> _loginReply() {
    final out = BytesBuilder();
    void u16(int v) => out.add([v & 0xff, v >> 8]);
    List<int> ucs2(String s) => [
          for (final c in s.codeUnits) ...[c & 0xff, c >> 8]
        ];

    const progName = 'Fake';
    out.addByte(0xad); // LOGINACK
    u16(1 + 4 + 1 + progName.length * 2 + 4);
    out.add([0x01, 0x74, 0x00, 0x00, 0x04, progName.length]);
    out.add(ucs2(progName));
    out.add([16, 0, 0x07, 0xd0]);

    final server = ucs2(routeHost);
    out.addByte(0xe3); // ENVCHANGE
    u16(1 + 2 + 1 + 2 + 2 + server.length + 2);
    out.addByte(20); // routing
    u16(1 + 2 + 2 + server.length);
    out.addByte(0); // TCP
    u16(routePort);
    u16(routeHost.length);
    out.add(server);
    u16(0);

    out.addByte(0xfd); // DONE
    u16(0);
    u16(0);
    out.add(List.filled(8, 0));
    return out.takeBytes();
  }

  static Uint8List _packet(List<int> payload) {
    final length = payload.length + 8;
    return Uint8List.fromList(
        [0x04, 0x01, length >> 8, length & 0xff, 0, 0, 1, 0, ...payload]);
  }
}
