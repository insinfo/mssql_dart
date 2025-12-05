import 'dart:async';

import 'package:mssql_dart/src/async_operation_lock.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncOperationLock', () {
    test('serializa execuções concorrentes', () async {
      final lock = AsyncOperationLock();
      final log = <String>[];

      Future<void> task(String label, Duration delay) async {
        await lock.synchronized(() async {
          log.add('start $label');
          await Future.delayed(delay);
          log.add('end $label');
        });
      }

      await Future.wait([
        task('A', const Duration(milliseconds: 20)),
        task('B', const Duration(milliseconds: 5)),
        task('C', const Duration(milliseconds: 1)),
      ]);

      expect(log, equals([
        'start A',
        'end A',
        'start B',
        'end B',
        'start C',
        'end C',
      ]));
    });

    test('permite reentrância sem deadlock', () async {
      final lock = AsyncOperationLock();
      final events = <String>[];

      await lock.synchronized(() async {
        events.add('outer-start');
        await lock.synchronized(() async {
          events.add('inner');
        });
        events.add('outer-end');
      });

      expect(events, equals(['outer-start', 'inner', 'outer-end']));
    });
  });
}
