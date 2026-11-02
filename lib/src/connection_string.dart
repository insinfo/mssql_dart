import 'settings.dart';

/// Parses an ADO.NET/ODBC, JDBC or URI connection string.
///
/// Backs [MssqlConnectionSettings.parse].
MssqlConnectionSettings parseConnectionString(String connectionString) {
  final text = connectionString.trim();
  if (text.isEmpty) {
    throw const FormatException('Empty connection string');
  }
  final builder = _SettingsBuilder();
  final lower = text.toLowerCase();
  if (lower.startsWith('jdbc:sqlserver://')) {
    _parseJdbc(text.substring('jdbc:sqlserver://'.length), builder);
  } else if (lower.startsWith('mssql://') || lower.startsWith('sqlserver://')) {
    _parseUri(text, builder);
  } else {
    for (final (key, value) in splitConnectionStringPairs(text)) {
      builder.apply(key, value);
    }
  }
  return builder.build(text);
}

/// Splits `key=value;key=value` into pairs.
///
/// Values may be enclosed in `"..."`, `'...'` (a doubled quote escapes it) or
/// `{...}` (`}}` escapes `}`).
List<(String, String)> splitConnectionStringPairs(String text) {
  final pairs = <(String, String)>[];
  var i = 0;
  final n = text.length;
  bool isSpace(int index) => text.codeUnitAt(index) <= 0x20;

  while (i < n) {
    while (i < n && (isSpace(i) || text[i] == ';')) {
      i++;
    }
    if (i >= n) break;
    final keyStart = i;
    while (i < n && text[i] != '=' && text[i] != ';') {
      i++;
    }
    if (i >= n || text[i] == ';') {
      throw FormatException(
          'Segment without "=" in connection string', text, keyStart);
    }
    final key = text.substring(keyStart, i).trim();
    if (key.isEmpty) {
      throw FormatException('Empty key in connection string', text, i);
    }
    i++; // '='
    while (i < n && isSpace(i) && text[i] != ';') {
      i++;
    }
    String value;
    if (i < n && (text[i] == '"' || text[i] == "'" || text[i] == '{')) {
      final open = text[i];
      final close = open == '{' ? '}' : open;
      final buffer = StringBuffer();
      final valueStart = i;
      i++;
      var closed = false;
      while (i < n) {
        final ch = text[i];
        if (ch == close) {
          if (i + 1 < n && text[i + 1] == close) {
            buffer.write(close);
            i += 2;
            continue;
          }
          closed = true;
          i++;
          break;
        }
        buffer.write(ch);
        i++;
      }
      if (!closed) {
        throw FormatException(
            'Value of "$key" is missing the closing $close', text, valueStart);
      }
      while (i < n && isSpace(i)) {
        i++;
      }
      if (i < n && text[i] != ';') {
        throw FormatException(
            'Unexpected text after the value of "$key"', text, i);
      }
      value = buffer.toString();
    } else {
      final valueStart = i;
      while (i < n && text[i] != ';') {
        i++;
      }
      value = text.substring(valueStart, i).trim();
    }
    pairs.add((key, value));
  }
  return pairs;
}

void _parseUri(String text, _SettingsBuilder builder) {
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException catch (error) {
    throw FormatException('Invalid URI: ${error.message}', text);
  }
  final userInfo = uri.userInfo;
  if (userInfo.isNotEmpty) {
    final colon = userInfo.indexOf(':');
    final user = colon < 0 ? userInfo : userInfo.substring(0, colon);
    builder.apply('user', Uri.decodeComponent(user));
    if (colon >= 0) {
      builder.apply(
          'password', Uri.decodeComponent(userInfo.substring(colon + 1)));
    }
  }
  if (uri.host.isNotEmpty) {
    builder.apply('server', _rawUriHost(text) ?? uri.host, fromUriHost: true);
  }
  if (uri.hasPort) builder.apply('port', '${uri.port}');
  final path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
  if (path.isNotEmpty) {
    if (path.contains('/')) {
      throw FormatException(
          'URI path must be just the database name: "/$path"', text);
    }
    builder.apply('database', Uri.decodeComponent(path));
  }
  uri.queryParametersAll.forEach((key, values) {
    for (final value in values) {
      builder.apply(key, value);
    }
  });
}

/// The host as written ([Uri.host] lowercases it, which would alter a
/// `host%5CInstance`); `null` for a bracketed IPv6 address.
String? _rawUriHost(String text) {
  var authority = text.substring(text.indexOf('://') + 3);
  authority = authority.split(RegExp('[/?#]')).first;
  final at = authority.lastIndexOf('@');
  if (at >= 0) authority = authority.substring(at + 1);
  if (authority.startsWith('[')) return null;
  final colon = authority.lastIndexOf(':');
  if (colon >= 0) authority = authority.substring(0, colon);
  return Uri.decodeComponent(authority);
}

void _parseJdbc(String rest, _SettingsBuilder builder) {
  final semicolon = rest.indexOf(';');
  final serverPart =
      (semicolon < 0 ? rest : rest.substring(0, semicolon)).trim();
  if (serverPart.isNotEmpty) builder.apply('server', serverPart);
  if (semicolon >= 0) {
    for (final (key, value)
        in splitConnectionStringPairs(rest.substring(semicolon + 1))) {
      builder.apply(key, value);
    }
  }
}

/// Accepted keys (lowercase, without spaces) and the field each one sets.
const Map<String, String> _keys = {
  'server': 'server',
  'datasource': 'server',
  'address': 'server',
  'addr': 'server',
  'networkaddress': 'server',
  'host': 'server',
  'servername': 'server',
  'port': 'port',
  'portnumber': 'port',
  'instancename': 'instance',
  'instance': 'instance',
  'database': 'database',
  'initialcatalog': 'database',
  'databasename': 'database',
  'userid': 'user',
  'uid': 'user',
  'user': 'user',
  'username': 'user',
  'password': 'password',
  'pwd': 'password',
  'encrypt': 'encrypt',
  'trustservercertificate': 'trust',
  'trustservercert': 'trust',
  'connecttimeout': 'timeout',
  'connectiontimeout': 'timeout',
  'timeout': 'timeout',
  'logintimeout': 'timeout',
  'applicationname': 'app',
  'app': 'app',
  'applicationintent': 'intent',
  'cafile': 'cafile',
  'servercertificate': 'cafile',
  'validatehostname': 'validatehost',
  'keepalive': 'keepalive',
  'commandtimeout': 'commandtimeout',
  'multipleactiveresultsets': 'mars',
  'mars_connection': 'mars',
  'marsconnection': 'mars',
  'integratedsecurity': 'integrated',
  'trustedconnection': 'integrated',
  'trusted_connection': 'integrated',
  'authentication': 'authentication',
};

/// Keys from other drivers that are accepted and ignored.
///
/// They control the ADO.NET pool (here that is `MssqlPool`), the ODBC driver,
/// or details with no equivalent.
const Set<String> _ignoredKeys = {
  'pooling',
  'minpoolsize',
  'maxpoolsize',
  'connectionlifetime',
  'loadbalancetimeout',
  'connectretrycount',
  'connectretryinterval',
  'persistsecurityinfo',
  'packetsize',
  'workstationid',
  'wsid',
  'currentlanguage',
  'language',
  'multisubnetfailover',
  'transparentnetworkipresolution',
  'enlist',
  'transactionbinding',
  'typesystemversion',
  'poolblockingperiod',
  'replication',
  'driver',
  'provider',
};

class _SettingsBuilder {
  final Map<String, String> values = {};
  final List<String> unknown = [];
  bool hostHadInstanceOrPort = false;

  void apply(String rawKey, String value, {bool fromUriHost = false}) {
    final key = rawKey.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (_ignoredKeys.contains(key)) return;
    final field = _keys[key];
    if (field == null) {
      unknown.add(rawKey.trim());
      return;
    }
    if (field == 'server') {
      _applyServer(value, rawKey, fromUriHost: fromUriHost);
      return;
    }
    values[field] = value;
  }

  void _applyServer(String raw, String key, {required bool fromUriHost}) {
    var server = raw.trim();
    final colonPrefix =
        RegExp(r'^(tcp|np|lpc|admin|via):', caseSensitive: false)
            .firstMatch(server);
    if (colonPrefix != null && !fromUriHost) {
      final protocol = colonPrefix.group(1)!.toLowerCase();
      if (protocol != 'tcp') {
        throw FormatException(
            'Protocol "$protocol:" is not supported in $key (use tcp)', raw);
      }
      server = server.substring(colonPrefix.end).trim();
    }
    String? port;
    final comma = server.lastIndexOf(',');
    if (comma >= 0) {
      port = server.substring(comma + 1).trim();
      server = server.substring(0, comma).trim();
    }
    String? instance;
    final backslash = server.indexOf('\\');
    if (backslash >= 0) {
      instance = server.substring(backslash + 1).trim();
      server = server.substring(0, backslash).trim();
    }
    if (server.startsWith('[') && server.endsWith(']')) {
      server = server.substring(1, server.length - 1); // bracketed IPv6
    } else if (port == null &&
        !fromUriHost &&
        RegExp(r'^[^:]+:\d+$').hasMatch(server)) {
      // `host:port`, common in other ecosystems (and in the JDBC format).
      final colon = server.lastIndexOf(':');
      port = server.substring(colon + 1);
      server = server.substring(0, colon);
    }
    if (instance != null && port == null) {
      final colon = instance.lastIndexOf(':');
      if (colon >= 0 &&
          RegExp(r'^\d+$').hasMatch(instance.substring(colon + 1))) {
        port = instance.substring(colon + 1); // JDBC: host\instance:port
        instance = instance.substring(0, colon);
      }
    }
    if (server.isEmpty || server == '.' || server.toLowerCase() == '(local)') {
      server = 'localhost';
    }
    values['host'] = server;
    if (instance != null && instance.isNotEmpty) {
      values['instance'] = instance;
    }
    if (port != null) values['port'] = port;
  }

  MssqlConnectionSettings build(String source) {
    if (unknown.isNotEmpty) {
      throw FormatException(
          'Unknown connection string keys: ${unknown.join(', ')}');
    }
    final host = values['host'];
    if (host == null) {
      throw const FormatException(
          'Connection string has no server (Server/Data Source)');
    }
    final user = values['user'];
    if (user == null || user.isEmpty) {
      throw const FormatException(
          'Connection string has no user (User Id/UID); only SQL Server '
          'authentication is supported');
    }
    _rejectUnsupported();

    final portText = values['port'];
    int? port;
    if (portText != null && portText.isNotEmpty) {
      port = int.tryParse(portText);
      if (port == null || port <= 0 || port > 65535) {
        throw FormatException('Invalid port: "$portText"');
      }
    }
    final instance = values['instance'];
    final timeout = _seconds('timeout', 'Connect Timeout', allowZero: false);
    final keepAlive = _seconds('keepalive', 'KeepAlive', allowZero: true);
    // As in ADO.NET, Command Timeout=0 means no limit.
    final commandTimeout =
        _seconds('commandtimeout', 'Command Timeout', allowZero: true);
    final intent = values['intent'];
    var readOnly = false;
    if (intent != null) {
      switch (intent.toLowerCase().replaceAll(' ', '')) {
        case 'readonly':
          readOnly = true;
        case 'readwrite':
          readOnly = false;
        default:
          throw FormatException('Invalid ApplicationIntent: "$intent"');
      }
    }
    const defaults =
        MssqlConnectionSettings(host: '', username: '', password: '');
    final caFile = values['cafile'];
    return MssqlConnectionSettings(
      host: host,
      port: port,
      instanceName: instance == null || instance.isEmpty ? null : instance,
      username: user,
      password: values['password'] ?? '',
      database: values['database'] ?? '',
      applicationName: values['app'] ?? defaults.applicationName,
      encrypt: _encrypt(),
      trustServerCertificate: _bool('trust', 'TrustServerCertificate') ?? false,
      caFile: caFile == null || caFile.isEmpty ? null : caFile,
      validateHostName: _bool('validatehost', 'ValidateHostName') ?? true,
      connectTimeout: timeout ?? defaults.connectTimeout,
      keepAlive: keepAlive ?? defaults.keepAlive,
      readOnlyIntent: readOnly,
      commandTimeout: commandTimeout == null || commandTimeout == Duration.zero
          ? null
          : commandTimeout,
    );
  }

  void _rejectUnsupported() {
    if (_bool('mars', 'MultipleActiveResultSets') ?? false) {
      throw const FormatException(
          'MultipleActiveResultSets=true is not supported (no MARS); use an '
          'MssqlPool for concurrent commands');
    }
    if (_bool('integrated', 'Integrated Security') ?? false) {
      throw const FormatException(
          'Integrated Security (Windows authentication) is not supported; use '
          'a SQL Server login');
    }
    final authentication = values['authentication'];
    if (authentication != null) {
      final normalized = authentication.toLowerCase().replaceAll(' ', '');
      if (normalized != 'sqlpassword' && normalized.isNotEmpty) {
        throw FormatException(
            'Authentication="$authentication" is not supported; only '
            'SqlPassword');
      }
    }
  }

  bool _encrypt() {
    final raw = values['encrypt'];
    if (raw == null || raw.isEmpty) return true;
    switch (raw.toLowerCase()) {
      case 'true' || 'yes' || '1' || 'mandatory':
        return true;
      case 'false' || 'no' || '0' || 'optional':
        return false;
      case 'strict':
        throw const FormatException(
            'Encrypt=Strict (TDS 8.0) is not supported; use Encrypt=true');
      default:
        throw FormatException('Invalid value for Encrypt: "$raw"');
    }
  }

  bool? _bool(String field, String label) {
    final raw = values[field];
    if (raw == null || raw.isEmpty) return null;
    switch (raw.toLowerCase()) {
      case 'true' || 'yes' || '1':
        return true;
      case 'false' || 'no' || '0':
        return false;
      default:
        if (field == 'integrated' && raw.toLowerCase() == 'sspi') return true;
        throw FormatException('Invalid boolean value for $label: "$raw"');
    }
  }

  Duration? _seconds(String field, String label, {required bool allowZero}) {
    final raw = values[field];
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds == null || seconds < 0 || (!allowZero && seconds == 0)) {
      throw FormatException('$label must be a '
          '${allowZero ? 'non-negative' : 'positive'} number of seconds: '
          '"$raw"');
    }
    return Duration(seconds: seconds);
  }
}
