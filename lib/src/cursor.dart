import 'dart:collection';

import 'tds_base.dart' as tds;
import 'tds_session.dart';

/// Cursor síncrono minimalista inspirado no DB-API: aceita apenas instruções
/// diretas (sem parâmetros ainda) e expõe `execute`/`fetch*`/`nextset`.
class TdsCursor {
  TdsCursor(TdsSession session) : _session = session;

  final TdsSession _session;
  bool _hasPendingCommand = false;
  bool _hasCurrentResult = false;
  bool _open = false;

  /// Última descrição de colunas retornada pelo servidor.
  tds.Results? get description => _session.results;

  /// Número de linhas afetadas pelo último comando (ou -1 quando desconhecido).
  int get rowcount => _session.rowsAffected;

  /// Inicia a execução de um comando SQL simples.
  void execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) {
    _finishActiveRequest();
    final bindings = _buildBindings(params, namedParams);
    if (bindings.isEmpty) {
      _session.submitPlainQuery(sql);
    } else {
      _session.submitExecSql(sql, bindings);
    }
    _session.beginResponse();
    _hasPendingCommand = true;
    _hasCurrentResult = _session.findResultOrDone();
    _open = true;
    if (!_hasCurrentResult && _session.state == tds.TDS_IDLE) {
      _open = false;
    }
  }

  /// Retorna a próxima linha do conjunto atual, ou `null` se não houver mais.
  dynamic fetchone() {
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
    if (_session.nextRow()) {
      return _session.takeRow();
    }
    _hasCurrentResult = false;
    if (!_open) {
      _hasPendingCommand = false;
    }
    return null;
  }

  /// Lê todas as linhas do conjunto atual.
  List<dynamic> fetchall() {
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
    while (_session.nextRow()) {
      final materialized = _session.takeRow();
      if (materialized != null) {
        rows.add(materialized);
      }
    }
    _hasCurrentResult = false;
    return rows;
  }

  /// Avança para o próximo result set, retornando `true` se existir outro.
  bool nextset() {
    if (!_hasPendingCommand) {
      throw tds.InterfaceError('execute() precisa ser chamado antes de nextset().');
    }
    final next = _session.nextSet();
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

  void _finishActiveRequest() {
    if (!_open) {
      _session.clearRowBuffer();
      _hasCurrentResult = false;
      return;
    }
    if (_hasCurrentResult) {
      _drainCurrentSet();
      _hasCurrentResult = false;
    }
    while (_session.nextSet() == true) {
      _drainCurrentSet();
    }
    _open = false;
    _hasCurrentResult = false;
    _session.clearRowBuffer();
  }

  void _drainCurrentSet() {
    var row = _session.takeRow();
    while (row != null) {
      row = _session.takeRow();
    }
    while (_session.nextRow()) {
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
