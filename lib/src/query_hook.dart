/// Details of an executed command, passed to [MssqlQueryHook].
class MssqlQueryEvent {
  const MssqlQueryEvent({
    required this.sql,
    required this.parameters,
    required this.elapsed,
    this.affectedRows,
    this.error,
  });

  /// The SQL as sent to the server (with `?` placeholders already converted).
  final String sql;

  /// The call's parameters ([List], [Map] or null).
  final Object? parameters;

  /// Time until the response was consumed (or until the failure).
  final Duration elapsed;

  /// Rows affected, when reported by the server.
  final int? affectedRows;

  /// The exception thrown by the command, or null on success.
  final Object? error;
}

/// Called after each command on a connection, for logging and metrics.
typedef MssqlQueryHook = void Function(MssqlQueryEvent event);
