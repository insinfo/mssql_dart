import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
//C:\Program Files\Microsoft SQL Server
//C:\MyDartProjects\mssql_dart\cpp\x64\Debug\dart_mssql.dll
//Server=localhost\SQLEXPRESS;Database=master;Trusted_Connection=True;
//sqlcmd -S localhost\SQLEXPRESS,1433 -U dart -P "dart"
//C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\20250321_205830
// Estrutura que representa o resultado SQL (modifique conforme as necessidades)


final DynamicLibrary mssqlLib = Platform.isWindows
    ? DynamicLibrary.open(
        'C:\\MyDartProjects\\mssql_dart\\cpp\\x64\\Debug\\dart_mssql.dll')
    : DynamicLibrary.process();

typedef _InitializeCOMNative = Int32 Function();
typedef _InitializeCOMDart = int Function();

final _InitializeCOMDart initializeCOM = mssqlLib
    .lookup<NativeFunction<_InitializeCOMNative>>('initializeCOM')
    .asFunction();

/// Constantes de autenticação conforme o header C.
const int AUTH_TYPE_PASSWORD = 0;
const int AUTH_TYPE_INTEGRATED = 1;

typedef _ConnectCommandNative = Int32 Function(
  Pointer<Utf8> serverName,
  Pointer<Utf8> dbName,
  Pointer<Utf8> userName,
  Pointer<Utf8> password,
  Int64 authType,
  Pointer<Pointer<Void>> ppInitialize,
  Pointer<Int32> errorCount,
  Pointer<Utf8> errorMessages,
  Int32 errorMsgBufferSize,
);
typedef _ConnectCommandDart = int Function(
  Pointer<Utf8> serverName,
  Pointer<Utf8> dbName,
  Pointer<Utf8> userName,
  Pointer<Utf8> password,
  int authType,
  Pointer<Pointer<Void>> ppInitialize,
  Pointer<Int32> errorCount,
  Pointer<Utf8> errorMessages,
  int errorMsgBufferSize,
);

final _ConnectCommandDart connectCommand = mssqlLib
    .lookup<NativeFunction<_ConnectCommandNative>>('sqlConnect')
    .asFunction();

/// Atualizamos a assinatura de sqlExecute para que ela retorne um Pointer<Utf8>
/// com os resultados da consulta (por exemplo, uma string JSON)
typedef _ExecuteCommandNative = Pointer<Utf8> Function(
  Pointer<Void> pInitialize,
  Pointer<Utf16> sqlCommand,
  Pointer<Void> sqlParams,
  Pointer<Void> dartMssqlLib,
  Pointer<Void> dartSqlResult,
  Pointer<Int32> errorCount,
  Pointer<Utf8> errorMessages,
  Int32 errorMsgBufferSize,
);
typedef _ExecuteCommandDart = Pointer<Utf8> Function(
  Pointer<Void> pInitialize,
  Pointer<Utf16> sqlCommand,
  Pointer<Void> sqlParams,
  Pointer<Void> dartMssqlLib,
  Pointer<Void> dartSqlResult,
  Pointer<Int32> errorCount,
  Pointer<Utf8> errorMessages,
  int errorMsgBufferSize,
);

final _ExecuteCommandDart executeCommand = mssqlLib
    .lookup<NativeFunction<_ExecuteCommandNative>>('sqlExecute')
    .asFunction();

class SqlConnectionNative {
  final String serverName;
  final String dbName;
  final String userName;
  final String password;
  late Pointer<Void> _connection;

  SqlConnectionNative({
    required this.serverName,
    required this.dbName,
    required this.userName,
    required this.password,
    bool integratedAuth = false,
  }) {
    final serverPtr = serverName.toNativeUtf8();
    final dbPtr = dbName.toNativeUtf8();
    final userPtr = userName.toNativeUtf8();
    final passPtr = password.toNativeUtf8();
    final auth = integratedAuth ? AUTH_TYPE_INTEGRATED : AUTH_TYPE_PASSWORD;

    // Aloca espaço para os parâmetros de saída.
    final ppInitialize = calloc<Pointer<Void>>();
    final errorCount = calloc<Int32>();
    const errorMsgBufferSize = 256;
    final errorMessages = calloc<Uint8>(errorMsgBufferSize);

    final hr = connectCommand(
      serverPtr,
      dbPtr,
      userPtr,
      passPtr,
      auth,
      ppInitialize,
      errorCount,
      errorMessages.cast(),
      errorMsgBufferSize,
    );

    calloc.free(serverPtr);
    calloc.free(dbPtr);
    calloc.free(userPtr);
    calloc.free(passPtr);

    if (hr != 0 || errorCount.value != 0) {
      final errMsg = errorMessages.cast<Utf8>().toDartString();
      calloc.free(errorMessages);
      calloc.free(errorCount);
      calloc.free(ppInitialize);
      throw Exception(
          'Erro ao conectar: $errMsg (HRESULT: $hr, errorCount: ${errorCount.value})');
    }

    _connection = ppInitialize.value;

    calloc.free(errorMessages);
    calloc.free(errorCount);
    calloc.free(ppInitialize);
  }

  bool get isConnected => _connection.address != 0;

  /// Executa um comando SQL e retorna os resultados como uma String
  /// (por exemplo, uma string JSON com os campos "columns", "rows" e "rowsAffected").
  String execute(String sqlCommand) {
    if (!isConnected) {
      throw Exception("Conexão não estabelecida");
    }
    final sqlPtr = sqlCommand.toNativeUtf16();
    final errorCount = calloc<Int32>();
    const errorMsgBufferSize = 256;
    final errorMessages = calloc<Uint8>(errorMsgBufferSize);

    // Como o resultado será retornado como string, passamos nullptr para dartMssqlLib e dartSqlResult.
    final resultPtr = executeCommand(
      _connection,
      sqlPtr,
      nullptr,
      nullptr,
      nullptr,
      errorCount,
      errorMessages.cast(),
      errorMsgBufferSize,
    );

    calloc.free(sqlPtr);
    if (errorCount.value != 0) {
      final errMsg = errorMessages.cast<Utf8>().toDartString();
      calloc.free(errorMessages);
      calloc.free(errorCount);
      throw Exception('Erro ao executar SQL: $errMsg');
    }
    final resultString = resultPtr.toDartString();

    // Se a DLL alocou o resultado dinamicamente, é recomendável liberar o buffer chamando
    // uma função exportada pela DLL (por exemplo, freeResult(resultPtr)). Aqui, isso não foi implementado.

    calloc.free(errorMessages);
    calloc.free(errorCount);
    return resultString;
  }

  void close() {
    _connection = Pointer<Void>.fromAddress(0);
  }
}
