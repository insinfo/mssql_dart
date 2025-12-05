import 'dart:async';

import 'async_cursor.dart';
import 'async_tds_socket.dart';
import 'tds_base.dart' as tds;

final tds.InterfaceError _asyncClosedConnectionError =
    tds.InterfaceError('Conexão assíncrona já foi fechada.');

/// Camada DB-API simplificada para uso com [AsyncTdsSocket]. Ela garante que
/// chamadas concorrentes sejam serializadas e que apenas um cursor mantenha um
/// comando ativo por vez.
class AsyncDbConnection {
  AsyncDbConnection._(this._socket);

  final AsyncTdsSocket _socket;
  bool _closed = false;
  AsyncDbCursor? _activeCursor;
  Completer<void>? _cursorWaiter;

  AsyncDbCursor cursor() {
    final session = _ensureOpen().cursor();
    return AsyncDbCursor._(this, AsyncTdsCursor(session));
  }

  Future<AsyncDbCursor> execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) async {
    final cur = cursor();
    await cur.execute(sql, params: params, namedParams: namedParams);
    return cur;
  }

  Future<AsyncDbCursor> executemany(
    String sql,
    Iterable<dynamic> paramSets,
  ) async {
    final cur = cursor();
    await cur.executemany(sql, paramSets);
    return cur;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _activeCursor = null;
    _cursorWaiter?.complete();
    _cursorWaiter = null;
    await _socket.close();
    _closed = true;
  }

  bool get isClosed => _closed;

  AsyncTdsSocket get socket => _ensureOpen();

  AsyncTdsSocket _ensureOpen() {
    if (_closed) {
      throw _asyncClosedConnectionError;
    }
    return _socket;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    return socket.runSerial((_) => action());
  }

  Future<void> _acquireCursor(AsyncDbCursor cursor) async {
    while (true) {
      final current = _activeCursor;
      if (current == null || identical(current, cursor)) {
        _activeCursor = cursor;
        return;
      }
      final waiter = _cursorWaiter ??= Completer<void>();
      await waiter.future;
    }
  }

  void _releaseCursor(AsyncDbCursor cursor) {
    if (!identical(_activeCursor, cursor)) {
      return;
    }
    _activeCursor = null;
    final waiter = _cursorWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    _cursorWaiter = null;
  }
}

class AsyncDbCursor {
  AsyncDbCursor._(this._connection, this._cursor);

  final AsyncDbConnection _connection;
  AsyncTdsCursor? _cursor;

  Future<void> execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) {
    return _runSerial((cursor) async {
      await cursor.execute(
        sql,
        params: params,
        namedParams: namedParams,
      );
    });
  }

  Future<void> executemany(String sql, Iterable<dynamic> paramSets) {
    return _runSerial((cursor) => cursor.executemany(sql, paramSets));
  }

  Future<dynamic> fetchone() {
    return _runSerial((cursor) => cursor.fetchone());
  }

  Future<List<dynamic>> fetchall() {
    return _runSerial((cursor) => cursor.fetchall());
  }

  Future<bool> nextset() {
    return _runSerial((cursor) => cursor.nextset());
  }

  Future<void> close() async {
    _cursor = null;
    _connection._releaseCursor(this);
  }

  bool get isClosed => _cursor == null || _connection.isClosed;

  tds.Results? get description => _ensureOpen().description;
  int get rowcount => _ensureOpen().rowcount;

  AsyncTdsCursor _ensureOpen() {
    final cursor = _cursor;
    if (cursor == null || _connection.isClosed) {
      throw tds.InterfaceError('Cursor assíncrono fechado');
    }
    return cursor;
  }

  Future<T> _runSerial<T>(Future<T> Function(AsyncTdsCursor cursor) action) async {
    await _connection._acquireCursor(this);
    try {
      final result = await _connection._serial(() async {
        final cursor = _ensureOpen();
        return await action(cursor);
      });
      _releaseIfIdle();
      return result;
    } catch (_) {
      _releaseIfIdle();
      rethrow;
    }
  }

  void _releaseIfIdle() {
    final cursor = _cursor;
    if (cursor == null || cursor.isIdle) {
      _connection._releaseCursor(this);
    }
  }
}

AsyncDbConnection asyncDbConnectionFromSocket(AsyncTdsSocket socket) {
  return AsyncDbConnection._(socket);
}
