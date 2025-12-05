reponda sempre em portugues
continue portando o C:\MyDartProjects\mssql_dart\pytds para dart e atualizando o C:\MyDartProjects\mssql_dart\TODO.md

use o comando rg para buscar no codigo fonte

- [x] 2025-12-04: Portados `progErrors`, `integrityErrors`, `InterfaceError`, alias de timeout e `_createExceptionByMessage`; helpers `skipall`, `readChunks`, `readall` e `readallFast` agora usam `TransportProtocol`. Ajustado `tds7CryptPass` para codificar em UTF-16LE equivalente.
- [x] 2025-12-04: Acrescentado `tds_types.dart` com definições de tipos SQL, fábrica de serializers e inferência básica para sustentar o restante do port.
- [x] 2025-12-04: Iniciado `tds_socket.dart` com `SocketTransport` (baseado em `RawSynchronousSocket`), construtor de sessões e esqueleto de `_TdsSocket` (login/close/mars placeholders).
- [x] 2025-12-05: `collate.dart` agora resolve codecs reais via pacote `charset`, adicionando suporte explícito a UTF-16LE/`ucs2` com `galileo_utf` e tratamento de `Collation.get_codec` baseado em nomes de charset.
- [x] 2025-12-05: Código do `fl_charset` copiado para `lib/third_party/fl_charset` junto com a licença correspondente e `collate.dart` atualizado para importar a versão interna em vez do pacote externo.
- [x] 2025-12-05: CP950/Big5 agora usam o codec `Big5` do `enough_convert` interno (`lib/third_party/enough_convert`), permitindo que collations tradicionais retornem o encoding correto.
- [x] 2025-12-05: Camada de sessão/transportes ganhou scaffolds: `session_link.dart`, `tds_socket.dart` agora aceita builder padrão, e foram criados placeholders para `tds_reader.dart`, `tds_writer.dart` e `tds_session.dart` (métodos básicos ainda retornam stubs, mas a API já está definida).
- [x] 2025-12-05: Portados `tds_reader.dart`/`tds_writer.dart` com parsing completo de cabeçalhos, PLP e helpers numéricos, eliminando os stubs iniciais.
- [x] 2025-12-05: `SocketTransport` agora usa `RawSynchronousSocket` real para `sendall`/`recv`, expõe descritor e ganchos para upgrade TLS conforme `pytds.tls`.
- [x] 2025-12-05: `_TdsSession` envia PRELOGIN/LOGIN reais, parseia LOGINACK/ENVCHANGE/INFO/ERROR/DONE, dá suporte a queries simples (`submitPlainQuery`/`processSimpleRequest`) e mantém rastreamento de mensagens para `raiseDbException`.
- [x] 2025-12-05: `TdsSession` passou a herdar `SerializerFactory`, collation inicial e `bytesToUnicode` do builder/contexto, expondo `updateTypeSystem` para manter a sessão alinhada com `_TdsSocket` antes de portar tokens de result set.
- [x] 2025-12-05: Sessão e socket agora compartilham mudanças de collation via callback (`SessionBuildContext.onCollationChanged`), permitindo atualizar o `TdsTypeInferrer` em tempo real antes de portar COLMETADATA/rows.
- [x] 2025-12-05: `_TdsSession` passou a propagar ENVCHANGE de charset/LCID/transações/routing para `_TdsSocket`, mantendo `tds72Transaction`, `route`, flags unicode e charset sincronizados com o servidor.
- [x] 2025-12-05: Portadas `row_strategies` básicas (tuple/list/dict), `SessionBuildContext` expõe um `RowStrategy` tipado e `TdsSocket` pode atualizar a estratégia em tempo real sincronizando com `TdsSession`, preparando o loop de resultados para respeitar o formato configurado.
- [x] 2025-12-05: `_TdsSession` já interpreta tokens `COLMETADATA`, monta `tds.Results` com descrições e lê `TYPE_INFO` básico (int/decimal/char/binário/texto/xml/UDT), reconstruindo o `RowStrategy` com os nomes de coluna; parsing de linhas reais (`ROW`/`NBCROW`) segue pendente.
- [x] 2025-12-05: Adicionado `scripts/test_pytds_driver.py` para validar logins contra SQL Server local usando o checkout de `pytds/src`, evitando o `pip install` que falha com versão `unknown`; o script fixa `user/password` como `dart`, host `localhost`, remove variáveis de ambiente supérfluas e sempre grava `scripts/pytds_driver.log` via tee para stdout.
- [x] 2025-12-05: `pytds.tds_session` ganhou `_trace` com cobertura de PRELOGIN/LOGIN/tokens (`PYTDS_TRACE_EVENTS=1` por padrão no `scripts/test_pytds_driver.py`), e o port em Dart agora aceita um `traceHook` equivalente (`SessionBuildContext.traceHook`) para emitir os mesmos eventos durante o desenvolvimento.
- [x] 2025-12-05: Criado `test/integration/python_trace_test.dart`, skipado salvo `MSSQL_DART_INTEGRATION=1`, que executa `scripts/test_pytds_driver.py`, garante `scripts/pytds_driver.log` e confere os eventos `prelogin.send`/`login.ack`/`done` como base para validar o port.
- [x] 2025-12-05: Disponibilizado `connectSync` (`lib/src/connect.dart`, exportado por `mssql_dart.dart`) para encapsular `SocketTransport` + `_TdsLogin`, padronizando client/appName e permitindo injetar `traceHook` durante o login.
- [x] 2025-12-05: Adicionado `test/integration/dart_login_test.dart`, que usa `connectSync` para logar com `dart/dart` em `localhost:1433` e garante que `TdsSocket` fica conectado/`env.database` ajustado.
- [x] 2025-12-05: Portar transporte assíncrono baseado em `Socket`/`SecureSocket`, expondo API `Future` equivalente a `TransportProtocol` (ex.: `AsyncTransportProtocol`) e atualizar `TdsReader/TdsWriter` para modos async (novos `AsyncSocketTransport`, `AsyncTdsReader` e `AsyncTdsWriter`).
- [ ] 2025-12-05: Integrar TLS real via `SecureSocket`, respeitando `encFlag`, `encLoginOnly`, `validateHost` e `cafile`, com capacidade de trocar o socket dentro do transporte (sem depender de `RawSynchronousSocket`).
- [x] 2025-12-05: Criar `AsyncTdsSession`/`AsyncTdsSocket` para usar o transporte async, garantindo `sendPrelogin/login/processLoginTokens` em `Future`, cancelamentos e hooks de trace equivalentes (novos `connectAsync`, `AsyncSessionLink` e `AsyncSessionBuilder`).
- [x] 2025-12-05: Adicionar testes de integração async (ex.: `dart_login_async_test.dart`) cobrindo handshake básico com `connectAsync`, validando `login.ack` e `env.database` iguais ao fluxo síncrono.
- [x] 2025-12-05: `connectAsync`/`_buildLogin` passaram a aceitar `cafile`, `SecurityContext`, `validateHost` e `encLoginOnly`, adicionando o helper `buildLoginForTesting` e testes unitários para garantir que os flags de criptografia sejam configurados corretamente.
- [ ] Próximo ciclo (quebrado em etapas):
	1. Portar `pytds/tls.py` (`establish_channel`/`revert_to_clear`), usando `SecureSocket` ou wrapper síncrono e expondo swap de transporte em `SocketTransport`.
	2. Completar `_TdsSession`: loop de tokens para result sets reais (`COLMETADATA`/NBCROW/ROWS), RPCs, parâmetros de saída, cancelamentos e transações.
	3. Finalizar serializers reais em `tds_types.dart`/`tds_base.dart` e ligá-los ao processamento de colunas/parâmetros.
	4. Só então portar TLS avançado + MARS (`smp.py`) para destravar múltiplas sessões simultâneas.
	5. Usar os traces (Python x Dart) para validar ordem de tokens/tipos e alimentar os testes de integração antes de liberar parsing de linhas reais.