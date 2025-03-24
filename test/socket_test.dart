import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:mssql_dart/src/socket/socket_raw.dart'; // Substitua por onde sua classe Socket está definida

void main() {
  group('Testes da Classe Socket', () {
    // Teste 1: Criação de Socket TCP
    test('Criação de Socket TCP', () {
      final socket = Socket(AF_INET, SOCK_STREAM, 0);
      print('Criação de Socket TCP socket ${socket} ');
      expect(socket, isNotNull);
      socket.close();
    });

    // Teste 2: Criação de Socket UDP
    test('Criação de Socket UDP', () {
      final socket = Socket(AF_INET, SOCK_DGRAM, 0);
      expect(socket, isNotNull);
      socket.close();
    });

    // Teste 3: Bind e Listen (TCP)
    test('Bind e Listen (TCP)', () async {
      final server = Socket(AF_INET, SOCK_STREAM, 0);
      server.bind('127.0.0.1', 5580);
      server.listen(5);
      server.close();
    });

    // Teste 4: Connect (TCP)
    test('Connect (TCP)', () async {
      final server = Socket(AF_INET, SOCK_STREAM, 0);
      final serverPort = 5580;
      server.bind('127.0.0.1', serverPort);
      server.listen(5);

      final client = Socket(AF_INET, SOCK_STREAM, 0);
      client.connect('127.0.0.1', serverPort);

      final clientSocket = server.accept();
      expect(clientSocket, isNotNull);

      client.close();
      clientSocket.close();
      server.close();
    });

    // Teste 5: Send e Recv (TCP)
    test('Send e Recv (TCP)', () async {
      final serverPort = 5580;
      final server = Socket(AF_INET, SOCK_STREAM, 0);
      server.bind('127.0.0.1', serverPort);
      server.listen(5);

      final client = Socket(AF_INET, SOCK_STREAM, 0);
      client.connect('127.0.0.1', serverPort);

      final clientSocket = server.accept();

      final message = Uint8List.fromList('Olá, mundo!'.codeUnits);
      client.send(message);

      final received = clientSocket.recv(1024);
      expect(received, equals(message));

      client.close();
      clientSocket.close();
      server.close();
    });

    // Teste 6: Sendto e Recvfrom (UDP)
    test('Sendto e Recvfrom (UDP)', () async {
      final serverPort = 5580;
      final server = Socket(AF_INET, SOCK_DGRAM, 0);
      server.bind('127.0.0.1', serverPort);

      final client = Socket(AF_INET, SOCK_DGRAM, 0);

      final message = Uint8List.fromList('Olá, UDP!'.codeUnits);
      client.sendto(message, '127.0.0.1', serverPort);

      final (received, host, port) = server.recvfrom(1024);
      print('Sendto e Recvfrom (UDP) received $received | host $host | $port');
      //Sendto e Recvfrom (UDP) received [79, 108, 225, 44, 32, 85, 68, 80, 33] | host 127.0.0.1 | 59651
      expect(received, equals(message));
      expect(host, '127.0.0.1');
      expect(port, isNotNull);

      client.close();
      server.close();
    });

    // Teste 7: Suporte a IPv6
    test('Suporte a IPv6', () async {
      final serverPort = 5580;
      final server = Socket(AF_INET6, SOCK_STREAM, 0);
      server.bind('::1', serverPort);
      server.listen(5);

      final client = Socket(AF_INET6, SOCK_STREAM, 0);
      client.connect('::1', serverPort);

      final clientSocket = server.accept();
      expect(clientSocket, isNotNull);

      client.close();
      clientSocket.close();
      server.close();
    });

    // Teste 8: Timeout
    test('Timeout', () async {
      final socket = Socket(AF_INET, SOCK_STREAM, 0);
      socket.settimeout(1.0); // Timeout de 1 segundo

      expect(() => socket.recv(1024), throwsA(isA<SocketException>()));
      socket.close();
    });

    // Teste 9: Modo Não Bloqueante
    test('Modo Não Bloqueante', () async {
      final socket = Socket(AF_INET, SOCK_STREAM, 0);
      socket.setblocking(false);

      expect(() => socket.recv(1024), throwsA(isA<SocketException>()));
      socket.close();
    });

    // Teste 10: GetHostname
    test('GetHostname', () {
      final hostname = Socket.gethostname();
      expect(hostname, isNotEmpty);
    });
  });

  group('Socket getAddress', () {
    test('IPv4', () {
      final port = 5580;
      final server = Socket(AF_INET, SOCK_STREAM, 0);
      server.bind('127.0.0.1', port);
      final (host, boundPort) = server.address;
      expect(host, equals('127.0.0.1'));
      expect(boundPort, equals(port));
      server.close();
    });

    test('IPv6', () {
      final port = 5580;
      final server = Socket(AF_INET6, SOCK_STREAM, 0);
      server.bind('::1', port);
      final (host, boundPort) = server.address;
      // O endereço IPv6 pode vir no formato "::1" ou "0:0:0:0:0:0:0:1"
      expect(host, anyOf(equals('::1'), equals('0:0:0:0:0:0:0:1')));
      expect(boundPort, equals(port));
      server.close();
    });
  });
}
