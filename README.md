# mssql_dart

An asynchronous Microsoft SQL Server driver written in pure Dart. It speaks
TDS 7.4 directly over a socket: no ODBC, no FreeTDS, no native libraries.

- Non-blocking `Future`/`Stream` API, built for HTTP servers and other
  concurrent apps, with a connection pool
- Parameters sent as binary RPC (`sp_executesql`), never spliced into SQL;
  `@name`, `@p0` or `?` placeholders; explicit SQL types when you need them
- TLS on by default, with certificate chain and host name validation
- Transactions with isolation levels and savepoints, stored procedures with
  OUTPUT parameters, per-command timeouts and cancellation
- Batched `executeMany`, streaming of large results, JSON-ready rows
- Connection strings (ADO.NET, JDBC, URI), named instances, Azure SQL redirects
- All SQL Server data types, including `(max)` types, `xml`, `sql_variant`,
  `datetimeoffset` and `varchar` in every collation code page (UTF-8 included)

## Quick start

```dart
import 'package:mssql_dart/mssql_dart.dart';

Future<void> main() async {
  final conn = await MssqlConnection.connect(const MssqlConnectionSettings(
    host: 'localhost',
    database: 'app',
    username: 'app_user',
    password: 'secret',
  ));

  final users = await conn.query(
    'SELECT id, name FROM users WHERE active = @active',
    parameters: {'active': true},
  );
  for (final row in users) {
    print('${row['id']}: ${row['name']}');
  }

  await conn.close();
}
```

In a server, use a pool instead of a single connection; see
[Using it in an HTTP server](#using-it-in-an-http-server).

## Connecting

`MssqlConnectionSettings` holds everything needed to connect, or parse it from
a connection string:

```dart
final settings = MssqlConnectionSettings.parse(
    'Server=tcp:db.example.com,1433;Database=app;User Id=app;Password=secret;'
    'Encrypt=true;Connect Timeout=30;Command Timeout=30');
// also accepted:
//   mssql://app:p%40ss@db.example.com:1433/app?trustServerCertificate=true
//   jdbc:sqlserver://db.example.com:1433;databaseName=app;user=app;password=secret
```

Keys are case-insensitive and accept the usual synonyms (`Data Source`,
`Address`, `Initial Catalog`, `UID`, `PWD`, `Application Name`...). Values may
be quoted with `"..."`, `'...'` or `{...}` to contain `;`. In URIs, user and
password are percent-decoded. Unknown keys throw a `FormatException` listing
them; keys of other drivers with no effect here (`Pooling`, `Max Pool Size`,
`Packet Size`, `MultiSubnetFailover`, `Driver`...) are ignored; unsupported
features (`MultipleActiveResultSets=true`, `Integrated Security`,
`Encrypt=Strict`) throw. `toString()` never shows the password.

### TLS

TLS is enabled by default (`encrypt: true`). The server certificate is
verified against the system CA bundle, or against `caFile` when given, and must
name `host`.

| Server certificate | Settings |
|---|---|
| Issued by a public CA for the host you connect to | nothing to change |
| Issued by your own CA | `caFile: 'ca.pem'` |
| Self-signed, e.g. the official Docker image | `caFile` pointing at the certificate, or `trustServerCertificate: true` |

`trustServerCertificate: true` keeps the traffic encrypted but does not
authenticate the server. With `encrypt: false` nothing is encrypted, not even
the login. Windows ships no CA bundle file, so give `caFile` there (or set
`SSL_CERT_FILE`).

### Timeouts, keepalive, named instances and Azure

- `connectTimeout` (15 s) bounds the whole connection: TCP, TLS, login and
  session setup. When it expires the socket is closed.
- `commandTimeout` sets the default timeout of every command (see
  [Timeouts and cancellation](#timeouts-and-cancellation)).
- `keepAlive` (30 s; `Duration.zero` disables it) turns on TCP keepalive so
  that connections dropped by NATs and firewalls are detected: after that much
  idle time the OS sends probes every 10 s and gives up after 3.
- `Server=host\SQLEXPRESS` (or `instanceName: 'SQLEXPRESS'`) without a port asks
  the SQL Server Browser (UDP 1434) for the instance's TCP port. Give the port
  (`host\SQLEXPRESS,49172`) to skip the lookup.
- When the server answers the login with a routing redirect (the Azure SQL
  gateway with the *Redirect* policy, or an Always On listener with
  `readOnlyIntent: true`), the driver reconnects once to the indicated server,
  validating its TLS certificate against that server's name.

## Queries

```dart
// Rows of the first result set; each row works by index or column name.
final users = await conn.query('SELECT id, name FROM users');
print(users.first['name']);
print(users.columns.map((c) => c.name));

final user = await conn.queryFirst('SELECT * FROM users WHERE id = @p0', parameters: [id]); // row or null
final one = await conn.querySingle('SELECT * FROM users WHERE id = @p0', parameters: [id]); // StateError unless 1 row
final count = await conn.queryScalar<int>('SELECT COUNT(*) FROM users');
final maps = await conn.queryMaps('SELECT id, name FROM users');

// Statements without rows return the affected row count.
final updated = await conn.execute(
  'UPDATE users SET active = 0 WHERE last_login < @p0',
  parameters: [DateTime.utc(2024)],
);
```

`parameters` is either a `List`, bound to `@p0`, `@p1`... in order, or a
`Map`, bound by name (`{'id': 1}` fills `@id`). To write `?` placeholders as in
JDBC or PDO, pass `placeholder: PlaceholderIdentifier.onlyQuestionMark`:

```dart
await conn.query(
  'SELECT * FROM books WHERE author = ? AND year > ?',
  parameters: ['Machado de Assis', 1880],
  placeholder: PlaceholderIdentifier.onlyQuestionMark,
);
```

A `?` inside a string literal, a `[bracketed]` or `"quoted"` identifier or a
comment is left alone.

### Types

| Dart value | Sent as |
|---|---|
| `int` | `int`, or `bigint` outside 32 bits |
| `double` | `float` |
| `bool` | `bit` |
| `String` | `nvarchar(4000)`, or `nvarchar(max)` when longer |
| `Uint8List` / `List<int>` | `varbinary(8000)`, or `varbinary(max)` |
| `DateTime` | `datetime2(7)`, using the value's calendar fields as they are |
| `Duration` | `time(7)` |
| `DateTimeOffsetValue` | `datetimeoffset(7)` |
| `DecimalValue`, `BigInt` | `decimal(38, s)` |
| `null` | `NULL` |

Columns come back as `int`, `double`, `bool`, `String`, `Uint8List`,
`DateTime` (UTC, holding the stored calendar value), `Duration` (`time`),
`DateTimeOffsetValue`, `DecimalValue` (`decimal`/`numeric`, exact) or
`double` (`money`). `uniqueidentifier` comes back as its string form.

### Explicit parameter types

Use `SqlParameter` to choose the SQL type, inside the `List` or the `Map`:

```dart
await conn.query('SELECT * FROM customers WHERE code = @code',
    parameters: {'code': SqlParameter.varchar('A-123', length: 20)});
```

A `String` goes as `nvarchar`, which makes SQL Server convert a `varchar`
column and skip its index; `SqlParameter.varchar` keeps the comparison
sargable. It is encoded in the code page of the database's default collation;
characters outside it throw `DataException` (use `nvarchar` for those).
Available: `bit`, `tinyint`, `smallint`, `int`, `bigint`, `real`, `float`,
`decimal(value, precision:, scale:)`, `money`, `smallmoney`, `date`,
`time(scale:)`, `datetime`, `smalldatetime`, `datetime2(scale:)`,
`datetimeoffset(scale:)`, `uniqueidentifier`, `char`, `varchar`, `nchar`,
`nvarchar`, `binary`, `varbinary` (with `length:`; `SqlParameter.max` for
`(max)`) and `xml`. `SqlParameter.int(null)` sends a typed `NULL`.

`.output()` makes an OUTPUT parameter; after `query`, its value is in
`result.outputParameters`:

```dart
final r = await conn.query('SET @n = @p * 2',
    parameters: {'p': 21, 'n': SqlParameter.int(null).output()});
print(r.outputParameters['n']); // 42
```

### JSON

Rows convert to JSON-ready maps: `DateTime` as ISO-8601, `time` as
`HH:MM:SS.ffffff`, `decimal` and `BigInt` as strings (no precision loss),
`datetimeoffset` as ISO-8601 with its offset, binary as base64.

```dart
response.write(jsonEncode((await pool.query('SELECT * FROM products')).toJson()));
response.write(jsonEncode(row.toJson()));
```

### Many rows: executeMany and streaming

```dart
await conn.executeMany(
  'INSERT INTO tags (name) VALUES (@p0)',
  [for (final tag in tags) [tag]],
);

await for (final row in conn.stream('SELECT * FROM big_table')) {
  // rows arrive as they are decoded; pausing the subscription pauses reading,
  // cancelling it stops the command on the server
}
```

`executeMany` sends the parameter sets in batches (up to 1000 RPC calls or
about 512 KB per round trip): 5,000 inserts take about 0.35 s instead of more
than 15 s one by one. SQL Server runs each call independently, so if one item
fails the others in the same batch are still applied; the error is thrown
after the batch and later batches are not sent. Wrap it in `transaction` for
all or nothing.

### Several result sets

```dart
final cursor = await conn.openCursor('SELECT 1 AS a; SELECT 2 AS b');
print(await cursor.fetchAll());
await cursor.nextSet();
print(await cursor.fetchOne());
await cursor.close();
```

A connection runs one command at a time. A cursor, stream or transaction
holds the connection until it finishes or is closed, and other calls wait for
their turn, so always close cursors.

## Transactions

```dart
await conn.transaction((tx) async {
  await tx.execute('UPDATE accounts SET balance -= 10 WHERE id = @p0', parameters: [1]);
  await tx.execute('UPDATE accounts SET balance += 10 WHERE id = @p0', parameters: [2]);
}, isolationLevel: IsolationLevel.serializable);
// COMMIT, or ROLLBACK if the callback throws
```

While a transaction runs, the connection is reserved for it: commands issued
from other code wait until it ends. The isolation level applies only to that
transaction (`snapshot` needs `ALLOW_SNAPSHOT_ISOLATION ON`).

Inside a transaction, `savepoint(name)` and `rollbackToSavepoint(name)` undo
part of the work, and a nested `tx.transaction(...)` runs on an automatic
savepoint: if it throws, only its work is rolled back. SQL Server spells these
`SAVE TRANSACTION name` / `ROLLBACK TRANSACTION name` (not `SAVEPOINT`).

## Stored procedures

```dart
final result = await conn.callProcedure('dbo.create_order', parameters: {
  'customer': 42,
  'order_id': SqlParameter.int(null).output(),
});
print(result.returnStatus);                 // RETURN value
print(result.outputParameters['order_id']);
for (final set in result.resultSets) { /* every result set */ }
```

The procedure is called by name over RPC. `parameters` is a `Map` (by name,
with or without `@`) or a `List` (by position; OUTPUT values are then keyed
`'0'`, `'1'`...).

## Timeouts and cancellation

```dart
await conn.query('SELECT * FROM big', timeout: const Duration(seconds: 5));
conn.commandTimeout = const Duration(seconds: 30); // default for every command
```

When a timeout expires, the driver sends a TDS attention, reads the reply up to
the server's acknowledgment and throws `MssqlTimeoutException`; the connection
stays usable. If the server does not acknowledge within 5 s, the connection is
closed. `conn.cancel()` cancels the command in flight from another async flow
(`MssqlCancelledException`). A cancelled command does not roll back an open
transaction; `transaction()` rolls it back when the error leaves the callback.

## Connection pool

```dart
final pool = MssqlPool(
  settings,
  maxConnections: 20,
  minConnections: 2,                                    // kept open
  onConnect: (conn) => conn.execute('SET LOCK_TIMEOUT 5000'),
  onQuery: (e) => log('${e.elapsed} ${e.sql}'),
);

final user = await pool.queryFirst('SELECT * FROM users WHERE id = @p0', parameters: [id]);
await pool.transaction((conn) async { /* ... */ });
await pool.withConnection((conn) async { /* several commands */ });

print(pool.stats); // total, idle, inUse, waiting, opened, closed, ...
await pool.close(timeout: const Duration(seconds: 10));
```

The pool offers the same commands as a connection (`query`, `queryFirst`,
`execute`, `executeMany`, `stream`, `callProcedure`, `transaction`...), each on
a connection of its own. It never opens more than `maxConnections`, waits up
to `acquireTimeout` for a free one, keeps `minConnections` open (retrying in
the background while the server is down), discards broken connections, rolls
back a transaction left open, checks connections idle for more than
`validateAfterIdle`, and closes those idle for more than `idleTimeout` or
older than `maxLifetime`. A connection whose session state was changed
(`SET ...`, `USE`, `EXECUTE AS`, temp tables) is reset before reuse, so
settings never leak between requests (`resetSessionState: false` disables it).
`close()` refuses new work and waits for borrowed connections to come back.

## Using it in an HTTP server

Share one `MssqlPool` across requests, give every command a timeout, and map
driver exceptions to HTTP status codes:

```dart
final pool = MssqlPool(settings, maxConnections: 20);

Future<void> handle(HttpRequest request) async {
  try {
    final id = int.parse(request.uri.pathSegments.last);
    final row = await pool.queryFirst(
        'SELECT id, name, price FROM products WHERE id = @p0',
        parameters: [id], timeout: const Duration(seconds: 5));
    request.response
      ..statusCode = row == null ? 404 : 200
      ..write(jsonEncode(row?.toJson() ?? {'error': 'not found'}));
  } on IntegrityException {
    request.response.statusCode = 409;      // unique/foreign key violation
  } on MssqlTimeoutException {
    request.response.statusCode = 504;      // the connection stays usable
  } on InterfaceException {
    request.response.statusCode = 503;      // pool closed or connection lost
  } finally {
    await request.response.close();
  }
}
```

Use `pool.transaction` for work that must be atomic, savepoints included; never
issue `BEGIN`/`SAVE`/`ROLLBACK` as separate commands on a connection shared by
concurrent requests. The test suite runs a REST API like this one
(`test/integration/rest_api_test.dart`): CRUD, pagination, NDJSON streaming
with clients that disconnect, timeouts, hundreds of concurrent requests, and
sessions killed on the server in the middle of the load, after which the pool
recovers on its own.

## Errors

Every exception extends `MssqlException`:

- `DatabaseException`: reported by the server, with `number`, `severity`,
  `state`, `line` and `procName`. Subtypes: `ProgrammingException` (syntax,
  missing object, permission), `IntegrityException` (constraint violations),
  `LoginException`, `OperationalException` (connection, TLS, timeouts;
  `MssqlTimeoutException` and `MssqlCancelledException` are subtypes)
- `InterfaceException`: misuse of the API, or a closed connection
  (`ClosedConnectionException`)
- `DataException`: a value that cannot be converted

A server error leaves the connection usable. An error that breaks the protocol
stream (a dropped connection, a malformed reply) closes it, and later calls
fail at once with `ClosedConnectionException` instead of hanging.

## Query hook

`onQuery` (on a connection or a pool) is called after every command with the
SQL as sent, the parameters, the elapsed time, the affected rows and the
error, if any: a single place for logging, metrics and tracing.

## Performance

Rows are decoded synchronously from the packet buffer, the socket is a
`RawSocket` with backpressure, requests are built in one buffer and sent with a
single write, and `executeMany` batches RPC calls. `benchmark/` holds the
measurements (`throughput.dart`, `execute_many.dart`).

## Limitations

- SQL Server authentication only: no Windows/NTLM/Kerberos or Microsoft Entra
  (Azure AD) login yet
- No MARS: one active command per connection (use the pool)
- No table-valued parameters or bulk copy yet
- TDS 8.0 strict encryption is not supported

## Low-level API

`package:mssql_dart/tds.dart` exposes the TDS session, socket, transport and
SQL Browser client used underneath, for tooling and experiments.

## Running the tests

The integration tests expect a server on `localhost:1433` with a database
`dart` and a login `dart`/`dart`, using the certificate in
`test/certificates`. The `MSSQL_HOST`, `MSSQL_PORT`, `MSSQL_USER`,
`MSSQL_PASSWORD`, `MSSQL_DATABASE` and `MSSQL_CA_FILE` environment variables
override those defaults, and `MSSQL_TRUST_SERVER_CERTIFICATE=true` accepts the
server's own certificate. See `.github/workflows/ci.yml` for a scripted setup.

## License

MIT. The TDS implementation is a port of
[pytds](https://github.com/denisenkom/pytds) (MIT). Character set tables come
from enough_convert (MPL-2.0) and charset (Apache-2.0); see `LICENSE` and
`lib/third_party/README.md`.
