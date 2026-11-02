/// Heavy TLS concurrency test using multiple isolates.
///
/// This test shows that SQL Server handles many simultaneous TLS connections.

import 'dart:async';

import 'package:mssql_dart/tds.dart';
import 'package:test/test.dart';
import 'test_config.dart';

const host = 'localhost';
const port = 1433;
const database = 'dart';
const user = 'dart';
const password = 'dart';

/// Opens a TLS connection and runs queries.
Future<String> runTlsConnection(int connectionId) async {
  try {
    // ignore: avoid_print
    print('[Conn $connectionId] Starting TLS connection...');

    final conn = await MssqlConnection.connect(MssqlConnectionSettings(
      host: host,
      port: port,
      username: user,
      password: password,
      database: database,
      encrypt: true,
      caFile: testCa,
      trustServerCertificate: testTrustServerCertificate,
      tlsBackend: TlsBackend.tlslite,
    ));

    // ignore: avoid_print
    print('[Conn $connectionId] Connected! Running queries...');

    final cursor = conn.cursor();

    // Runs several queries
    for (var i = 0; i < 5; i++) {
      await cursor.execute(
          'SELECT $connectionId AS conn_id, $i AS query_num, GETDATE() AS ts');
      final rows = await cursor.fetchAll();
      if (rows.isEmpty) {
        throw Exception('Conn $connectionId: query $i returned no rows');
      }
    }

    await cursor.close();
    await conn.close();

    // ignore: avoid_print
    print('[Conn $connectionId] Completed successfully!');
    return 'Conn $connectionId: OK';
  } catch (e) {
    // ignore: avoid_print
    print('[Conn $connectionId] ERROR: $e');
    return 'Conn $connectionId: ERROR - $e';
  }
}

void main() {
  group('Heavy TLS Concurrency', () {
    test('10 simultaneous TLS connections', () async {
      // ignore: avoid_print
      print('\n=== Starting 10 simultaneous TLS connections ===\n');

      final futures = <Future<String>>[];

      for (var i = 0; i < 10; i++) {
        futures.add(runTlsConnection(i));
      }

      final results = await Future.wait(futures);

      // ignore: avoid_print
      print('\n=== Results ===');
      for (final result in results) {
        // ignore: avoid_print
        print(result);
      }

      final successCount = results.where((r) => r.contains('OK')).length;
      // ignore: avoid_print
      print('\nSuccess: $successCount/10');

      expect(successCount, equals(10),
          reason: 'All 10 connections must succeed');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('20 simultaneous TLS connections', () async {
      // ignore: avoid_print
      print('\n=== Starting 20 simultaneous TLS connections ===\n');

      final futures = <Future<String>>[];

      for (var i = 0; i < 20; i++) {
        futures.add(runTlsConnection(i));
      }

      final results = await Future.wait(futures);

      final successCount = results.where((r) => r.contains('OK')).length;
      // ignore: avoid_print
      print('\nSuccess: $successCount/20');

      expect(successCount, equals(20),
          reason: 'All 20 connections must succeed');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('50 quick sequential TLS connections', () async {
      // ignore: avoid_print
      print('\n=== Starting 50 sequential TLS connections ===\n');

      var successCount = 0;
      var errorCount = 0;

      for (var i = 0; i < 50; i++) {
        try {
          final conn = await MssqlConnection.connect(MssqlConnectionSettings(
            host: host,
            port: port,
            username: user,
            password: password,
            database: database,
            encrypt: true,
            caFile: testCa,
            trustServerCertificate: testTrustServerCertificate,
            tlsBackend: TlsBackend.tlslite,
          ));

          final cursor = conn.cursor();
          await cursor.execute('SELECT $i AS num');
          final rows = await cursor.fetchAll();
          await cursor.close();
          await conn.close();

          if (rows.isNotEmpty) {
            successCount++;
          }

          if ((i + 1) % 10 == 0) {
            // ignore: avoid_print
            print('Progress: ${i + 1}/50');
          }

          // Short delay between connections to avoid TIME_WAIT issues
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          errorCount++;
          // ignore: avoid_print
          print('Error on connection $i: $e');
        }
      }

      // ignore: avoid_print
      print('\nSuccess: $successCount/50, errors: $errorCount');

      expect(successCount, equals(50),
          reason: 'All 50 connections must succeed');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('50 sequential connections WITHOUT TLS (baseline)', () async {
      // ignore: avoid_print
      print('\n=== Starting 50 sequential connections WITHOUT TLS ===\n');

      var successCount = 0;
      var errorCount = 0;

      for (var i = 0; i < 50; i++) {
        try {
          final conn = await MssqlConnection.connect(MssqlConnectionSettings(
            host: host,
            port: port,
            username: user,
            password: password,
            database: database,
            encrypt: false, // no TLS
          ));

          final cursor = conn.cursor();
          await cursor.execute('SELECT $i AS num');
          final rows = await cursor.fetchAll();
          await cursor.close();
          await conn.close();

          if (rows.isNotEmpty) {
            successCount++;
          }

          if ((i + 1) % 10 == 0) {
            // ignore: avoid_print
            print('Progress: ${i + 1}/50');
          }

          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          errorCount++;
          // ignore: avoid_print
          print('Error on connection $i: $e');
        }
      }

      // ignore: avoid_print
      print('\nSuccess: $successCount/50, errors: $errorCount');

      expect(successCount, equals(50),
          reason: 'All 50 connections without TLS must succeed');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
