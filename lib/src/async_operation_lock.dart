import 'dart:async';

/// Pequeno utilitário para serializar operações assíncronas.
///
/// Inspirado na estratégia de fila usada pelo `postgresql-dart` para impedir
/// que múltiplos comandos usem o mesmo canal simultaneamente. Permite
/// reentrância: chamadas realizadas enquanto a mesma operação estiver ativa
/// executam imediatamente, evitando deadlocks ao chamar APIs internas.
class AsyncOperationLock {
  AsyncOperationLock();

  Future<void> _tail = Future<void>.value();
  int _depth = 0;

  /// Executa [action] garantindo que nenhuma outra operação protegida rode
  /// simultaneamente. Se a chamada ocorrer durante outra operação já ativa,
  /// ela é executada imediatamente (reentrante) para permitir composições.
  Future<T> synchronized<T>(Future<T> Function() action) {
    if (_depth > 0) {
      return action();
    }
    final previous = _tail;
    final completer = Completer<void>();
    _tail = previous.whenComplete(() => completer.future);
    return previous.then((_) async {
      _depth += 1;
      try {
        return await action();
      } finally {
        _depth -= 1;
        completer.complete();
      }
    });
  }
}
