/// Teste de concorrência pesada com TLS usando múltiplos isolates.
///
/// Este teste prova que o SQL Server aguenta muitas conexões TLS simultâneas.

import 'dart:async';

import 'package:mssql_dart/mssql_dart.dart';
import 'package:test/test.dart';

const host = 'localhost';
const port = 1433;
const database = 'dart';
const user = 'dart';
const password = 'dart';

/// Função que cria uma conexão TLS e executa queries
Future<String> runTlsConnection(int connectionId) async {
  try {
    // ignore: avoid_print
    print('[Conn $connectionId] Iniciando conexão TLS...');
    
    final conn = await dbConnectAsync(
      host: host,
      port: port,
      user: user,
      password: password,
      database: database,
      encrypt: true,
      validateHost: false,
      tlsBackend: TlsBackend.tlslite,
    );
    
    // ignore: avoid_print
    print('[Conn $connectionId] Conectado! Executando queries...');
    
    final cursor = conn.cursor();
    
    // Executa várias queries
    for (var i = 0; i < 5; i++) {
      await cursor.execute('SELECT $connectionId AS conn_id, $i AS query_num, GETDATE() AS ts');
      final rows = await cursor.fetchall();
      if (rows.isEmpty) {
        throw Exception('Conn $connectionId: Query $i retornou vazio');
      }
    }
    
    await cursor.close();
    await conn.close();
    
    // ignore: avoid_print
    print('[Conn $connectionId] Concluído com sucesso!');
    return 'Conn $connectionId: OK';
  } catch (e) {
    // ignore: avoid_print
    print('[Conn $connectionId] ERRO: $e');
    return 'Conn $connectionId: ERRO - $e';
  }
}

void main() {
  group('Heavy TLS Concurrency', () {
    test('10 conexões TLS simultâneas', () async {
      // ignore: avoid_print
      print('\n=== Iniciando 10 conexões TLS simultâneas ===\n');
      
      final futures = <Future<String>>[];
      
      for (var i = 0; i < 10; i++) {
        futures.add(runTlsConnection(i));
      }
      
      final results = await Future.wait(futures);
      
      // ignore: avoid_print
      print('\n=== Resultados ===');
      for (final result in results) {
        // ignore: avoid_print
        print(result);
      }
      
      final successCount = results.where((r) => r.contains('OK')).length;
      // ignore: avoid_print
      print('\nSucesso: $successCount/10');
      
      expect(successCount, equals(10), reason: 'Todas as 10 conexões devem ter sucesso');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('20 conexões TLS simultâneas', () async {
      // ignore: avoid_print
      print('\n=== Iniciando 20 conexões TLS simultâneas ===\n');
      
      final futures = <Future<String>>[];
      
      for (var i = 0; i < 20; i++) {
        futures.add(runTlsConnection(i));
      }
      
      final results = await Future.wait(futures);
      
      final successCount = results.where((r) => r.contains('OK')).length;
      // ignore: avoid_print
      print('\nSucesso: $successCount/20');
      
      expect(successCount, equals(20), reason: 'Todas as 20 conexões devem ter sucesso');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('50 conexões TLS sequenciais rápidas', () async {
      // ignore: avoid_print
      print('\n=== Iniciando 50 conexões TLS sequenciais ===\n');
      
      var successCount = 0;
      var errorCount = 0;
      
      for (var i = 0; i < 50; i++) {
        try {
          final conn = await dbConnectAsync(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            encrypt: true,
            validateHost: false,
            tlsBackend: TlsBackend.tlslite,
          );
          
          final cursor = conn.cursor();
          await cursor.execute('SELECT $i AS num');
          final rows = await cursor.fetchall();
          await cursor.close();
          await conn.close();
          
          if (rows.isNotEmpty) {
            successCount++;
          }
          
          if ((i + 1) % 10 == 0) {
            // ignore: avoid_print
            print('Progresso: ${i + 1}/50');
          }
          
          // Pequeno delay entre conexões para evitar TIME_WAIT issues
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          errorCount++;
          // ignore: avoid_print
          print('Erro na conexão $i: $e');
        }
      }
      
      // ignore: avoid_print
      print('\nSucesso: $successCount/50, Erros: $errorCount');
      
      expect(successCount, equals(50), reason: 'Todas as 50 conexões devem ter sucesso');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('50 conexões SEM TLS sequenciais (baseline)', () async {
      // ignore: avoid_print
      print('\n=== Iniciando 50 conexões SEM TLS sequenciais ===\n');
      
      var successCount = 0;
      var errorCount = 0;
      
      for (var i = 0; i < 50; i++) {
        try {
          final conn = await dbConnectAsync(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            encrypt: false, // SEM TLS
          );
          
          final cursor = conn.cursor();
          await cursor.execute('SELECT $i AS num');
          final rows = await cursor.fetchall();
          await cursor.close();
          await conn.close();
          
          if (rows.isNotEmpty) {
            successCount++;
          }
          
          if ((i + 1) % 10 == 0) {
            // ignore: avoid_print
            print('Progresso: ${i + 1}/50');
          }
          
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          errorCount++;
          // ignore: avoid_print
          print('Erro na conexão $i: $e');
        }
      }
      
      // ignore: avoid_print
      print('\nSucesso: $successCount/50, Erros: $errorCount');
      
      expect(successCount, equals(50), reason: 'Todas as 50 conexões SEM TLS devem ter sucesso');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
