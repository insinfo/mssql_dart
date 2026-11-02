## 1.0.0

First release: a pure Dart TDS 7.4 driver for Microsoft SQL Server, ported
from pytds, that runs wherever the Dart VM runs.

- `MssqlConnection`: `query` (rows by index or column name), `queryFirst`,
  `querySingle`, `queryScalar`, `queryMaps`, `execute`, `executeMany`,
  `stream`, `openCursor`/`MssqlCursor` (several result sets), `callProcedure`
  and `transaction`
- `MssqlPool`: bounded pool with `minConnections`, acquire timeout, validation
  of idle connections, idle and lifetime limits, `onConnect`, session reset
  between borrowers (`SET`, `USE`, isolation level), rollback of transactions
  left open, removal of broken connections, graceful `close`, `stats`
- Parameters sent as binary RPC (`sp_executesql`) with inferred types, or
  explicit ones with `SqlParameter` (`varchar`, `decimal(p, s)`, `datetime`,
  `uniqueidentifier`, ...), including OUTPUT parameters
- `@name`, `@p0` and `?` placeholders (`PlaceholderIdentifier.onlyQuestionMark`)
- Stored procedures by RPC with OUTPUT parameters, return status and every
  result set
- Transactions with isolation levels, savepoints and nested transactions on
  savepoints
- Per-command `timeout`, `commandTimeout` and `cancel()`: a TDS attention
  stops the command and the connection stays usable
- `executeMany` batches up to 1000 RPC calls per round trip
- JSON-ready rows (`MssqlRow.toJson`, `MssqlResult.toJson`)
- `onQuery` hook for logging, metrics and tracing
- Connection strings: ADO.NET/ODBC, JDBC and `mssql://` URIs
- Named instances through the SQL Server Browser, Azure SQL/Always On routing
  redirects, `readOnlyIntent`, TCP keepalive
- TLS on by default, TLS 1.2 minimum. The server certificate is validated
  (chain against `caFile` or the system CAs, and host name);
  `trustServerCertificate` accepts any certificate
- `connectTimeout` bounds TCP, TLS, login and session setup together and
  closes the socket when it expires
- Reads every SQL Server type, including `(max)`, `text`/`ntext`/`image`,
  `xml`, `sql_variant`, and `varchar` in all collation code pages and in
  UTF-8 collations
- Exceptions: `MssqlException`, `DatabaseException` (with the server's number,
  severity, state and line), `ProgrammingException`, `IntegrityException`,
  `LoginException`, `OperationalException`, `MssqlTimeoutException`,
  `MssqlCancelledException`, `InterfaceException`,
  `ClosedConnectionException`, `DataException`
- A server error leaves the connection usable; a failure that breaks the
  protocol stream closes it, so later calls fail at once instead of hanging
- Socket on `RawSocket` with read backpressure; rows decoded synchronously
  from the packet buffer; requests encoded in one buffer
- No runtime dependencies besides `tlslite`
