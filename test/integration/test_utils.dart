import 'dart:async';
import 'dart:io';

/// Executa [action] sob um lock baseado em arquivo para impedir que vários
/// testes de integração usem o SQL Server simultaneamente.
Future<T> withSqlServerLock<T>(FutureOr<T> Function() action) async {
  final lock = await _SqlServerTestLock.instance._acquire();
  try {
    return await Future.sync(action);
  } finally {
    await lock.release();
  }
}

class _SqlServerTestLock {
  _SqlServerTestLock._();

  static final _SqlServerTestLock instance = _SqlServerTestLock._();
  final File _lockFile = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}mssql_dart_sqlserver.lock',
  );

  Future<_FileLockHandle> _acquire() async {
    final raf = await _lockFile.open(mode: FileMode.write);
    await raf.lock(FileLock.exclusive);
    return _FileLockHandle(raf);
  }
}

class _FileLockHandle {
  _FileLockHandle(this._raf);

  final RandomAccessFile _raf;

  Future<void> release() async {
    await _raf.unlock();
    await _raf.close();
  }
}
