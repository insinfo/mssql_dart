import 'dart:io';

/// Socket "fake" que só implementa a interface Socket,
/// mas não é a implementação interna de dart:io.
///
/// Repare que só sobrescrevemos noSuchMethod:
/// isso é suficiente para o código compilar,
/// mas a classe NÃO tem o método privado `_detachRaw`
/// que o SecureSocket.secure espera encontrar.
class FakeSocket implements Socket {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    print('FakeSocket.noSuchMethod -> ${invocation.memberName}');
    return super.noSuchMethod(invocation);
  }
  //  Future<List<Object?>> _detachRaw(){
  //   return Future.value(<Object?>[]);
  //  }
}

Future<void> main() async {
  final socket = FakeSocket();

  print('Runtime type do socket: ${socket.runtimeType}');
  print('Chamando SecureSocket.secure(FakeSocket)...');

  try {
    // Aqui é onde a mágica (e o problema) acontece:
    // SecureSocket.secure vai tentar fazer:
    //   socket._detachRaw()
    // como mostrado na implementação oficial do SDK.
    await SecureSocket.secure(
      socket,
      host: 'example.com',
    );

    print('>>> SURPRESA: SecureSocket.secure não falhou (isso seria estranho).');
  } catch (e, st) {
    print('----------------------------------------');
    print('SecureSocket.secure FALHOU como esperado.');
    print('Tipo do erro: ${e.runtimeType}');
    print('Mensagem: $e');
    print('Stack trace:');
    print(st);
    print('----------------------------------------');
    print('Isso demonstra que SecureSocket.secure depende de um método interno');
    print("(_detachRaw) que não existe em uma implementação custom de Socket.");
  }
}
