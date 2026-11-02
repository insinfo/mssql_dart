import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tds_base.dart' show OperationalException;

/// A SQL Server instance advertised by the SQL Server Browser.
class SqlServerInstance {
  const SqlServerInstance({
    required this.serverName,
    required this.instanceName,
    this.isClustered = false,
    this.version,
    this.tcpPort,
    this.pipeName,
    this.properties = const {},
  });

  /// NetBIOS name of the server.
  final String serverName;

  /// Instance name (`MSSQLSERVER` for the default instance).
  final String instanceName;

  final bool isClustered;

  /// SQL Server version, such as `16.0.1000.6`.
  final String? version;

  /// TCP port the instance listens on, or `null` if TCP is disabled.
  final int? tcpPort;

  /// Named pipe of the instance, if enabled.
  final String? pipeName;

  /// All key/value pairs received, with keys as sent.
  final Map<String, String> properties;

  @override
  String toString() => 'SqlServerInstance($serverName\\$instanceName, '
      'tcp: ${tcpPort ?? '-'}, version: ${version ?? '?'})';
}

/// Client for the SQL Server Resolution Protocol ([MC-SQLR]).
///
/// The SQL Server Browser service (UDP 1434) uses it to report the TCP port of
/// named instances.
///
/// ```dart
/// final instance = await SqlBrowser.lookupInstance('db-host', 'SQLEXPRESS');
/// print(instance.tcpPort);
/// ```
abstract final class SqlBrowser {
  /// UDP port of the SQL Server Browser.
  static const int defaultPort = 1434;

  /// Default time to wait for a response.
  static const Duration defaultTimeout = Duration(seconds: 2);

  static const int _clntUcastEx = 0x03;
  static const int _clntUcastInst = 0x04;
  static const int _svrResp = 0x05;

  /// Asks the Browser on [host] for the instance [instanceName]
  /// (CLNT_UCAST_INST).
  ///
  /// Throws [OperationalException] if there is no response within [timeout]
  /// (the Browser is stopped, the UDP port is blocked or the instance does
  /// not exist: in these cases the server simply does not reply) or if the
  /// response does not include the instance.
  static Future<SqlServerInstance> lookupInstance(
    String host,
    String instanceName, {
    int port = defaultPort,
    Duration timeout = defaultTimeout,
  }) async {
    final name = instanceName.trim();
    if (name.isEmpty || name.length > 32) {
      throw ArgumentError.value(
          instanceName, 'instanceName', 'must be 1 to 32 characters long');
    }
    final request = <int>[_clntUcastInst, ..._encodeName(name), 0];
    final data = await _query(host, port, request, timeout,
        what: 'for instance "$name"');
    final instances = parseResponse(data);
    for (final instance in instances) {
      if (instance.instanceName.toLowerCase() == name.toLowerCase()) {
        return instance;
      }
    }
    throw OperationalException(
      'The SQL Server Browser at $host:$port replied without instance "$name" '
      '(advertised: ${instances.map((i) => i.instanceName).join(', ')})',
    );
  }

  /// Lists the instances advertised by the Browser on [host] (CLNT_UCAST_EX).
  static Future<List<SqlServerInstance>> listInstances(
    String host, {
    int port = defaultPort,
    Duration timeout = defaultTimeout,
  }) async {
    final data = await _query(host, port, const [_clntUcastEx], timeout,
        what: 'for the instance list');
    return parseResponse(data);
  }

  /// Returns the TCP port of [instanceName] on [host].
  ///
  /// Throws [OperationalException] if the instance does not accept TCP.
  static Future<int> resolvePort(
    String host,
    String instanceName, {
    int port = defaultPort,
    Duration timeout = defaultTimeout,
  }) async {
    final instance =
        await lookupInstance(host, instanceName, port: port, timeout: timeout);
    final tcpPort = instance.tcpPort;
    if (tcpPort == null) {
      throw OperationalException(
        'Instance "$instanceName" on $host does not accept TCP/IP (the '
        'Browser reported no tcp port); enable TCP/IP in SQL Server '
        'Configuration Manager',
      );
    }
    return tcpPort;
  }

  /// Decodes an SVR_RESP response.
  ///
  /// The layout is `0x05`, the size (little-endian uint16) and the text
  /// `ServerName;X;InstanceName;Y;IsClustered;No;Version;...;tcp;1433;;`,
  /// with one instance per block terminated by `;;`.
  static List<SqlServerInstance> parseResponse(List<int> data) {
    if (data.length < 3 || data[0] != _svrResp) {
      throw const FormatException(
          'Invalid SQL Server Browser response (expected SVR_RESP 0x05)');
    }
    final size = data[1] | (data[2] << 8);
    if (size > data.length - 3) {
      throw FormatException(
          'Truncated SQL Server Browser response: $size bytes announced, '
          '${data.length - 3} received');
    }
    // The text uses the server code page; names and ports are ASCII.
    final text = latin1.decode(data.sublist(3, 3 + size));
    final instances = <SqlServerInstance>[];
    for (final block in text.split(';;')) {
      if (block.trim().isEmpty) continue;
      final parts = block.split(';');
      final properties = <String, String>{};
      final lowered = <String, String>{};
      for (var i = 0; i + 1 < parts.length; i += 2) {
        properties[parts[i]] = parts[i + 1];
        lowered[parts[i].toLowerCase()] = parts[i + 1];
      }
      final instanceName = lowered['instancename'];
      if (instanceName == null) {
        throw FormatException(
            'SQL Server Browser response without InstanceName: "$block"');
      }
      final tcp = lowered['tcp'];
      instances.add(SqlServerInstance(
        serverName: lowered['servername'] ?? '',
        instanceName: instanceName,
        isClustered: (lowered['isclustered'] ?? '').toLowerCase() == 'yes',
        version: lowered['version'],
        tcpPort: tcp == null ? null : int.tryParse(tcp.trim()),
        pipeName: lowered['np'],
        properties: Map.unmodifiable(properties),
      ));
    }
    return instances;
  }

  static List<int> _encodeName(String name) {
    for (final unit in name.codeUnits) {
      if (unit > 0x7f) return utf8.encode(name);
    }
    return ascii.encode(name);
  }

  /// Sends [request] to every address of [host] and returns the first
  /// response.
  ///
  /// Resends once halfway through [timeout], since UDP can drop packets.
  static Future<Uint8List> _query(
    String host,
    int port,
    List<int> request,
    Duration timeout, {
    required String what,
  }) async {
    final List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host).timeout(timeout);
    } on SocketException catch (error) {
      throw OperationalException(
          'Failed to resolve $host for the SQL Server Browser: ${error.message}');
    } on TimeoutException {
      throw OperationalException(
          'Timed out resolving $host for the SQL Server Browser');
    }
    final sockets = <RawDatagramSocket>[];
    final response = Completer<Uint8List>();
    Timer? resend;
    try {
      for (final type in {for (final a in addresses) a.type}) {
        final bindAddress = type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4;
        final RawDatagramSocket socket;
        try {
          socket = await RawDatagramSocket.bind(bindAddress, 0);
        } on SocketException {
          continue; // e.g. IPv6 stack unavailable
        }
        sockets.add(socket);
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null || response.isCompleted) return;
          final bytes = datagram.data;
          if (bytes.isNotEmpty && bytes[0] == _svrResp) {
            response.complete(bytes);
          }
        }, onError: (Object _) {
          // ICMP "port unreachable" may surface as an error; keep waiting for
          // the other addresses until the timeout.
        });
      }
      if (sockets.isEmpty) {
        throw OperationalException(
            'Could not open a UDP socket for the SQL Server Browser');
      }
      void sendAll() {
        for (final address in addresses) {
          for (final socket in sockets) {
            if (socket.address.type == address.type) {
              try {
                socket.send(request, address, port);
              } on SocketException {
                // Unreachable address; the others may still respond.
              }
            }
          }
        }
      }

      sendAll();
      resend = Timer(timeout ~/ 2, sendAll);
      return await response.future.timeout(timeout);
    } on TimeoutException {
      throw OperationalException(
        'The SQL Server Browser at $host (UDP $port) did not answer the query '
        '$what within $timeout. Check that the SQL Server Browser service is '
        'running, that UDP port $port is open in the firewall and that the '
        'instance name is correct, or specify the TCP port directly',
      );
    } finally {
      resend?.cancel();
      for (final socket in sockets) {
        socket.close();
      }
    }
  }
}
