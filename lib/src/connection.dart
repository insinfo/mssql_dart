import 'dart:async';
import 'dart:collection';

import 'async_cursor.dart';
import 'async_tds_session.dart';
import 'async_tds_socket.dart';
import 'connect.dart';
import 'placeholders.dart';
import 'query_hook.dart';
import 'result.dart';
import 'settings.dart';
import 'tds_base.dart' as tds;

/// Transaction isolation level ([MssqlConnection.transaction]).
enum IsolationLevel {
  readUncommitted('READ UNCOMMITTED'),
  readCommitted('READ COMMITTED'),
  repeatableRead('REPEATABLE READ'),
  serializable('SERIALIZABLE'),

  /// Requires `ALLOW_SNAPSHOT_ISOLATION ON` on the database.
  snapshot('SNAPSHOT');

  const IsolationLevel(this.sql);

  /// The level as written in `SET TRANSACTION ISOLATION LEVEL`.
  final String sql;
}

/// A connection to SQL Server.
///
/// ```dart
/// final conn = await MssqlConnection.connect(settings);
/// final users = await conn.query(
///   'SELECT id, name FROM users WHERE active = @active',
///   parameters: {'active': true},
/// );
/// for (final row in users) {
///   print('${row['id']}: ${row['name']}');
/// }
/// await conn.close();
/// ```
///
/// Parameters are sent as binary RPC (`sp_executesql`), never inlined in the
/// SQL text: pass a [List] for `@p0`, `@p1`... (or `?` with
/// [PlaceholderIdentifier.onlyQuestionMark]) or a [Map] for `@name`. Values
/// may be `SqlParameter` instances to choose the SQL type.
///
/// A connection runs one command at a time; concurrent calls wait their turn
/// in arrival order. For HTTP servers, use `MssqlPool`.
///
/// Every command accepts a `timeout`; without one, [commandTimeout] applies.
/// When it expires, the command is cancelled on the server and throws
/// `MssqlTimeoutException`, and the connection remains usable.
class MssqlConnection {
  MssqlConnection._(this._socket);

  /// Opens a connection using [settings].
  static Future<MssqlConnection> connect(
          MssqlConnectionSettings settings) async =>
      MssqlConnection._(await connectWithSettings(settings))
        ..commandTimeout = settings.commandTimeout;

  /// Wraps an already authenticated low-level socket.
  factory MssqlConnection.fromSocket(AsyncTdsSocket socket) =>
      MssqlConnection._(socket);

  final AsyncTdsSocket _socket;
  bool _closed = false;

  /// Called after each command on this connection (logging, metrics,
  /// tracing).
  MssqlQueryHook? onQuery;

  /// Default timeout for each command when the call does not pass a
  /// `timeout`; `null` (the default) waits indefinitely.
  ///
  /// The deadline counts from the call, including the wait for the
  /// connection. When it expires, the driver sends an ATTENTION to the
  /// server, waits for the acknowledgement and throws
  /// `MssqlTimeoutException`; the connection remains usable. If the server
  /// does not acknowledge within 5 s, the connection is closed.
  Duration? commandTimeout;

  /// Current owner: a [MssqlCursor] with an open result or a [transaction].
  Object? _owner;
  final Queue<Completer<void>> _waiters = Queue();
  final Object _txnKey = Object();
  _Command? _activeCommand;
  int _savepointSeq = 0;

  /// The underlying TDS socket, for advanced use.
  AsyncTdsSocket get tdsSocket => _ensureOpen();

  /// False after [close] or after a failure that broke the connection.
  bool get isOpen => !_closed && _socket.isConnected;

  /// Whether a [transaction] is active in the current flow.
  bool get inTransaction => Zone.current[_txnKey] != null;

  /// Whether the server considers a transaction open on this connection
  /// (including one started with `BEGIN TRANSACTION` in SQL).
  bool get hasOpenTransaction => _session?.transactionActive ?? false;

  AsyncTdsSession? get _session {
    final session = _socket.mainSession;
    return session is AsyncTdsSession ? session : null;
  }

  /// Creates a cursor, to read multiple result sets or row by row.
  MssqlCursor cursor() =>
      MssqlCursor._(this, AsyncTdsCursor(_ensureOpen().cursor()));

  /// Runs [sql] and returns the rows of the first result set.
  ///
  /// Values of `SqlParameter.output` parameters are available in
  /// [MssqlResult.outputParameters].
  Future<MssqlResult> query(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameters, placeholder, timeout, (command) async {
        final cur = await _openCursorIn(command, sql, parameters, placeholder);
        try {
          final rows = await cur.fetchAll();
          final columns = cur.columns;
          final affected = cur.affectedRows;
          final outputs = cur._ensureOpen().outputParameters;
          await cur.close();
          return MssqlResult(rows,
              columns: columns,
              affectedRows: affected,
              outputParameters:
                  outputs.isEmpty ? const {} : Map.unmodifiable(outputs));
        } finally {
          await cur.close();
        }
      }, affected: (result) => result.affectedRows);

  /// Returns the first row of the first result set, or `null` if there are
  /// no rows.
  ///
  /// The rest of the result is discarded; prefer `TOP 1` in the SQL.
  Future<MssqlRow?> queryFirst(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameters, placeholder, timeout, (command) async {
        final cur = await _openCursorIn(command, sql, parameters, placeholder);
        try {
          return await cur.fetchOne();
        } finally {
          await cur.close();
        }
      });

  /// Returns the only row of the first result set.
  ///
  /// Throws [StateError] if the result does not have exactly one row.
  Future<MssqlRow> querySingle(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameters, placeholder, timeout, (command) async {
        final cur = await _openCursorIn(command, sql, parameters, placeholder);
        try {
          final first = await cur.fetchOne();
          if (first == null) {
            throw StateError('querySingle: the query returned no rows');
          }
          if (await cur.fetchOne() != null) {
            throw StateError('querySingle: the query returned more than one '
                'row');
          }
          return first;
        } finally {
          await cur.close();
        }
      });

  /// Returns the first column of the first row, or `null` when there are no
  /// rows (or the value is `NULL`).
  ///
  /// ```dart
  /// final total = await conn.queryScalar<int>('SELECT COUNT(*) FROM users');
  /// ```
  Future<T?> queryScalar<T>(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameters, placeholder, timeout, (command) async {
        final cur = await _openCursorIn(command, sql, parameters, placeholder);
        try {
          final row = await cur.fetchOne();
          if (row == null || row.isEmpty) return null;
          return row[0] as T?;
        } finally {
          await cur.close();
        }
      });

  /// Returns the rows of the first result set as column → value maps.
  Future<List<Map<String, Object?>>> queryMaps(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) async {
    final result = await query(sql,
        parameters: parameters, placeholder: placeholder, timeout: timeout);
    return [for (final row in result) row.toColumnMap()];
  }

  /// Runs a command (INSERT, UPDATE, DDL...) and returns the rows affected
  /// by the last statement that reported them, or -1.
  Future<int> execute(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameters, placeholder, timeout, (command) async {
        final cur = await _openCursorIn(command, sql, parameters, placeholder);
        try {
          while (await cur.nextSet()) {}
          return cur.affectedRows;
        } finally {
          await cur.close();
        }
      }, affected: (count) => count);

  /// Runs [sql] for each item of [parameterSets] and returns the total rows
  /// affected (-1 if any item did not report them).
  ///
  /// Items are sent in batches: up to 1000 calls (or ~512 KB) per TDS
  /// message, one round trip per batch. If an item fails, the error is
  /// thrown after the whole batch finishes; SQL Server runs each item
  /// independently, so the items before and after it in the same batch are
  /// applied, and later batches are not sent. Use a [transaction] for
  /// all-or-nothing behavior.
  Future<int> executeMany(
    String sql,
    Iterable<Object?> parameterSets, {
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameterSets, placeholder, timeout, (command) async {
        final cur = cursor().._command = command;
        try {
          await cur._executeMany(sql, parameterSets, placeholder);
          return cur.affectedRows;
        } finally {
          await cur.close();
        }
      }, affected: (count) => count);

  /// Runs [sql] and emits rows as they arrive, without loading the whole
  /// result into memory.
  ///
  /// The connection stays busy until the stream ends or the subscription is
  /// cancelled. Cancelling the subscription early interrupts the command on
  /// the server (ATTENTION): subsequent statements in the same batch are not
  /// executed. [timeout] applies to the whole stream.
  Stream<MssqlRow> stream(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) {
    late StreamController<MssqlRow> controller;
    var cancelled = false;
    Completer<void>? resumed;
    Future<void> pump() async {
      final command = _Command(this, timeout);
      MssqlCursor? cur;
      Object? failure;
      try {
        cur = await _openCursorIn(command, sql, parameters, placeholder);
        while (!cancelled) {
          final row = await cur.fetchOne();
          if (row == null) break;
          controller.add(row);
          final waitResume = resumed;
          if (waitResume != null) await waitResume.future;
        }
      } catch (error, stackTrace) {
        failure = error;
        if (!cancelled) controller.addError(error, stackTrace);
      } finally {
        var affected = -1;
        try {
          final tdsCursor = cur?._cursor;
          if (cancelled && tdsCursor != null && !tdsCursor.isIdle) {
            await _session?.requestCancel(
                tds.MssqlCancelledException('Stream cancelled'));
          }
          if (cur != null && !cur.isClosed) affected = cur.affectedRows;
          await cur?.close();
        } catch (error) {
          failure ??= error;
        }
        _finishCommand(command, sql, parameters, placeholder,
            affectedRows: affected, error: failure);
        await controller.close();
      }
    }

    void wake() {
      resumed?.complete();
      resumed = null;
    }

    controller = StreamController<MssqlRow>(
      onListen: pump,
      onPause: () => resumed ??= Completer<void>(),
      onResume: wake,
      onCancel: () {
        cancelled = true;
        wake();
      },
    );
    return controller.stream;
  }

  /// Runs [sql] and returns a cursor positioned on the first result.
  ///
  /// The cursor holds the connection until it is fully read or closed.
  /// [timeout] applies until the first result arrives.
  Future<MssqlCursor> openCursor(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _runCommand(sql, parameters, placeholder, timeout, (command) async {
        final cur = await _openCursorIn(command, sql, parameters, placeholder);
        cur._command = null;
        return cur;
      }, affected: (cur) => cur.affectedRows);

  /// Calls the stored procedure [name] via RPC (without `EXEC` or
  /// `sp_executesql`).
  ///
  /// [parameters] is a [List] (positional) or a [Map] (by parameter name,
  /// with or without `@`). `OUTPUT` parameters use `SqlParameter.output`:
  ///
  /// ```dart
  /// final result = await conn.callProcedure('dbo.create_order', parameters: {
  ///   'customer': 42,
  ///   'order_id': SqlParameter.int(null).output(),
  /// });
  /// print(result.outputParameters['order_id']);
  /// print(result.returnStatus);
  /// ```
  Future<MssqlProcedureResult> callProcedure(
    String name, {
    Object? parameters,
    Duration? timeout,
  }) =>
      _runCommand(name, parameters, PlaceholderIdentifier.atSign, timeout,
          (command) async {
        final (list, map) = _splitParameters(parameters);
        final cur = cursor().._command = command;
        try {
          await cur
              ._run((c) => c.callproc(name, params: list, namedParams: map));
          final sets = await cur._readAllSets();
          final tdsCursor = cur._ensureOpen();
          return MssqlProcedureResult(
            resultSets: List.unmodifiable(sets),
            outputParameters: Map.unmodifiable(tdsCursor.outputParameters),
            returnStatus: tdsCursor.returnStatus,
            affectedRows: tdsCursor.rowcount,
          );
        } finally {
          await cur.close();
        }
      }, affected: (result) => result.affectedRows);

  /// Cancels the command running on this connection; call it from another
  /// asynchronous flow.
  ///
  /// The command throws `MssqlCancelledException` as soon as the server
  /// acknowledges, and the connection remains usable. Returns `false` if
  /// there was no command to cancel.
  Future<bool> cancel() async {
    if (_closed) return false;
    final reason = tds.MssqlCancelledException();
    final command = _activeCommand;
    if (command != null) return command.cancel(reason);
    return await _session?.requestCancel(reason) ?? false;
  }

  /// Runs [action] inside `BEGIN TRANSACTION`, with `COMMIT` at the end or
  /// `ROLLBACK` if [action] throws.
  ///
  /// During the transaction the connection is reserved: commands issued from
  /// inside [action] take part in it; commands from outside wait for it to
  /// end.
  ///
  /// [isolationLevel] applies only to this transaction: the session's
  /// previous level is restored at the end (SQL Server keeps it on the
  /// connection, and a pooled connection must not inherit it).
  ///
  /// When called inside another transaction, it creates a savepoint: if
  /// [action] throws, only its own work is undone (`ROLLBACK TRANSACTION` to
  /// the savepoint) and the error keeps propagating.
  ///
  /// A command that was cancelled or exceeded its `timeout` does not roll
  /// back the transaction on the server; if the error escapes [action], the
  /// `ROLLBACK` happens here.
  Future<T> transaction<T>(
    Future<T> Function(MssqlConnection connection) action, {
    IsolationLevel? isolationLevel,
  }) {
    if (inTransaction) {
      if (isolationLevel != null) {
        throw ArgumentError.value(isolationLevel, 'isolationLevel',
            'cannot be changed in a nested transaction');
      }
      return _nestedTransaction(action);
    }
    final token = Object();
    return runZoned(() async {
      await _acquire(token);
      try {
        var restore = '';
        if (isolationLevel == null) {
          await execute('BEGIN TRANSACTION');
        } else {
          final sets = await _runBatch(
              'SELECT transaction_isolation_level FROM sys.dm_exec_sessions '
              'WHERE session_id = @@SPID; '
              'SET TRANSACTION ISOLATION LEVEL ${isolationLevel.sql}; '
              'BEGIN TRANSACTION');
          final previous = sets.first.first[0] as int;
          restore = '; SET TRANSACTION ISOLATION LEVEL '
              '${_isolationLevelSql(previous)}';
        }
        final T result;
        try {
          result = await action(this);
        } catch (_) {
          await _rollbackQuietly(restore);
          rethrow;
        }
        try {
          await execute('COMMIT TRANSACTION$restore');
        } catch (_) {
          await _rollbackQuietly(restore);
          rethrow;
        }
        return result;
      } finally {
        _release(token);
      }
    }, zoneValues: {_txnKey: token});
  }

  /// Creates the savepoint [name] in the current transaction
  /// (`SAVE TRANSACTION`).
  ///
  /// ```dart
  /// await conn.transaction((tx) async {
  ///   await tx.execute('INSERT ...');
  ///   await tx.savepoint('before_items');
  ///   try {
  ///     await tx.execute('INSERT ...');
  ///   } on DatabaseException {
  ///     await tx.rollbackToSavepoint('before_items');
  ///   }
  /// });
  /// ```
  Future<void> savepoint(String name) async {
    _checkSavepoint(name);
    await execute('SAVE TRANSACTION $name');
  }

  /// Undoes the work done after the savepoint [name], keeping the
  /// transaction open (`ROLLBACK TRANSACTION name`).
  Future<void> rollbackToSavepoint(String name) async {
    _checkSavepoint(name);
    await execute('ROLLBACK TRANSACTION $name');
  }

  /// Closes the connection.
  ///
  /// Waiting commands fail with [tds.InterfaceException].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _owner = null;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
    await _socket.close();
  }

  static final RegExp _savepointName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,31}$');

  void _checkSavepoint(String name) {
    if (!inTransaction && !hasOpenTransaction) {
      throw tds.InterfaceException('Savepoints require an active transaction');
    }
    if (!_savepointName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name',
          'use letters, digits and _ (up to 32 chars, not starting with a digit)');
    }
  }

  Future<T> _nestedTransaction<T>(
      Future<T> Function(MssqlConnection connection) action) async {
    final name = 'mssql_dart_sp${++_savepointSeq}';
    await savepoint(name);
    try {
      return await action(this);
    } catch (_) {
      if (isOpen) {
        try {
          // With the transaction doomed (XACT_STATE() = -1) there is no way
          // back to the savepoint; the outer transaction rolls back
          // everything.
          await execute('IF XACT_STATE() = 1 ROLLBACK TRANSACTION $name');
        } catch (_) {
          // The original error is more useful.
        }
      }
      rethrow;
    }
  }

  Future<void> _rollbackQuietly(String restore) async {
    if (!isOpen) return;
    try {
      await execute('IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION$restore');
    } catch (_) {
      // The original error is more useful.
    }
  }

  static String _isolationLevelSql(int level) => switch (level) {
        1 => IsolationLevel.readUncommitted.sql,
        3 => IsolationLevel.repeatableRead.sql,
        4 => IsolationLevel.serializable.sql,
        5 => IsolationLevel.snapshot.sql,
        _ => IsolationLevel.readCommitted.sql,
      };

  /// Runs [sql] and reads all result sets, throwing errors from any
  /// statement in the batch.
  Future<List<MssqlResult>> _runBatch(String sql) =>
      _runCommand(sql, null, PlaceholderIdentifier.atSign, null,
          (command) async {
        final cur = await _openCursorIn(
            command, sql, null, PlaceholderIdentifier.atSign);
        try {
          return await cur._readAllSets();
        } finally {
          await cur.close();
        }
      });

  Future<MssqlCursor> _openCursorIn(_Command command, String sql,
      Object? parameters, PlaceholderIdentifier placeholder) async {
    final cur = cursor().._command = command;
    try {
      await cur._execute(sql, parameters, placeholder);
    } catch (_) {
      await cur.close();
      rethrow;
    }
    return cur;
  }

  /// Runs [body] as a command: deadline, cancellation and [onQuery].
  Future<R> _runCommand<R>(
    String sql,
    Object? parameters,
    PlaceholderIdentifier placeholder,
    Duration? timeout,
    Future<R> Function(_Command command) body, {
    int Function(R result)? affected,
  }) async {
    final command = _Command(this, timeout);
    final R result;
    try {
      result = await body(command);
    } catch (error) {
      _finishCommand(command, sql, parameters, placeholder, error: error);
      rethrow;
    }
    _finishCommand(command, sql, parameters, placeholder,
        affectedRows: affected?.call(result));
    return result;
  }

  void _finishCommand(
    _Command command,
    String sql,
    Object? parameters,
    PlaceholderIdentifier placeholder, {
    int? affectedRows,
    Object? error,
  }) {
    command.finish();
    final hook = onQuery;
    if (hook == null) return;
    var sentSql = sql;
    if (placeholder == PlaceholderIdentifier.onlyQuestionMark) {
      sentSql = convertQuestionMarks(sql).sql;
    }
    final event = MssqlQueryEvent(
      sql: sentSql,
      parameters: parameters,
      elapsed: command.elapsed,
      affectedRows:
          affectedRows == null || affectedRows < 0 ? null : affectedRows,
      error: error,
    );
    try {
      hook(event);
    } catch (hookError, stackTrace) {
      // A failure in the hook must not change the command's result.
      Zone.current.handleUncaughtError(hookError, stackTrace);
    }
  }

  /// Interrupts [command] for [reason]: if it is using the session, sends
  /// the ATTENTION; between two requests, the next one fails without being
  /// sent.
  Future<bool> _interrupt(_Command command, tds.MssqlException reason) async {
    if (_closed) return false;
    if (!identical(_activeCommand, command)) return true;
    final session = _session;
    if (session == null) return false;
    if (await session.requestCancel(reason)) return true;
    if (identical(_activeCommand, command)) {
      session.cancelBeforeNextRequest = reason;
    }
    return true;
  }

  /// [command] starts using the session; its deadline is also checked on
  /// every token read (see [AsyncTdsSession.setDeadline]).
  void _activate(_Command command) {
    _activeCommand = command;
    final limit = command.timeout;
    if (limit != null && command.cancelReason == null) {
      _session?.setDeadline(command, limit - command.elapsed,
          () => command.cancel(tds.MssqlTimeoutException(limit)));
    }
  }

  void _commandFinished(_Command command) {
    if (identical(_activeCommand, command)) _activeCommand = null;
    final session = _session;
    session?.clearDeadline(command);
    final reason = command.cancelReason;
    if (session != null &&
        reason != null &&
        identical(session.cancelBeforeNextRequest, reason)) {
      session.cancelBeforeNextRequest = null;
    }
  }

  AsyncTdsSocket _ensureOpen() {
    if (_closed) {
      throw tds.InterfaceException('The connection is already closed.');
    }
    return _socket;
  }

  Future<T> _serial<T>(Future<T> Function() action) =>
      _ensureOpen().runSerial((_) => action());

  Object _effectiveOwner(Object candidate) =>
      Zone.current[_txnKey] ?? candidate;

  Future<void> _acquire(Object owner, [_Command? command]) async {
    while (true) {
      _ensureOpen();
      command?.throwIfCancelled();
      final current = _owner;
      if (current == null || identical(current, owner)) {
        _owner = owner;
        return;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      if (command == null) {
        await waiter.future;
        continue;
      }
      await Future.any([waiter.future, command.cancelled]);
      if (!waiter.isCompleted) {
        _waiters.remove(waiter);
      } else if (command.cancelReason != null &&
          _owner == null &&
          _waiters.isNotEmpty) {
        // Our turn came, but the command is giving up: hand over to the next.
        _waiters.removeFirst().complete();
      }
    }
  }

  void _release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
  }
}

/// A logical command (one or more requests): deadline and cancellation.
class _Command {
  _Command(this.connection, Duration? timeout)
      : timeout = timeout ?? connection.commandTimeout {
    final limit = this.timeout;
    if (limit != null) {
      _timer = Timer(limit, () => cancel(tds.MssqlTimeoutException(limit)));
    }
  }

  final MssqlConnection connection;
  final Duration? timeout;
  final Stopwatch _watch = Stopwatch()..start();
  final Completer<void> _cancelled = Completer<void>();
  Timer? _timer;

  /// The cancellation reason, if cancelled.
  tds.MssqlException? cancelReason;

  Duration get elapsed => _watch.elapsed;

  /// Completes when the command is cancelled.
  Future<void> get cancelled => _cancelled.future;

  void throwIfCancelled() {
    final reason = cancelReason;
    if (reason != null) throw reason;
  }

  Future<bool> cancel(tds.MssqlException reason) {
    if (cancelReason != null) return Future.value(true);
    cancelReason = reason;
    _timer?.cancel();
    _cancelled.complete();
    return connection._interrupt(this, reason);
  }

  void finish() {
    _timer?.cancel();
    _watch.stop();
    connection._commandFinished(this);
  }
}

/// A cursor for reading results row by row and iterating over multiple
/// result sets.
///
/// Close it with [close] when done.
class MssqlCursor {
  MssqlCursor._(this._connection, this._cursor);

  final MssqlConnection _connection;
  AsyncTdsCursor? _cursor;
  RowSchema? _schema;
  List<List<dynamic>>? _schemaSource;

  /// The command whose deadline and cancellation apply to cursor operations.
  _Command? _command;

  /// Runs [sql]; [parameters] is a [List] (positional) or a [Map].
  ///
  /// [timeout] applies until the first result arrives.
  Future<void> execute(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _connection._runCommand(sql, parameters, placeholder, timeout,
          (command) async {
        _command = command;
        try {
          await _execute(sql, parameters, placeholder);
        } finally {
          _command = null;
        }
      });

  /// Runs [sql] once per item of [parameterSets], in batches (see
  /// [MssqlConnection.executeMany]).
  Future<void> executeMany(
    String sql,
    Iterable<Object?> parameterSets, {
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      _connection._runCommand(sql, parameterSets, placeholder, timeout,
          (command) async {
        _command = command;
        try {
          await _executeMany(sql, parameterSets, placeholder);
        } finally {
          _command = null;
        }
      });

  Future<void> _execute(
      String sql, Object? parameters, PlaceholderIdentifier placeholder) {
    final (list, map) = _splitParameters(parameters);
    return _run((cursor) => cursor.execute(sql,
        params: list, namedParams: map, placeholderIdentifier: placeholder));
  }

  Future<void> _executeMany(String sql, Iterable<Object?> parameterSets,
      PlaceholderIdentifier placeholder) {
    return _run((cursor) => cursor.executemany(sql, parameterSets,
        placeholderIdentifier: placeholder));
  }

  /// Returns the next row of the current result set, or `null` at the end.
  Future<MssqlRow?> fetchOne() async {
    final row = await _run((cursor) => cursor.fetchone());
    return row == null
        ? null
        : MssqlRow(row as List<Object?>, _currentSchema());
  }

  /// Returns all remaining rows of the current result set.
  Future<List<MssqlRow>> fetchAll() async {
    final rows = await _run((cursor) => cursor.fetchall());
    if (rows.isEmpty) return const [];
    final schema = _currentSchema();
    return [for (final row in rows) MssqlRow(row as List<Object?>, schema)];
  }

  /// Advances to the next result set; returns `false` when there are no more.
  Future<bool> nextSet() => _run((cursor) => cursor.nextset());

  /// The columns of the current result set.
  List<MssqlColumn> get columns => _currentSchema().columns;

  /// Rows affected as reported by the server, or -1.
  int get affectedRows => _ensureOpen().rowcount;

  /// The last command's `OUTPUT` parameters, keyed by name without the `@`;
  /// complete once the whole response has been read.
  Map<String, Object?> get outputParameters =>
      Map.unmodifiable(_ensureOpen().outputParameters);

  bool get isClosed => _cursor == null || _connection._closed;

  /// Closes the cursor, discarding unread data and releasing the connection.
  Future<void> close() async {
    final cursor = _cursor;
    if (cursor == null) return;
    _cursor = null;
    final owner = _connection._effectiveOwner(this);
    try {
      if (!_connection._closed && identical(_connection._owner, owner)) {
        await _connection._serial(() => cursor.close());
      }
    } finally {
      if (identical(owner, this)) _connection._release(this);
    }
  }

  /// Reads all remaining result sets.
  Future<List<MssqlResult>> _readAllSets() async {
    final sets = <MssqlResult>[];
    do {
      if (_ensureOpen().hasCurrentResult) {
        final rows = await fetchAll();
        sets.add(
            MssqlResult(rows, columns: columns, affectedRows: affectedRows));
      }
    } while (await nextSet());
    return sets;
  }

  RowSchema _currentSchema() {
    final description = _ensureOpen().description?.description ?? const [];
    if (!identical(description, _schemaSource)) {
      _schemaSource = description;
      _schema = RowSchema(MssqlColumn.fromDescription(description));
    }
    return _schema!;
  }

  AsyncTdsCursor _ensureOpen() {
    final cursor = _cursor;
    if (cursor == null || _connection._closed) {
      throw tds.InterfaceException('Cursor closed');
    }
    return cursor;
  }

  Future<T> _run<T>(Future<T> Function(AsyncTdsCursor cursor) action) async {
    final command = _command;
    final owner = _connection._effectiveOwner(this);
    await _connection._acquire(owner, command);
    try {
      return await _connection._serial(() {
        if (command != null) {
          command.throwIfCancelled();
          _connection._activate(command);
        }
        return action(_ensureOpen());
      });
    } finally {
      final cursor = _cursor;
      // Outside a transaction, the connection is released as soon as the
      // response ends.
      if (identical(owner, this) &&
          (cursor == null || cursor.isIdle || !_connection.isOpen)) {
        _connection._release(this);
      }
    }
  }
}

(List<dynamic>?, Map<String, dynamic>?) _splitParameters(Object? parameters) =>
    switch (parameters) {
      null => (null, null),
      List<dynamic> list => (list, null),
      Map<String, dynamic> map => (null, map),
      _ => throw ArgumentError.value(parameters, 'parameters',
          'use List (positional) or Map<String, Object?>'),
    };
