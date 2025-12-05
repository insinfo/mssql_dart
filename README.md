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

Demo code to perform Raw SQL queries

```dart

```


