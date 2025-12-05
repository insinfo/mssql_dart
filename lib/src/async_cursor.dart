import 'dart:async';
import 'dart:collection';

import 'tds_base.dart' as tds;
import 'async_tds_session.dart';

/// Cursor assíncrono inspirado no DB-API. Mantém o controle do estado
/// atual do `AsyncTdsSession` enquanto executa comandos sequenciais.
class AsyncTdsCursor {
  AsyncTdsCursor(this._session);

  final AsyncTdsSession _session;
  bool _hasPendingCommand = false;
  bool _hasCurrentResult = false;
  bool _open = false;
  int? _rowcountOverride;

  tds.Results? get description => _session.results;
  int get rowcount => _rowcountOverride ?? _session.rowsAffected;
  bool get isIdle => _session.state == tds.TDS_IDLE;

  Future<void> execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) async {
    _rowcountOverride = null;
    await _finishActiveRequest();
    final bindings = _buildBindings(params, namedParams);
    if (bindings.isEmpty) {
      await _session.submitPlainQuery(sql);
    } else {
      await _session.submitExecSql(sql, bindings);
    }
    await _session.beginResponse();
    _hasPendingCommand = true;
    await _session.findResultOrDone();
    _hasCurrentResult = _session.results != null;
    _open = true;
    if (!_hasCurrentResult && _session.state == tds.TDS_IDLE) {
      _open = false;
    }
  }

  /// Executa a mesma instrução múltiplas vezes, aceitando listas ou mapas de
  /// parâmetros para cada item fornecido pelo iterável.
  Future<void> executemany(String sql, Iterable<dynamic> paramSets) async {
    _rowcountOverride = null;
    await _finishActiveRequest();
    var total = 0;
    var canAggregate = true;
    var hadAny = false;

    for (final params in paramSets) {
      hadAny = true;
      if (params == null) {
        await execute(sql);
      } else if (params is List<dynamic>) {
        await execute(sql, params: params);
      } else if (params is Map<String, dynamic>) {
        await execute(sql, namedParams: params);
      } else {
        throw tds.InterfaceError(
          'executemany aceita apenas listas ou mapas de parâmetros',
        );
      }
      final count = _session.rowsAffected;
      if (count == tds.TDS_NO_COUNT) {
        canAggregate = false;
      } else if (canAggregate) {
        total += count;
      }
    }

    if (!hadAny) {
      _open = false;
      _hasPendingCommand = false;
      _rowcountOverride = 0;
      return;
    }

    if (canAggregate) {
      _rowcountOverride = total;
    } else {
      _rowcountOverride = null;
    }
  }

  Future<dynamic> fetchone() async {
    if (!_hasPendingCommand) {
      throw tds.InterfaceError('execute() precisa ser chamado antes de fetchone().');
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
      throw tds.InterfaceError('execute() precisa ser chamado antes de fetchall().');
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
      throw tds.InterfaceError('execute() precisa ser chamado antes de nextset().');
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
          throw tds.InterfaceError(
            'Parâmetro $normalized definido mais de uma vez',
          );
        }
        bindings[normalized] = value;
      });
    }
    return bindings;
  }
}
