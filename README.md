# dart_mssql

High Performance Microsoft SQL Server (MS-SQL Server) Driver for Dart (32 & 64bits)

####  forked from MoacirSchmidt/dart_mssql

# Important

- This package is not suitable for flutter or web projects. It only runs on server-side apps.
 
## TLS / TDS limitations (2025-12)

Enquanto o novo stack Dart para TDS não tiver acesso a um canal TLS plenamente controlado, seguimos limitados ao modo "TLS-first" (SecureSocket.connect antes do PRELOGIN). Isso significa que não é possível alternar para login-only ou compatibilizar servidores que exigem `ENCRYPT_OFF`/`ENCRYPT_ON` dinâmico até que uma das alternativas abaixo aconteça:

1. A correção do [dart-lang/sdk#62174](https://github.com/dart-lang/sdk/issues/62174), permitindo interceptar e reenquadrar registros TLS no nível necessário para refletir o comportamento do `pytds/tls.py`.
2. A conclusão do porte do [insinfo/tlslite](https://github.com/insinfo/tlslite), que nos dará um mecanismo 100% em Dart para reproduzir `establish_channel` / `revert_to_clear` e desbloquear login-only.

Assim que uma dessas frentes estiver disponível, removeremos essa limitação e integraremos os modos de criptografia equivalentes ao `pytds`.

# Example Usage

### Synchronous DB-API

Demo code to perform raw SQL queries using the higher-level cursor.

```dart
import 'package:mssql_dart/mssql_dart.dart';

void main() {
	final conn = dbConnectSync(
		host: 'localhost',
		port: 1433,
		user: 'sa',
		password: 'P@ssw0rd',
		database: 'master',
	);

	final cursor = conn.cursor();
	cursor.execute(
		'SELECT name FROM sys.databases WHERE database_id = @p0 AND name = @db',
		params: [1],
		namedParams: {'db': 'master'},
	);

	final row = cursor.fetchone();
	print(row);

	cursor.close();
	conn.close();
}
```

Positional collections map to `@p0`, `@p1`, ... placeholders, while entries in
`namedParams` expect the full placeholder name you used inside the SQL batch
(`@db` in the example).

	Para inserções/dml em lote, utilize `cursor.executemany` com uma lista contendo
	parâmetros posicionais ou nomeados em cada item:

	```dart
	cursor.executemany(
		'INSERT INTO dbo.logs (id, descricao) VALUES (@p0, @p1)',
		[
			[1, 'Primeira linha'],
			{'id': 2, 'descricao': 'Nomeado também funciona'},
		],
	);
	```

### Async DB-API

Para quem prefere `Future`s em vez do stack síncrono, `dbConnectAsync` expõe a
mesma camada DB-API utilizando `AsyncTdsSocket` e serializando o uso do socket
internamente.

```dart
import 'package:mssql_dart/mssql_dart.dart';

Future<void> main() async {
	final conn = await dbConnectAsync(
		host: 'localhost',
		port: 1433,
		user: 'sa',
		password: 'P@ssw0rd',
		database: 'master',
		encrypt: true,
	);

	final cursor = conn.cursor();
	await cursor.execute(
		'SELECT name FROM sys.databases WHERE database_id = @p0 AND name = @db',
		params: [1],
		namedParams: {'db': 'master'},
	);

	final row = await cursor.fetchone();
	print(row);

	await cursor.executemany(
		'INSERT INTO dbo.logs (id, descricao) VALUES (@p0, @p1)',
		[
			[3, 'Async 1'],
			[4, 'Async 2'],
		],
	);

	await cursor.close();
	await conn.close();
}
```

Mesmo criando múltiplos cursors, o driver garante exclusão mútua sob o capô,
então é seguro disparar `Future.wait` com diferentes operações — elas serão
serializadas automaticamente sobre o mesmo canal TDS.

### Async Session

The async socket/session API é de baixo nível, então encapsule as operações em
`socket.runSerial` para garantir que apenas um comando TDS esteja ativo por vez
(semelhante ao `_operationLock` do `postgresql-dart`).

```dart
import 'package:mssql_dart/mssql_dart.dart';

Future<void> main() async {
	final socket = await connectAsync(
		host: 'localhost',
		port: 1433,
		user: 'sa',
		password: 'P@ssw0rd',
		database: 'master',
		encrypt: true,
	);

	await socket.login();

	await socket.runSerial((session) async {
		await session.beginTransaction();
		await session.submitPlainQuery(
			'SELECT TOP (1) name FROM sys.databases ORDER BY name ASC',
		);
		await session.processSimpleRequest();
		final rows = socket.takeAllRows();
		print(rows);
		await session.commitTransaction();
	});
	await socket.close();
}
```


