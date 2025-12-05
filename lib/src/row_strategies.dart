import 'dart:collection';
import 'dart:math' as math;

/// Representa uma função que recebe a lista de valores de uma linha e devolve
/// a estrutura final exposta ao usuário (lista, mapa, etc.).
typedef RowGenerator = dynamic Function(List<dynamic> values);

/// Estratégia que, dado o conjunto de nomes de colunas, produz um [RowGenerator].
typedef RowStrategy = RowGenerator Function(List<String> columnNames);

/// Retorna linhas imutáveis (análogas a tuples em Python).
RowGenerator tupleRowStrategy(List<String> columnNames) {
  return (List<dynamic> values) => UnmodifiableListView<dynamic>(
        List<dynamic>.from(values, growable: false),
      );
}

/// Retorna linhas como listas mutáveis independentes do buffer interno.
RowGenerator listRowStrategy(List<String> columnNames) {
  return (List<dynamic> values) => List<dynamic>.from(values);
}

/// Retorna linhas como mapas (nome -> valor), preenchendo nomes vazios com o índice.
RowGenerator dictRowStrategy(List<String> columnNames) {
  final normalized = <String>[];
  for (var i = 0; i < columnNames.length; i++) {
    final name = columnNames[i];
    normalized.add(name.isEmpty ? '$i' : name);
  }
  return (List<dynamic> values) {
    final result = <String, dynamic>{};
    final limit = math.min(normalized.length, values.length);
    for (var i = 0; i < limit; i++) {
      result[normalized[i]] = values[i];
    }
    return result;
  };
}

/// Estratégia padrão utilizada quando nenhuma é especificada.
final RowStrategy defaultRowStrategy = listRowStrategy;
