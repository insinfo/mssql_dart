import 'dart:async';
import 'dart:io';

/// Runs [action] under a file-based lock so that multiple integration tests
/// do not use SQL Server at the same time.
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
