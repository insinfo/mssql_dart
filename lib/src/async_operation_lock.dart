import 'dart:async';

/// Serializes asynchronous operations in arrival order (FIFO).
///
/// It is reentrant only for the current holder: calls made from inside
/// [synchronized] (in the same asynchronous flow, identified by a [Zone])
/// run immediately; any other call waits its turn, even if it arrives while
/// the holder is waiting on I/O.
class AsyncOperationLock {
  AsyncOperationLock();

  final Object _zoneKey = Object();
  Future<void> _tail = Future<void>.value();

  /// Whether the current flow already holds the lock.
  bool get isHeldByCurrentZone => Zone.current[_zoneKey] == true;

  Future<T> synchronized<T>(Future<T> Function() action) {
    if (isHeldByCurrentZone) {
      return action();
    }
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) {
      return runZoned(action, zoneValues: {_zoneKey: true});
    }).whenComplete(done.complete);
  }
}
