import 'package:mssql_dart/mssql_dart.dart';

void main() {
  try {
    // Inicializa a COM
    final hr = initializeCOM();
    if (hr != 0) {
      throw Exception('Erro ao inicializar COM: HRESULT: $hr');
    }
    // Cria a conexão com o SQL Server
    final conn = SqlConnectionNative(
      serverName: 'localhost',
      dbName: 'teste',
      userName: 'dart',
      password: 'dart',
      integratedAuth: false,
    );

    // Cria a tabela se ela não existir.
    const createTableSQL = '''
  CREATE TABLE MinhaTabela (
    col1 VARCHAR(100),
    col2 INT
  )
''';
   final res = conn.execute(createTableSQL);
    print('Tabela criada (ou já existente). $res');

    // Executa uma consulta para listar os dados.
   final res2 = conn.execute('SELECT * FROM MinhaTabela');
    print('Consulta SELECT executada. $res2');

    // Fecha a conexão.
    conn.close();
  } catch (e) {
    print('Erro: $e');
  }
}
