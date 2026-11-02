# Third-party code

Character set tables used to decode `char`/`varchar`/`text` columns whose
collation is not Unicode. They are vendored so the driver has no runtime
dependencies.

| Directory | Origin | License |
|---|---|---|
| `charset/` (except `other/`) | [enough_convert](https://pub.dev/packages/enough_convert) 1.6.0 | MPL-2.0, see `charset/LICENSE` |
| `charset/other/` | [charset](https://pub.dev/packages/charset) 2.0.1 by shirne ([source](https://github.com/shirne/charset-dart)) | Apache-2.0, see `charset/other/LICENSE` |

Only the codecs for SQL Server code pages are kept: 437, 850, 874 and
1250-1258 (`other/code_page.dart`), 932 (`other/shift_jis.dart`), 936
(`other/gbk.dart`), 949 (`other/euc_kr.dart`) and 950 (`src/big5`).

Modifications: the files were moved under `lib/third_party/charset` and
adapted (imports and small changes); `other/euc_kr.dart` uses the two lookup
tables the other way round, because their names are swapped upstream. Diff
the files against the versions above for details. The source code of the MPL-2.0 files is the files themselves.
