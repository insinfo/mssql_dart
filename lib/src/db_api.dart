import 'cursor.dart';
import 'tds_base.dart' as tds;
import 'tds_socket.dart';

/// Exceção lançada quando operações são tentadas após o fechamento da conexão.
final tds.InterfaceError _closedConnectionError =
    tds.InterfaceError('Conexão já foi fechada.');

/// Camada DB-API inspirada no `pytds.connection`, mas atualmente sem pooling
/// e sem MARS. Expõe uma API simples para quem só precisa de cursors de alto
/// nível.
class DbConnection {
  DbConnection._(this._socket);

  final TdsSocket _socket;
  bool _closed = false;

  /// Cria um cursor associado à conexão.
  DbCursor cursor() {
    final socket = _ensureOpen();
    final session = socket.cursor();
    return DbCursor._(this, session);
  }

  /// Executa uma instrução e retorna o cursor usado.
  DbCursor execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) {
    final cur = cursor();
    cur.execute(sql, params: params, namedParams: namedParams);
    return cur;
  }

  /// Encerra a conexão com o servidor.
  void close() {
    if (_closed) {
      return;
    }
    _socket.close();
    _closed = true;
  }

  bool get isClosed => _closed;

  TdsSocket get socket => _ensureOpen();

  TdsSocket _ensureOpen() {
    if (_closed) {
      throw _closedConnectionError;
    }
    return _socket;
  }
}

class DbCursor {
  DbCursor._(this._connection, this._cursor);

  final DbConnection _connection;
  TdsCursor? _cursor;

  /// Executa a instrução SQL fornecida.
  void execute(
    String sql, {
    List<dynamic>? params,
    Map<String, dynamic>? namedParams,
  }) {
    final cursor = _ensureOpen();
    cursor.execute(sql, params: params, namedParams: namedParams);
  }

  /// Retorna a próxima linha ou `null` se não houver mais resultados.
  dynamic fetchone() {
    final cursor = _ensureOpen();
    return cursor.fetchone();
  }

  /// Retorna todas as linhas restantes do conjunto atual.
  List<dynamic> fetchall() {
    final cursor = _ensureOpen();
    return cursor.fetchall();
  }

  /// Avança para o próximo result set.
  bool nextset() {
    final cursor = _ensureOpen();
    return cursor.nextset();
  }

  /// Encerra o cursor. Novas chamadas resultarão em erro.
  void close() {
    _cursor = null;
  }

  bool get isClosed => _cursor == null || _connection.isClosed;

  tds.Results? get description => _ensureOpen().description;
  int get rowcount => _ensureOpen().rowcount;

  TdsCursor _ensureOpen() {
    final cursor = _cursor;
    if (cursor == null || _connection.isClosed) {
      throw tds.InterfaceError('Cursor fechado');
    }
    return cursor;
  }
}

DbConnection dbConnectionFromSocket(TdsSocket socket) {
  return DbConnection._(socket);
}
