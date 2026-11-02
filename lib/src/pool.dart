import 'dart:async';
import 'dart:collection';

import 'connect.dart' show applySessionSetup;
import 'connection.dart';
import 'placeholders.dart';
import 'query_hook.dart';
import 'result.dart';
import 'session_reset.dart';
import 'settings.dart';
import 'tds_base.dart' as tds;

/// A connection pool for concurrent applications such as HTTP servers.
///
/// ```dart
/// final pool = MssqlPool(settings, maxConnections: 20, minConnections: 2);
/// final rows = await pool.query('SELECT name FROM users WHERE id = @p0', parameters: [id]);
/// await pool.transaction((conn) async {
///   await conn.execute('UPDATE accounts SET balance -= @p0 WHERE id = @p1', parameters: [10, a]);
///   await conn.execute('UPDATE accounts SET balance += @p0 WHERE id = @p1', parameters: [10, b]);
/// });
/// await pool.close();
/// ```
///
/// Each operation uses an exclusive connection, returned to the pool when it
/// finishes. Broken connections are discarded, a transaction left open is
/// rolled back before the connection is returned, connections idle for
/// longer than [idleTimeout] are closed (without going below
/// [minConnections]) and those idle for longer than [validateAfterIdle] are
/// checked with `SELECT 1` before being handed out.
///
/// With [resetSessionState], a connection whose session state was changed by
/// a command without parameters (`SET ...`, `USE`, `EXECUTE AS`, a temporary
/// table, `sp_set_session_context`) is not returned to the pool as is: it is
/// reset with RESETCONNECTION when the session supports it
/// ([ResettableSession]), or discarded otherwise. Commands with parameters
/// run inside `sp_executesql`, whose scope already undoes SETs and temporary
/// tables.
class MssqlPool {
  MssqlPool(
    this.settings, {
    this.maxConnections = 10,
    this.minConnections = 0,
    this.idleTimeout = const Duration(minutes: 10),
    this.acquireTimeout = const Duration(seconds: 30),
    this.validateAfterIdle = const Duration(seconds: 30),
    this.maxLifetime,
    this.onConnect,
    this.onQuery,
    this.resetSessionState = true,
  }) {
    if (maxConnections < 1) {
      throw ArgumentError.value(
          maxConnections, 'maxConnections', 'must be >= 1');
    }
    if (minConnections < 0 || minConnections > maxConnections) {
      throw ArgumentError.value(minConnections, 'minConnections',
          'must be between 0 and maxConnections ($maxConnections)');
    }
    _reaper = Timer.periodic(_reapInterval, (_) => _maintain());
    if (minConnections > 0) _scheduleFill();
  }

  final MssqlConnectionSettings settings;

  /// Maximum number of open connections (in use, idle and being opened).
  final int maxConnections;

  /// Number of connections kept open even when idle.
  ///
  /// They are opened in the background right after the pool is created and
  /// replaced when they drop; if the server is down, retries continue with
  /// increasing backoff (up to 30 s), without throwing errors.
  final int minConnections;

  /// Connections idle for longer than this are closed.
  final Duration idleTimeout;

  /// How long [withConnection] waits for a free connection before failing.
  final Duration acquireTimeout;

  /// Connections idle for longer than this are validated before use.
  final Duration validateAfterIdle;

  /// Maximum age of a connection; once exceeded, it is closed when returned.
  final Duration? maxLifetime;

  /// Runs on each new connection before it enters the pool (and again after
  /// a session reset), for example to `SET LOCK_TIMEOUT 5000`.
  ///
  /// If it throws, the connection is closed and the error goes to the caller
  /// that requested the connection.
  final FutureOr<void> Function(MssqlConnection connection)? onConnect;

  /// Assigned to [MssqlConnection.onQuery] of each connection handed out by
  /// the pool; can be changed at any time.
  MssqlQueryHook? onQuery;

  /// Whether to reset (or discard) connections whose session state was
  /// changed.
  final bool resetSessionState;

  final Queue<_PooledConnection> _idle = Queue();
  final Set<_PooledConnection> _inUse = {};
  final Queue<_Waiter> _waiters = Queue();
  int _total = 0;
  int _closing = 0;
  bool _closed = false;
  late final Timer _reaper;
  Completer<void>? _drained;

  bool _filling = false;
  Timer? _fillRetry;
  Duration _fillBackoff = Duration.zero;
  static const Duration _maxFillBackoff = Duration(seconds: 30);

  int _opened = 0;
  int _closedCount = 0;
  int _failedConnects = 0;
  int _acquireTimeouts = 0;
  int _resets = 0;

  Duration get _reapInterval {
    final half = idleTimeout ~/ 2;
    return half < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : half;
  }

  /// Connections open or being opened.
  int get totalConnections => _total;

  /// Free connections in the pool.
  int get idleConnections => _idle.length;

  /// Connections handed out and not yet returned.
  int get inUseConnections => _inUse.length;

  /// Calls waiting for a connection.
  int get waitingRequests => _waiters.length;

  bool get isClosed => _closed;

  /// A snapshot of the pool counters, for metrics and diagnostics.
  MssqlPoolStats get stats => MssqlPoolStats(
        total: _total,
        idle: _idle.length,
        inUse: _inUse.length,
        waiting: _waiters.length,
        opened: _opened,
        closed: _closedCount,
        failedConnects: _failedConnects,
        acquireTimeouts: _acquireTimeouts,
        resets: _resets,
      );

  /// Runs [action] with an exclusive connection and returns it to the pool
  /// afterwards.
  Future<T> withConnection<T>(
      Future<T> Function(MssqlConnection connection) action) async {
    final pooled = await _acquire();
    try {
      return await action(pooled.connection);
    } finally {
      await _releaseConnection(pooled);
    }
  }

  /// Runs [action] in a transaction ([MssqlConnection.transaction]).
  Future<T> transaction<T>(
    Future<T> Function(MssqlConnection connection) action, {
    IsolationLevel? isolationLevel,
  }) =>
      withConnection(
          (conn) => conn.transaction(action, isolationLevel: isolationLevel));

  /// Runs [MssqlConnection.query] on a pooled connection.
  Future<MssqlResult> query(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.query(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.queryFirst] on a pooled connection.
  Future<MssqlRow?> queryFirst(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.queryFirst(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.querySingle] on a pooled connection.
  Future<MssqlRow> querySingle(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.querySingle(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.queryScalar] on a pooled connection.
  Future<T?> queryScalar<T>(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.queryScalar<T>(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.queryMaps] on a pooled connection.
  Future<List<Map<String, Object?>>> queryMaps(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.queryMaps(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.execute] on a pooled connection.
  Future<int> execute(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.execute(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.executeMany] on a pooled connection.
  Future<int> executeMany(
    String sql,
    Iterable<Object?> parameterSets, {
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) =>
      withConnection((conn) => conn.executeMany(sql, parameterSets,
          placeholder: placeholder, timeout: timeout));

  /// Runs [MssqlConnection.callProcedure] on a pooled connection.
  Future<MssqlProcedureResult> callProcedure(
    String name, {
    Object? parameters,
    Duration? timeout,
  }) =>
      withConnection((conn) =>
          conn.callProcedure(name, parameters: parameters, timeout: timeout));

  /// Runs [MssqlConnection.stream] on a pooled connection, returned when the
  /// stream ends (or when the subscription is cancelled).
  Stream<MssqlRow> stream(
    String sql, {
    Object? parameters,
    PlaceholderIdentifier placeholder = PlaceholderIdentifier.atSign,
    Duration? timeout,
  }) async* {
    final pooled = await _acquire();
    try {
      yield* pooled.connection.stream(sql,
          parameters: parameters, placeholder: placeholder, timeout: timeout);
    } finally {
      await _releaseConnection(pooled);
    }
  }

  /// Rejects new operations, closes the free connections and waits for the
  /// ones in use to be returned, closing them afterwards.
  ///
  /// Without [timeout], waits indefinitely. With [timeout], connections still
  /// in use when it expires are force-closed (operations on them fail with
  /// [tds.ClosedConnectionException] or [tds.InterfaceException]);
  /// [Duration.zero] closes everything immediately.
  Future<void> close({Duration? timeout}) async {
    if (!_closed) {
      _closed = true;
      _reaper.cancel();
      _fillRetry?.cancel();
      _fillRetry = null;
      while (_waiters.isNotEmpty) {
        _waiters
            .removeFirst()
            .completer
            .completeError(tds.InterfaceException('The pool is closed'));
      }
      final idle = List.of(_idle);
      _idle.clear();
      await Future.wait(idle.map(_discard));
    }
    if (_isDrained) return;
    final drained = (_drained ??= Completer<void>()).future;
    if (timeout == null) return drained;
    try {
      await drained.timeout(timeout);
    } on TimeoutException {
      // Connections still being opened are closed as soon as they finish.
      await Future.wait(List.of(_inUse).map(_discard));
    }
  }

  bool get _isDrained => _total == 0 && _closing == 0;

  void _checkDrained() {
    if (_closed && _isDrained) {
      final drained = _drained;
      if (drained != null && !drained.isCompleted) drained.complete();
    }
  }

  Future<_PooledConnection> _acquire() async {
    while (true) {
      if (_closed) throw tds.InterfaceException('The pool is closed');
      if (_idle.isNotEmpty) {
        final pooled = _idle.removeLast(); // the most recent one is "warm"
        _inUse.add(pooled);
        if (!await _isUsable(pooled)) continue;
        if (_closed) {
          await _discard(pooled);
          throw tds.InterfaceException('The pool is closed');
        }
        return _checkout(pooled);
      }
      if (_total < maxConnections) {
        return _checkout(await _open());
      }
      final waiter = _Waiter();
      _waiters.add(waiter);
      try {
        return await waiter.completer.future.timeout(acquireTimeout);
      } on TimeoutException {
        waiter.abandoned = true;
        _waiters.remove(waiter);
        _acquireTimeouts++;
        throw tds.OperationalException(
          'No free connection in the pool within $acquireTimeout '
          '($_total of $maxConnections in use)',
        );
      }
    }
  }

  /// Marks [pooled] as in use and installs the query hook.
  _PooledConnection _checkout(_PooledConnection pooled) {
    _inUse.add(pooled);
    pooled.connection.onQuery = (event) {
      if (resetSessionState &&
          !pooled.dirty &&
          changesSessionState(event.sql, event.parameters)) {
        pooled.dirty = true;
      }
      onQuery?.call(event);
    };
    return pooled;
  }

  Future<_PooledConnection> _open() async {
    _total++; // count before connecting, so the limit is never exceeded
    MssqlConnection? connection;
    try {
      connection = await MssqlConnection.connect(settings);
      final callback = onConnect;
      if (callback != null) await callback(connection);
    } catch (_) {
      _total--;
      _failedConnects++;
      if (connection != null) unawaited(_closeQuietly(connection));
      _checkDrained();
      _wakeWaiterToOpen();
      rethrow;
    }
    _opened++;
    final pooled = _PooledConnection(connection, _currentDatabase(connection));
    if (_closed) {
      await _discard(pooled);
      throw tds.InterfaceException('The pool is closed');
    }
    return pooled;
  }

  Future<bool> _isUsable(_PooledConnection pooled) async {
    if (!pooled.connection.isOpen || _expired(pooled)) {
      await _discard(pooled);
      return false;
    }
    if (DateTime.now().difference(pooled.lastUsed) > validateAfterIdle) {
      try {
        await pooled.connection.execute('SELECT 1');
      } catch (_) {
        await _discard(pooled);
        return false;
      }
    }
    return true;
  }

  bool _expired(_PooledConnection pooled) {
    final lifetime = maxLifetime;
    return lifetime != null &&
        DateTime.now().difference(pooled.created) > lifetime;
  }

  Future<void> _releaseConnection(_PooledConnection pooled) async {
    if (pooled.discarded) return; // force-closed by close()
    final connection = pooled.connection;
    connection.onQuery = null; // internal commands do not reach the hook
    if (connection.isOpen && connection.hasOpenTransaction) {
      try {
        await connection.execute('IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION');
      } catch (_) {
        await _discard(pooled);
        return;
      }
    }
    if (_closed || !connection.isOpen || _expired(pooled)) {
      await _discard(pooled);
      return;
    }
    if (resetSessionState && _needsReset(pooled)) {
      if (!await _resetSession(pooled)) {
        await _discard(pooled);
        return;
      }
    }
    if (pooled.discarded) return;
    _inUse.remove(pooled);
    _handOver(pooled);
  }

  /// Hands [pooled] to a waiter or leaves it free in the pool.
  void _handOver(_PooledConnection pooled) {
    pooled.lastUsed = DateTime.now();
    if (_closed) {
      unawaited(_discard(pooled));
      return;
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().completer.complete(_checkout(pooled));
      return;
    }
    _idle.addLast(pooled);
  }

  bool _needsReset(_PooledConnection pooled) {
    if (pooled.dirty) return true;
    final initial = pooled.initialDatabase;
    final current = _currentDatabase(pooled.connection);
    return initial != null &&
        current != null &&
        initial.toLowerCase() != current.toLowerCase();
  }

  /// Resets the session with RESETCONNECTION and reapplies the driver
  /// options and [onConnect]; returns `false` when the session does not
  /// support it.
  Future<bool> _resetSession(_PooledConnection pooled) async {
    final connection = pooled.connection;
    final Object session = connection.tdsSocket.mainSession;
    if (session is! ResettableSession) return false;
    try {
      session.resetConnectionOnNextRequest();
      await applySessionSetup(connection.tdsSocket);
      final callback = onConnect;
      if (callback != null) await callback(connection);
      connection.onQuery = null;
    } catch (_) {
      return false;
    }
    pooled.dirty = false;
    _resets++;
    return true;
  }

  String? _currentDatabase(MssqlConnection connection) {
    try {
      return connection.tdsSocket.env.database;
    } catch (_) {
      return null;
    }
  }

  Future<void> _discard(_PooledConnection pooled) async {
    if (pooled.discarded) return;
    pooled.discarded = true;
    _inUse.remove(pooled);
    _idle.remove(pooled);
    _total--;
    _closedCount++;
    _closing++;
    try {
      await _closeQuietly(pooled.connection);
    } finally {
      _closing--;
    }
    _checkDrained();
    _wakeWaiterToOpen();
    if (_total < minConnections) _scheduleFill();
  }

  Future<void> _closeQuietly(MssqlConnection connection) async {
    try {
      await connection.close();
    } catch (_) {
      // It was already broken.
    }
  }

  /// A slot was freed: a waiter can open a new connection.
  void _wakeWaiterToOpen() {
    if (_closed || _total >= maxConnections) return;
    if (_waiters.isEmpty) return;
    final waiter = _waiters.removeFirst();
    _open().then((pooled) {
      // The waiter gave up (timeout): the connection goes back to the pool.
      if (waiter.abandoned) {
        _handOver(pooled);
      } else {
        waiter.completer.complete(_checkout(pooled));
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!waiter.abandoned) waiter.completer.completeError(error, stackTrace);
    });
  }

  void _maintain() {
    final now = DateTime.now();
    // Oldest first; idle ones are only closed above minConnections.
    for (final pooled in List.of(_idle)) {
      final stale = now.difference(pooled.lastUsed) > idleTimeout;
      if (_expired(pooled) ||
          !pooled.connection.isOpen ||
          (stale && _total > minConnections)) {
        unawaited(_discard(pooled));
      }
    }
    if (_total < minConnections) _scheduleFill();
  }

  /// Opens connections up to [minConnections], in the background.
  void _scheduleFill() {
    if (_closed || _filling || _fillRetry != null) return;
    _filling = true;
    scheduleMicrotask(() async {
      var failed = false;
      try {
        final missing = minConnections - _total;
        final room = maxConnections - _total;
        final count = missing < room ? missing : room;
        await Future.wait([
          for (var i = 0; i < count; i++)
            _open().then(_handOver, onError: (Object _) {
              failed = true;
            }),
        ]);
      } finally {
        _filling = false;
      }
      if (_closed) return;
      if (failed) {
        _fillBackoff = _fillBackoff == Duration.zero
            ? const Duration(milliseconds: 500)
            : _fillBackoff * 2;
        if (_fillBackoff > _maxFillBackoff) _fillBackoff = _maxFillBackoff;
        _fillRetry = Timer(_fillBackoff, () {
          _fillRetry = null;
          _scheduleFill();
        });
      } else {
        _fillBackoff = Duration.zero;
        if (_total < minConnections) _scheduleFill();
      }
    });
  }
}

/// Counters of a [MssqlPool] at a point in time.
class MssqlPoolStats {
  const MssqlPoolStats({
    required this.total,
    required this.idle,
    required this.inUse,
    required this.waiting,
    required this.opened,
    required this.closed,
    required this.failedConnects,
    required this.acquireTimeouts,
    required this.resets,
  });

  /// Connections open or being opened.
  final int total;

  /// Free connections.
  final int idle;

  /// Connections handed out and not returned.
  final int inUse;

  /// Calls waiting for a connection.
  final int waiting;

  /// Connections opened successfully since the pool was created.
  final int opened;

  /// Connections closed by the pool (idle, expired, broken...).
  final int closed;

  /// Failed connection attempts (including [MssqlPool.onConnect] failures).
  final int failedConnects;

  /// Requests that gave up after [MssqlPool.acquireTimeout].
  final int acquireTimeouts;

  /// Sessions reset with RESETCONNECTION.
  final int resets;

  @override
  String toString() => 'MssqlPoolStats(total: $total, idle: $idle, '
      'inUse: $inUse, waiting: $waiting, opened: $opened, closed: $closed, '
      'failedConnects: $failedConnects, acquireTimeouts: $acquireTimeouts, '
      'resets: $resets)';
}

/// Whether a command may have changed the session state in a way that leaks
/// to the connection's next user.
///
/// A conservative heuristic over the SQL text. Commands with parameters run
/// inside `sp_executesql`, which undoes SETs, `USE`, `EXECUTE AS` and local
/// temporary tables when it finishes; only `sp_set_session_context`,
/// `CONTEXT_INFO` and global temporary tables (`##`) survive. A database
/// change via `USE` is also detected through the server's ENVCHANGE.
bool changesSessionState(String sql, Object? parameters) {
  if (_persistentStatePattern.hasMatch(sql)) return true;
  final plainBatch = parameters == null ||
      (parameters is List && parameters.isEmpty) ||
      (parameters is Map && parameters.isEmpty);
  return plainBatch && _batchStatePattern.hasMatch(sql);
}

final RegExp _persistentStatePattern = RegExp(
  r'sp_set_session_context|\bCONTEXT_INFO\b|(CREATE\s+TABLE|INTO)\s+##',
  caseSensitive: false,
);

final RegExp _batchStatePattern = RegExp(
  r'(?<![\w@#$])SET\s+(TRANSACTION\s+ISOLATION|ANSI_\w+|QUOTED_IDENTIFIER|'
  r'ARITHABORT|ARITHIGNORE|NOCOUNT|LANGUAGE|DATEFORMAT|DATEFIRST|'
  r'LOCK_TIMEOUT|XACT_ABORT|TEXTSIZE|IMPLICIT_TRANSACTIONS|'
  r'CONCAT_NULL_YIELDS_NULL|NUMERIC_ROUNDABORT|DEADLOCK_PRIORITY|ROWCOUNT|'
  r'CURSOR_CLOSE_ON_COMMIT|FMTONLY|NOEXEC|PARSEONLY|SHOWPLAN_\w+|'
  r'STATISTICS|FORCEPLAN|QUERY_GOVERNOR_COST_LIMIT|REMOTE_PROC_TRANSACTIONS|'
  r'NO_BROWSETABLE|IDENTITY_INSERT|OFFSETS)\b(?!\s*[-+*/%&|^]?=)'
  r'|(?<![\w@#$])EXEC(UTE)?\s+AS\s+(LOGIN|USER)\b'
  r'|\bSETUSER\b|sp_setapprole'
  r'|(CREATE\s+TABLE|INTO)\s+#',
  caseSensitive: false,
);

class _Waiter {
  final Completer<_PooledConnection> completer = Completer();
  bool abandoned = false;
}

class _PooledConnection {
  _PooledConnection(this.connection, this.initialDatabase)
      : created = DateTime.now(),
        lastUsed = DateTime.now();

  final MssqlConnection connection;
  final String? initialDatabase;
  final DateTime created;
  DateTime lastUsed;

  /// A command may have changed the session state.
  bool dirty = false;

  /// Already closed and removed from the pool count.
  bool discarded = false;
}
