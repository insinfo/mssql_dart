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
- [ ] Próximo ciclo (quebrado em etapas):
	1. Portar `tds_reader.py`/`tds_writer.py` reais (frame header, PLP, NBC row helpers) substituindo os stubs atuais.
	2. Implementar `SocketTransport` com `Socket/SecureSocket`, negociar TLS conforme `pytds.tls` (establish/revert) e expor ganchos para um futuro `SmpManager`.
	3. Trazer `_TdsSession` completo (token loop, envio de login/RPC, gerenciamento de mensagens) acoplando o novo reader/writer.
	4. Finalizar serializers reais em `tds_types.dart`/`tds_base.dart` e ligá-los ao processamento de colunas/parametros.
	5. Só então portar TLS avançado + MARS (`smp.py`) para destravar múltiplas sessões.