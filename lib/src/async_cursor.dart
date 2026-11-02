import 'dart:async';
import 'dart:collection';

import 'tds_base.dart' as tds;
import 'async_tds_session.dart';
import 'placeholders.dart';

/// Asynchronous cursor modeled on the DB-API. Tracks the current state of
/// the `AsyncTdsSession` while running sequential commands.
class AsyncTdsCursor {
  AsyncTdsCursor(this._session);

  final AsyncTdsSession _session;
  bool _hasPendingCommand = false;
  bool _hasCurrentResult = false;
  bool _open = false;
  int? _rowcountOverride;

  tds.Results? get description => _session.results;

  /// Whether the cursor is positioned on a result set not yet fully read.
  bool get hasCurrentResult => _hasCurrentResult;

  /// OUTPUT parameters returned by the last command (see
  /// [AsyncTdsSession.outputParameters]).
  Map<String, Object?> get outputParameters => _session.outputParameters;

  /// `RETURN` value of the procedure called by the last command.
  int? get returnStatus => _session.returnStatus;
  int get rowcount => _rowcountOverride ?? _session.rowsAffected;
  bool get isIdle => _session.state == tds.TDS_IDLE;

  Future<void> execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) async {
    sql = prepareSql(sql, placeholderIdentifier, params, namedParams);
    _rowcountOverride = null;
    await _finishActiveRequest();
    // Another cursor may have left a half-read response on the same session.
    await _session.drainPending();
    final bindings = _buildBindings(params, namedParams);
    if (bindings.isEmpty) {
      await _session.submitPlainQuery(sql);
    } else {
      await _session.submitExecSql(sql, bindings);
    }
    await _positionOnFirstResult();
  }

  /// Calls the procedure [name] via RPC, with positional [params] and/or
  /// [namedParams].
  Future<void> callproc(
    String name, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) async {
    _rowcountOverride = null;
    await _finishActiveRequest();
    await _session.drainPending();
    final list = <(String, Object?)>[
      if (params != null)
        for (final value in params) ('', value),
      if (namedParams != null)
        for (final entry in namedParams.entries) (entry.key, entry.value),
    ];
    await _session.submitProcedureCall(name, list);
    await _positionOnFirstResult();
  }

  Future<void> _positionOnFirstResult() async {
    await _session.beginResponse();
    _hasPendingCommand = true;
    await _session.findResultOrDone();
    _hasCurrentResult = _session.results != null;
    _open = true;
    if (!_hasCurrentResult && _session.state == tds.TDS_IDLE) {
      _open = false;
    }
  }

  /// Executes the same statement once per item of [paramSets], each item
  /// being a list or a map of parameters.
  ///
  /// Items are sent in RPC batches ([AsyncTdsSession.executeRpcBatch]) of up
  /// to [batchSize] items per message; with `batchSize: 1` each item is a
  /// separate request and execution stops at the first error.
  Future<void> executemany(
    String sql,
    Iterable<dynamic> paramSets, {
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
    int batchSize = 1000,
  }) async {
    _rowcountOverride = null;
    await _finishActiveRequest();
    await _session.drainPending();
    var total = 0;
    var canAggregate = true;
    String? prepared;
    final chunk = <Map<String, dynamic>>[];

    Future<void> flush() async {
      if (chunk.isEmpty) return;
      final count = batchSize <= 1 && chunk.length == 1
          ? await _executeSingle(prepared!, chunk.first)
          : await _session.executeRpcBatch(prepared!, chunk);
      chunk.clear();
      if (count == null) {
        canAggregate = false;
      } else {
        total += count;
      }
    }

    for (final params in paramSets) {
      final (list, map) = switch (params) {
        null => (null, null),
        List<dynamic> list => (list, null),
        Map<String, dynamic> map => (null, map),
        _ => throw tds.InterfaceException(
            'executemany accepts only lists or maps of parameters',
          ),
      };
      // Validate every item; the `?` conversion is the same for all of them.
      prepared = prepareSql(sql, placeholderIdentifier, list, map);
      chunk.add(_buildBindings(list, map));
      if (chunk.length >= batchSize) await flush();
    }
    await flush();
    _open = false;
    _hasCurrentResult = false;
    // As after execute(): fetch* returns empty instead of failing.
    _hasPendingCommand = true;
    _session.clearRowBuffer();
    _rowcountOverride = canAggregate ? total : null;
  }

  /// Runs one [executemany] item as its own request.
  Future<int?> _executeSingle(String sql, Map<String, dynamic> bindings) async {
    if (bindings.isEmpty) {
      await _session.submitPlainQuery(sql);
    } else {
      await _session.submitExecSql(sql, bindings);
    }
    await _positionOnFirstResult();
    await _finishActiveRequest();
    final count = _session.rowsAffected;
    return count == tds.TDS_NO_COUNT ? null : count;
  }

  Future<dynamic> fetchone() async {
    if (!_hasPendingCommand) {
      throw tds.InterfaceException(
          'execute() must be called before fetchone().');
    }
    if (!_hasCurrentResult) {
      if (!_open) {
        _hasPendingCommand = false;
      }
      return null;
    }
    final buffered = _session.takeRow();
    if (buffered != null) {
      return buffered;
    }
    if (await _session.nextRow()) {
      return _session.takeRow();
    }
    _hasCurrentResult = false;
    if (!_open) {
      _hasPendingCommand = false;
    }
    return null;
  }

  Future<List<dynamic>> fetchall() async {
    if (!_hasPendingCommand) {
      throw tds.InterfaceException(
          'execute() must be called before fetchall().');
    }
    if (!_hasCurrentResult) {
      if (!_open) {
        _hasPendingCommand = false;
      }
      return const <dynamic>[];
    }
    final rows = <dynamic>[];
    var row = _session.takeRow();
    while (row != null) {
      rows.add(row);
      row = _session.takeRow();
    }
    while (await _session.nextRow()) {
      final materialized = _session.takeRow();
      if (materialized != null) {
        rows.add(materialized);
      }
    }
    _hasCurrentResult = false;
    return rows;
  }

  Future<bool> nextset() async {
    if (!_hasPendingCommand) {
      throw tds.InterfaceException(
          'execute() must be called before nextset().');
    }
    final next = await _session.nextSet();
    if (next == true) {
      _session.clearRowBuffer();
      _hasCurrentResult = true;
      _open = true;
      return true;
    }
    _hasCurrentResult = false;
    _open = false;
    _hasPendingCommand = false;
    _session.clearRowBuffer();
    return false;
  }

  /// Discards whatever remains of the current response, freeing the session.
  Future<void> close() async {
    _open = false;
    _hasCurrentResult = false;
    _hasPendingCommand = false;
    await _session.drainPending();
  }

  Future<void> _finishActiveRequest() async {
    if (!_open) {
      _session.clearRowBuffer();
      _hasCurrentResult = false;
      _hasPendingCommand = false;
      return;
    }
    if (_hasCurrentResult) {
      await _drainCurrentSet();
      _hasCurrentResult = false;
    }
    while (await _session.nextSet() == true) {
      await _drainCurrentSet();
    }
    _open = false;
    _hasCurrentResult = false;
    _hasPendingCommand = false;
    _session.clearRowBuffer();
  }

  Future<void> _drainCurrentSet() async {
    var row = _session.takeRow();
    while (row != null) {
      row = _session.takeRow();
    }
    while (await _session.nextRow()) {
      _session.takeRow();
    }
  }

  Map<String, dynamic> _buildBindings(
    List<dynamic>? positional,
    Map<String, dynamic>? named,
  ) {
    final bindings = LinkedHashMap<String, dynamic>();
    if (positional != null) {
      for (var i = 0; i < positional.length; i++) {
        bindings['@p$i'] = positional[i];
      }
    }
    if (named != null) {
      named.forEach((key, value) {
        final normalized = key.startsWith('@') ? key : '@$key';
        if (bindings.containsKey(normalized)) {
          throw tds.InterfaceException(
            'Parameter $normalized defined more than once',
          );
        }
        bindings[normalized] = value;
      });
    }
    return bindings;
  }
}
