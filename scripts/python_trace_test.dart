import 'dart:io';

import 'package:test/test.dart';

void main() {
  final rootDir = Directory.current.path;

  test(
    'pytds driver gera logs de trace',
    () async {
      final result = await Process.run(
        'python',
        ['scripts/test_pytds_driver.py'],
        workingDirectory: rootDir,
        environment: {
          ...Platform.environment,
          'PYTDS_TRACE_EVENTS': '1',
        },
      );
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      expect(result.exitCode, 0,
          reason: 'python retornou ${result.exitCode}: ${result.stderr}');
      final logFile = File('$rootDir/scripts/pytds_driver.log');
      expect(logFile.existsSync(), isTrue,
          reason: 'scripts/pytds_driver.log não foi criado pelo driver Python');
      final logContent = await logFile.readAsString();
      expect(logContent.contains('[PYTDS-TRACE] prelogin.send'), isTrue,
          reason: 'Log não contem evento prelogin.send');
      expect(logContent.contains('[PYTDS-TRACE] login.ack'), isTrue,
          reason: 'Log não contem evento login.ack');
      expect(logContent.contains('[PYTDS-TRACE] done'), isTrue,
          reason: 'Log não contem evento done');
    },
  );
}
