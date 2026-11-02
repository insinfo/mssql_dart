/// Pure Dart asynchronous driver for Microsoft SQL Server.
///
/// Start with [MssqlConnection.connect] or, in servers, with [MssqlPool].
/// The low-level protocol lives in `package:mssql_dart/tds.dart`.
library;

export 'src/connection.dart' show IsolationLevel, MssqlConnection, MssqlCursor;
export 'src/placeholders.dart' show PlaceholderIdentifier;
export 'src/pool.dart' show MssqlPool, MssqlPoolStats;
export 'src/query_hook.dart' show MssqlQueryEvent, MssqlQueryHook;
export 'src/result.dart'
    show MssqlColumn, MssqlProcedureResult, MssqlResult, MssqlRow;
export 'src/settings.dart' show MssqlConnectionSettings;
export 'src/sql_parameter.dart' show SqlParameter, SqlParameterKind;
export 'src/tds_base.dart'
    show
        ClosedConnectionException,
        DataException,
        DatabaseException,
        IntegrityException,
        InterfaceException,
        InternalException,
        LoginException,
        MssqlCancelledException,
        MssqlException,
        MssqlTimeoutException,
        NotSupportedException,
        OperationalException,
        ProgrammingException,
        TlsBackend;
export 'src/tds_types.dart' show DateTimeOffsetValue, DecimalValue;
