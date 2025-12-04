reponda sempre em portugues
continue portando o C:\MyDartProjects\mssql_dart\pytds para dart e atualizando o C:\MyDartProjects\mssql_dart\TODO.md

use o comando rg para buscar no codigo fonte

- [x] 2025-12-04: Portados `progErrors`, `integrityErrors`, `InterfaceError`, alias de timeout e `_createExceptionByMessage`; helpers `skipall`, `readChunks`, `readall` e `readallFast` agora usam `TransportProtocol`. Ajustado `tds7CryptPass` para codificar em UTF-16LE equivalente.
- [x] 2025-12-05: `collate.dart` agora resolve codecs reais via pacote `charset`, adicionando suporte explícito a UTF-16LE/`ucs2` com `galileo_utf` e tratamento de `Collation.get_codec` baseado em nomes de charset.
- [x] 2025-12-05: Código do `fl_charset` copiado para `lib/third_party/fl_charset` junto com a licença correspondente e `collate.dart` atualizado para importar a versão interna em vez do pacote externo.
- [x] 2025-12-05: CP950/Big5 agora usam o codec `Big5` do `enough_convert` interno (`lib/third_party/enough_convert`), permitindo que collations tradicionais retornem o encoding correto.
- [ ] Próximo: concluir o restante de `tds_base` (type factories, serializers e suporte a mensagens) para então integrar com `tds_session`/`tds_types`.