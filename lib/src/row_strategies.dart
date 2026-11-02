import 'dart:collection';
import 'dart:math' as math;

/// A function that takes a row's list of values and returns the final
/// structure exposed to the user (list, map, etc.).
typedef RowGenerator = dynamic Function(List<dynamic> values);

/// A strategy that, given the column names, produces a [RowGenerator].
typedef RowStrategy = RowGenerator Function(List<String> columnNames);

/// Returns immutable rows (analogous to Python tuples).
RowGenerator tupleRowStrategy(List<String> columnNames) {
  return (List<dynamic> values) => UnmodifiableListView<dynamic>(
        List<dynamic>.from(values, growable: false),
      );
}

/// Returns rows as mutable lists, independent of the internal buffer.
RowGenerator listRowStrategy(List<String> columnNames) {
  return (List<dynamic> values) => List<dynamic>.from(values);
}

/// Returns rows as maps (name -> value), using the index for empty names.
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

/// The default strategy, used when none is specified.
final RowStrategy defaultRowStrategy = listRowStrategy;
