import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

extension Uint8Pointer on Pointer<Uint8> {
  /// Pointer arithmetic (takes element size into account).
  // Deprecated('Use operator + instead')
  Pointer<Uint8> elementAt(int index) =>
      Pointer.fromAddress(address + sizeOf<Uint8>() * index);

  /// A pointer to the [offset]th [Uint8] after this one.
  ///
  /// Returns a pointer to the [Uint8] whose address is
  /// [offset] times the size of `Uint8` after the address of this pointer.
  /// That is `(this + offset).address == this.address + offset * sizeOf<Uint8>()`.
  ///
  /// Also `(this + offset).value` is equivalent to `this[offset]`,
  /// and similarly for setting.

  Pointer<Uint8> operator +(int offset) =>
      Pointer.fromAddress(address + sizeOf<Uint8>() * offset);

  /// A pointer to the [offset]th [Uint8] before this one.
  ///
  /// Equivalent to `this + (-offset)`.
  ///
  /// Returns a pointer to the [Uint8] whose address is
  /// [offset] times the size of `Uint8` before the address of this pointer.
  /// That is, `(this - offset).address == this.address - offset * sizeOf<Uint8>()`.
  ///
  /// Also, `(this - offset).value` is equivalent to `this[-offset]`,
  /// and similarly for setting,
  Pointer<Uint8> operator -(int offset) =>
      Pointer.fromAddress(address - sizeOf<Uint8>() * offset);
}

final DynamicLibrary _lib = Platform.isWindows
    ? DynamicLibrary.open('ws2_32.dll')
    : Platform.isMacOS
        ? DynamicLibrary.open('libSystem.dylib')
        : DynamicLibrary.open('libc.so.6');

// ------------- WINDOWS -------------
final Pointer<Uint8> Function(int, int, int) _socketWin = _lib.lookupFunction<
    Pointer<Uint8> Function(Int32, Int32, Int32),
    Pointer<Uint8> Function(int, int, int)>('socket');

final int Function(Pointer<Uint8>, Pointer, int) _bindWin = _lib.lookupFunction<
    Int32 Function(Pointer<Uint8>, Pointer, Int32),
    int Function(Pointer<Uint8>, Pointer, int)>('bind');

final int Function(Pointer<Uint8>, int) _listenWin = _lib.lookupFunction<
    Int32 Function(Pointer<Uint8>, Int32),
    int Function(Pointer<Uint8>, int)>('listen');

final Pointer<Uint8> Function(Pointer<Uint8>, Pointer, Pointer<Int32>)
    _acceptWin = _lib.lookupFunction<
        Pointer<Uint8> Function(Pointer<Uint8>, Pointer, Pointer<Int32>),
        Pointer<Uint8> Function(
            Pointer<Uint8>, Pointer, Pointer<Int32>)>('accept');

final int Function(Pointer<Uint8>, Pointer, int) _connectWin =
    _lib.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer, Int32),
        int Function(Pointer<Uint8>, Pointer, int)>('connect');

final int Function(Pointer<Uint8>, Pointer<Uint8>, int, int) _sendWin =
    _lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Int32),
        int Function(Pointer<Uint8>, Pointer<Uint8>, int, int)>('send');

final int Function(Pointer<Uint8>, Pointer<Uint8>, int, int) _recvWin =
    _lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Int32),
        int Function(Pointer<Uint8>, Pointer<Uint8>, int, int)>('recv');

final int Function(Pointer<Uint8>) _closesocketWin = _lib.lookupFunction<
    Int32 Function(Pointer<Uint8>),
    int Function(Pointer<Uint8>)>('closesocket');

// ------------- Unix Functions (Linux and macOS) -------------
final int Function(int, int, int) _socketUnix = _lib.lookupFunction<
    Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket');

final int Function(int, Pointer, int) _bindUnix = _lib.lookupFunction<
    Int32 Function(Int32, Pointer, Int32),
    int Function(int, Pointer, int)>('bind');

final int Function(int, int) _listenUnix =
    _lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'listen');

final int Function(int, Pointer, Pointer<Int32>) _acceptUnix =
    _lib.lookupFunction<Int32 Function(Int32, Pointer, Pointer<Int32>),
        int Function(int, Pointer, Pointer<Int32>)>('accept');

final int Function(int, Pointer, int) _connectUnix = _lib.lookupFunction<
    Int32 Function(Int32, Pointer, Int32),
    int Function(int, Pointer, int)>('connect');

final int Function(int, Pointer<Uint8>, int, int) _sendUnix =
    _lib.lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32, Int32),
        int Function(int, Pointer<Uint8>, int, int)>('send');

final int Function(int, Pointer<Uint8>, int, int) _recvUnix =
    _lib.lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32, Int32),
        int Function(int, Pointer<Uint8>, int, int)>('recv');

final int Function(int) _closeUnix =
    _lib.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

// ------------- Helper Functions -------------
final int Function(int) _htons =
    _lib.lookupFunction<Uint16 Function(Uint16), int Function(int)>('htons');

final int Function(int, Pointer<Utf8>, Pointer) _inetPton = _lib.lookupFunction<
    Int32 Function(Int32, Pointer<Utf8>, Pointer),
    int Function(int, Pointer<Utf8>, Pointer)>('inet_pton');

final _gethostname = _lib.lookupFunction<Int32 Function(Pointer<Uint8>, Int32),
    int Function(Pointer<Uint8>, int)>('gethostname');

final _select = _lib.lookupFunction<
    Int32 Function(Int32, Pointer, Pointer, Pointer, Pointer),
    int Function(int, Pointer, Pointer, Pointer, Pointer)>('select');

final _ioctlsocket = _lib.lookupFunction<
    Int32 Function(Pointer<Uint8>, Int32, Pointer<Uint32>),
    int Function(Pointer<Uint8>, int, Pointer<Uint32>)>('ioctlsocket');

final _fcntl = _lib.lookupFunction<Int32 Function(Int32, Int32, Int32),
    int Function(int, int, int)>('fcntl');

final _recvfromWin = _lib.lookupFunction<
    Int32 Function(
        Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Pointer, Pointer<Int32>),
    int Function(Pointer<Uint8>, Pointer<Uint8>, int, int, Pointer,
        Pointer<Int32>)>('recvfrom');

final _recvfromUnix = _lib.lookupFunction<
    Int32 Function(
        Int32, Pointer<Uint8>, Int32, Int32, Pointer, Pointer<Int32>),
    int Function(
        int, Pointer<Uint8>, int, int, Pointer, Pointer<Int32>)>('recvfrom');

final _sendtoWin = _lib.lookupFunction<
    Int32 Function(
        Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Pointer, Int32),
    int Function(
        Pointer<Uint8>, Pointer<Uint8>, int, int, Pointer, int)>('sendto');

final _sendtoUnix = _lib.lookupFunction<
    Int32 Function(Int32, Pointer<Uint8>, Int32, Int32, Pointer, Int32),
    int Function(int, Pointer<Uint8>, int, int, Pointer, int)>('sendto');

final _inetNtop = _lib.lookupFunction<
    Pointer<Utf8> Function(Int32, Pointer, Pointer<Utf8>, Int32),
    Pointer<Utf8> Function(int, Pointer, Pointer<Utf8>, int)>('inet_ntop');

final _ntohs =
    _lib.lookupFunction<Uint16 Function(Uint16), int Function(int)>('ntohs');

// Binding para getsockname (Windows e Unix)
final int Function(Pointer<Uint8>, Pointer, Pointer<Int32>) _getsocknameWin =
    _lib.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer, Pointer<Int32>),
        int Function(Pointer<Uint8>, Pointer, Pointer<Int32>)>('getsockname');

final int Function(int, Pointer, Pointer<Int32>) _getsocknameUnix =
    _lib.lookupFunction<Int32 Function(Int32, Pointer, Pointer<Int32>),
        int Function(int, Pointer, Pointer<Int32>)>('getsockname');

int _getsockname(dynamic handle, Pointer addr, Pointer<Int32> addrLen) {
  if (Platform.isWindows) {
    return _getsocknameWin(handle as Pointer<Uint8>, addr, addrLen);
  } else {
    return _getsocknameUnix(handle as int, addr, addrLen);
  }
}

// Definindo os tipos equivalentes do C no Dart.
typedef UShort = Uint16;
typedef AddressFamily = Uint16;
typedef InAddr = Uint32; // Para IPv4
typedef ULong = Uint32;
//typedef AddressFamily = Uint16;
typedef SaFamilyT = Uint16;
typedef InPortT = Uint16;

// Structures
/// The sockaddr_in structure represents an IPv4 socket address.
final class SockaddrIn extends Struct {
  @Int16()
  external int sin_family;

  @Uint16()
  external int sin_port;

  @Uint32()
  external int s_addr; // campo para o endereço IPv4

  @Array<Uint8>(8)
  external Array<Uint8> sin_zero;
}

// Estrutura para IPv6
// Representação da estrutura IN6_ADDR (16 bytes para IPv6).
final class In6Addr extends Struct {
  @Array<Uint8>(16)
  external Array<Uint8> s6_addr;
}

// Representação da união SCOPE_ID.
final class ScopeIdUnion extends Union {
  @ULong()
  external int sin6_scope_id;
  external ScopeIdStruct sin6_scope_struct;
}

// Representação da estrutura SCOPE_ID (se necessário).
final class ScopeIdStruct extends Struct {
  // Defina os campos necessários aqui, se você precisar deles.
  // Exemplo (se houver campos dentro de SCOPE_ID):
  @Uint32()
  external int someField;
}

// Representação da estrutura sockaddr_in6. SockAddrIn6
final class SockAddrIn6 extends Struct {
  @SaFamilyT()
  external int sin6_family;

  @InPortT()
  external int sin6_port;

  @Uint32()
  external int sin6_flowinfo;

  external In6Addr sin6_addr;

  @Uint32()
  external int sin6_scope_id;
}

// Estrutura para timeout
final class Timeval extends Struct {
  @Int64()
  external int tv_sec;

  @Int64()
  external int tv_usec;
}
// Define Constants

const int AF_INET = 2; // IPv4 address family
const int SOCK_STREAM = 1; // TCP socket type
const int IPPROTO_TCP = 6; // TCP protocol
const int AF_INET6 = 23;
const int SOCK_DGRAM = 2;
const int INET6_ADDRSTRLEN = 46;

class SocketException implements Exception {
  final String message;
  SocketException(this.message);
  @override
  String toString() => 'SocketException: $message';
}

class Socket {
  Pointer<Uint8>? _socket; // Windows socket handle
  int? _fd; // Unix file descriptor
  bool _closed = false;
  final int _family; // AF_INET ou AF_INET6
  final int _type; // SOCK_STREAM ou SOCK_DGRAM
  double? _timeout; // Timeout em segundos

  (String, int) get address => getAddress();

  int get port => getAddress().$2;

  (String, int) getAddress() {
    String host;
    int port;
    final buffer = calloc<Uint8>(INET6_ADDRSTRLEN);

    if (_family == AF_INET) {
      // Para IPv4, aloca SockaddrIn.
      final addr = calloc<SockaddrIn>();
      final addrLen = calloc<Int32>()..value = sizeOf<SockaddrIn>();
      final handle = Platform.isWindows ? _socket : _fd;
      final result = _getsockname(handle!, addr.cast(), addrLen);
      if (result == -1) {
        calloc.free(addr);
        calloc.free(addrLen);
        calloc.free(buffer);
        throw SocketException('Failed to get socket address');
      }
      // O campo s_addr começa aos 4 bytes.
      final ptr = addr.cast<Uint8>() + 4;
      final convResult =
          _inetNtop(AF_INET, ptr, buffer.cast(), INET6_ADDRSTRLEN);
      if (convResult == nullptr) {
        calloc.free(addr);
        calloc.free(addrLen);
        calloc.free(buffer);
        throw SocketException('Failed to convert address');
      }
      host = buffer.cast<Utf8>().toDartString();
      port = _ntohs(addr.ref.sin_port);
      calloc.free(addr);
      calloc.free(addrLen);
    } else {
      // Para IPv6, aloca SockAddrIn6.
      final addr = calloc<SockAddrIn6>();
      final addrLen = calloc<Int32>()..value = sizeOf<SockAddrIn6>();
      final handle = Platform.isWindows ? _socket : _fd;
      final result = _getsockname(handle!, addr.cast(), addrLen);
      if (result == -1) {
        calloc.free(addr);
        calloc.free(addrLen);
        calloc.free(buffer);
        throw SocketException('Failed to get socket address');
      }
      // O campo sin6_addr inicia aos 8 bytes (2+2+4).
      const sin6AddrOffset = 8;
      final ptr = addr.cast<Uint8>() + sin6AddrOffset;
      final convResult =
          _inetNtop(AF_INET6, ptr, buffer.cast(), INET6_ADDRSTRLEN);
      if (convResult == nullptr) {
        calloc.free(addr);
        calloc.free(addrLen);
        calloc.free(buffer);
        throw SocketException('Failed to convert address');
      }
      host = buffer.cast<Utf8>().toDartString();
      port = _ntohs(addr.ref.sin6_port);
      calloc.free(addr);
      calloc.free(addrLen);
    }

    calloc.free(buffer);
    return (host, port);
  }

  // Construtor principal
  Socket(int family, int type, int protocol)
      : _family = family,
        _type = type {
    if (family != AF_INET && family != AF_INET6) {
      throw SocketException('Unsupported address family');
    }
    if (type != SOCK_STREAM && type != SOCK_DGRAM) {
      throw SocketException('Unsupported socket type');
    }
    if (Platform.isWindows) {
      _socket = _socketWin(family, type, protocol);
      if (_socket!.address == 0) {
        throw SocketException('Failed to create socket');
      }
    } else {
      _fd = _socketUnix(family, type, protocol);
      if (_fd == -1) {
        throw SocketException('Failed to create socket');
      }
    }
  }

  Socket._fromSocket(Pointer<Uint8> socket, this._family, this._type)
      : _socket = socket;
  Socket._fromFd(int fd, this._family, this._type) : _fd = fd;

  // **1. Suporte a gethostname()**
  static String gethostname() {
    final buffer = calloc<Uint8>(256);
    final result = _gethostname(buffer, 256);
    if (result != 0) {
      calloc.free(buffer);
      throw SocketException('Failed to get hostname');
    }
    final hostname = buffer.cast<Utf8>().toDartString();
    calloc.free(buffer);
    return hostname;
  }

  // **2. Suporte a settimeout()**
  void settimeout(double? timeout) {
    _timeout = timeout;
  }

  // **3. Suporte a sendall()**
  void sendall(Uint8List data) {
    int totalSent = 0;
    while (totalSent < data.length) {
      final sent = send(data.sublist(totalSent));
      if (sent == 0) {
        throw SocketException('Connection closed');
      }
      totalSent += sent;
    }
  }

  // **4. Suporte a UDP (SOCK_DGRAM)**
  (Uint8List, String, int) recvfrom(int bufferSize) {
    if (_type != SOCK_DGRAM) {
      throw SocketException('recvfrom is only for UDP sockets');
    }
    final buffer = calloc<Uint8>(bufferSize);
    final addr =
        _family == AF_INET ? calloc<SockaddrIn>() : calloc<SockAddrIn6>();
    final addrLen = calloc<Int32>()
      ..value =
          _family == AF_INET ? sizeOf<SockaddrIn>() : sizeOf<SockAddrIn6>();
    int received = Platform.isWindows
        ? _recvfromWin(_socket!, buffer, bufferSize, 0, addr.cast(), addrLen)
        : _recvfromUnix(_fd!, buffer, bufferSize, 0, addr.cast(), addrLen);
    if (received == -1) {
      calloc.free(buffer);
      calloc.free(addr);
      calloc.free(addrLen);
      throw SocketException('Recvfrom failed');
    }
    final data = Uint8List(received);
    for (int i = 0; i < received; i++) {
      data[i] = buffer[i];
    }

    String host;
    int port;
    final addrBuffer = calloc<Uint8>(INET6_ADDRSTRLEN);

    if (_family == AF_INET) {
      final sockAddrIn = addr.cast<SockaddrIn>().ref;
      // Para IPv4, o campo s_addr está em offset 4.
      final ptr = addr.cast<Uint8>() + 4;
      final result =
          _inetNtop(AF_INET, ptr, addrBuffer.cast(), INET6_ADDRSTRLEN);
      if (result == nullptr) {
        calloc.free(addrBuffer);
        throw SocketException('Failed to convert IPv4 address');
      }
      host = addrBuffer.cast<Utf8>().toDartString();
      port = _ntohs(sockAddrIn.sin_port);
    } else {
      final sockAddrIn6 = addr.cast<SockAddrIn6>().ref;
      // Para IPv6, o campo sin6_addr inicia aos 8 bytes.
      final ptr = addr.cast<Uint8>() + 8;
      final result =
          _inetNtop(AF_INET6, ptr, addrBuffer.cast(), INET6_ADDRSTRLEN);
      if (result == nullptr) {
        calloc.free(addrBuffer);
        throw SocketException('Failed to convert IPv6 address');
      }
      host = addrBuffer.cast<Utf8>().toDartString();
      port = _ntohs(sockAddrIn6.sin6_port);
    }

    calloc.free(buffer);
    calloc.free(addr);
    calloc.free(addrLen);
    calloc.free(addrBuffer);
    return (data, host, port);
  }

  int sendto(Uint8List data, String host, int port) {
    if (_type != SOCK_DGRAM) {
      throw SocketException('sendto is only for UDP sockets');
    }

    if (_family == AF_INET) {
      final addr = calloc<SockaddrIn>();
      addr.ref.sin_family = AF_INET;
      addr.ref.sin_port = _htons(port);
      final hostPtr = host.toNativeUtf8();
      final ipBuffer = calloc<Uint32>();
      final ip = _inetPton(AF_INET, hostPtr, ipBuffer.cast());
      calloc.free(hostPtr);
      if (ip != 1) {
        calloc.free(ipBuffer);
        calloc.free(addr);
        throw SocketException('Invalid address');
      }
      addr.ref.s_addr = ipBuffer.value;
      calloc.free(ipBuffer);

      final buffer = calloc<Uint8>(data.length);
      for (int i = 0; i < data.length; i++) {
        buffer[i] = data[i];
      }
      int sent = Platform.isWindows
          ? _sendtoWin(_socket!, buffer, data.length, 0, addr.cast(),
              sizeOf<SockaddrIn>())
          : _sendtoUnix(
              _fd!, buffer, data.length, 0, addr.cast(), sizeOf<SockaddrIn>());
      calloc.free(buffer);
      calloc.free(addr);
      if (sent == -1) throw SocketException('Sendto failed');
      return sent;
    } else {
      final addr = calloc<SockAddrIn6>();
      addr.ref.sin6_family = AF_INET6;
      addr.ref.sin6_port = _htons(port);
      final hostPtr = host.toNativeUtf8();
      final addrPtr = addr.cast<Uint8>();
      // O campo sin6_addr inicia aos 8 bytes:
      final ip = _inetPton(AF_INET6, hostPtr, addrPtr.elementAt(8));
      calloc.free(hostPtr);
      if (ip != 1) {
        calloc.free(addr);
        throw SocketException('Invalid address');
      }
      final buffer = calloc<Uint8>(data.length);
      for (int i = 0; i < data.length; i++) {
        buffer[i] = data[i];
      }
      int sent = Platform.isWindows
          ? _sendtoWin(_socket!, buffer, data.length, 0, addr.cast(),
              sizeOf<SockAddrIn6>())
          : _sendtoUnix(
              _fd!, buffer, data.length, 0, addr.cast(), sizeOf<SockAddrIn6>());
      calloc.free(buffer);
      calloc.free(addr);
      if (sent == -1) throw SocketException('Sendto failed');
      return sent;
    }
  }

  void bind(String host, int port) {
    if (_family == AF_INET) {
      // IPv4
      final addr = calloc<SockaddrIn>();
      addr.ref.sin_family = AF_INET;
      addr.ref.sin_port = _htons(port);

      final hostPtr = host.toNativeUtf8();
      final ipBuffer = calloc<Uint32>();
      final ip = _inetPton(AF_INET, hostPtr, ipBuffer.cast());
      calloc.free(hostPtr);
      if (ip != 1) {
        calloc.free(ipBuffer);
        calloc.free(addr);
        throw SocketException('Invalid address');
      }
      // Atribui o endereço binário ao campo s_addr
      addr.ref.s_addr = ipBuffer.value;
      calloc.free(ipBuffer);

      int result = Platform.isWindows
          ? _bindWin(_socket!, addr.cast(), sizeOf<SockaddrIn>())
          : _bindUnix(_fd!, addr.cast(), sizeOf<SockaddrIn>());
      calloc.free(addr);
      if (result != 0) throw SocketException('Bind failed');
    } else {
      // IPv6
      final addr = calloc<SockAddrIn6>();
      addr.ref.sin6_family = AF_INET6;
      addr.ref.sin6_port = _htons(port);

      // Aloca buffer temporário para receber os 16 bytes do endereço IPv6
      final temp = calloc<Uint8>(16);
      final hostPtr = host.toNativeUtf8();
      final ip = _inetPton(AF_INET6, hostPtr, temp);
      calloc.free(hostPtr);
      if (ip != 1) {
        calloc.free(temp);
        calloc.free(addr);
        throw SocketException('Invalid address');
      }

      // Cálculo de offset: sin6_family(2 bytes) + sin6_port(2 bytes) + sin6_flowinfo(4 bytes) = 8 bytes
      // Logo, o campo sin6_addr começa no offset 8
      const sin6AddrOffset = 8;

      // Ponteiro para o início da estrutura
      final addrPtr = addr.cast<Uint8>();

      // Copia os 16 bytes do buffer temporário (temp) para o campo sin6_addr
      for (int i = 0; i < 16; i++) {
        addrPtr.elementAt(sin6AddrOffset + i).value = temp[i];
      }
      calloc.free(temp);

      int result = Platform.isWindows
          ? _bindWin(_socket!, addr.cast(), sizeOf<SockAddrIn6>())
          : _bindUnix(_fd!, addr.cast(), sizeOf<SockAddrIn6>());
      calloc.free(addr);
      if (result != 0) throw SocketException('Bind failed');
    }
  }

  void connect(String host, int port) {
    if (_family == AF_INET) {
      final addr = calloc<SockaddrIn>();
      addr.ref.sin_family = AF_INET;
      addr.ref.sin_port = _htons(port);

      // Aloca buffer temporário para receber o endereço IPv4.
      final ipBuffer = calloc<Uint32>();
      final hostPtr = host.toNativeUtf8();
      final ip = _inetPton(AF_INET, hostPtr, ipBuffer.cast());
      calloc.free(hostPtr);

      if (ip != 1) {
        calloc.free(ipBuffer);
        calloc.free(addr);
        throw SocketException('Invalid address');
      }
      // Copia o valor convertido para o campo s_addr.
      addr.ref.s_addr = ipBuffer.value;
      calloc.free(ipBuffer);

      int result = Platform.isWindows
          ? _connectWin(_socket!, addr.cast(), sizeOf<SockaddrIn>())
          : _connectUnix(_fd!, addr.cast(), sizeOf<SockaddrIn>());
      calloc.free(addr);

      if (result != 0) throw SocketException('Connect failed');
    } else {
      final addr = calloc<SockAddrIn6>();
      addr.ref.sin6_family = AF_INET6;
      addr.ref.sin6_port = _htons(port);

      // Aloca buffer temporário de 16 bytes para o endereço IPv6.
      final temp = calloc<Uint8>(16);
      final hostPtr = host.toNativeUtf8();
      final ip = _inetPton(AF_INET6, hostPtr, temp);
      calloc.free(hostPtr);

      if (ip != 1) {
        calloc.free(temp);
        calloc.free(addr);
        throw SocketException('Invalid address');
      }

      // Cálculo de offset para sin6_addr: sin6_family(2) + sin6_port(2) + sin6_flowinfo(4) = 8 bytes
      const sin6AddrOffset = 8;
      final addrPtr = addr.cast<Uint8>();

      // Copia os 16 bytes de temp para o campo sin6_addr.
      for (int i = 0; i < 16; i++) {
        addrPtr.elementAt(sin6AddrOffset + i).value = temp[i];
      }
      calloc.free(temp);

      int result = Platform.isWindows
          ? _connectWin(_socket!, addr.cast(), sizeOf<SockAddrIn6>())
          : _connectUnix(_fd!, addr.cast(), sizeOf<SockAddrIn6>());
      calloc.free(addr);

      if (result != 0) throw SocketException('Connect failed');
    }
  }

  Socket accept() {
    if (_family == AF_INET) {
      final clientAddr = calloc<SockaddrIn>();
      final addrLen = calloc<Int32>()..value = sizeOf<SockaddrIn>();
      if (Platform.isWindows) {
        final clientSocket = _acceptWin(_socket!, clientAddr.cast(), addrLen);
        calloc.free(clientAddr);
        calloc.free(addrLen);
        if (clientSocket.address == 0) throw SocketException('Accept failed');
        return Socket._fromSocket(clientSocket, AF_INET, _type);
      } else {
        final clientFd = _acceptUnix(_fd!, clientAddr.cast(), addrLen);
        calloc.free(clientAddr);
        calloc.free(addrLen);
        if (clientFd == -1) throw SocketException('Accept failed');
        return Socket._fromFd(clientFd, AF_INET, _type);
      }
    } else {
      final clientAddr = calloc<SockAddrIn6>();
      final addrLen = calloc<Int32>()..value = sizeOf<SockAddrIn6>();
      if (Platform.isWindows) {
        final clientSocket = _acceptWin(_socket!, clientAddr.cast(), addrLen);
        calloc.free(clientAddr);
        calloc.free(addrLen);
        if (clientSocket.address == 0) throw SocketException('Accept failed');
        return Socket._fromSocket(clientSocket, AF_INET6, _type);
      } else {
        final clientFd = _acceptUnix(_fd!, clientAddr.cast(), addrLen);
        calloc.free(clientAddr);
        calloc.free(addrLen);
        if (clientFd == -1) throw SocketException('Accept failed');
        return Socket._fromFd(clientFd, AF_INET6, _type);
      }
    }
  }

  // **6. Modos não bloqueantes**
  void setblocking(bool flag) {
    if (Platform.isWindows) {
      final mode = calloc<Uint32>()..value = flag ? 0 : 1;
      final result = _ioctlsocket(_socket!, 0x8004667E, mode); // FIONBIO
      calloc.free(mode);
      if (result != 0) throw SocketException('Failed to set blocking mode');
    } else {
      final flags = _fcntl(_fd!, 3, 0); // F_GETFL
      if (flags == -1) throw SocketException('Failed to get flags');
      final newFlags = flag ? flags & ~0x800 : flags | 0x800; // O_NONBLOCK
      final result = _fcntl(_fd!, 4, newFlags); // F_SETFL
      if (result == -1) throw SocketException('Failed to set flags');
    }
  }

  int send(Uint8List data) {
    if (_timeout != null) {
      final fdSet = calloc<Uint8>(128); // Ajuste conforme necessário
      final timeoutStruct = calloc<Timeval>();
      timeoutStruct.ref.tv_sec = _timeout!.toInt();
      timeoutStruct.ref.tv_usec =
          ((_timeout! - _timeout!.toInt()) * 1000000).toInt();
      final maxFd = Platform.isWindows ? 0 : _fd! + 1;
      final result = _select(maxFd, nullptr, fdSet, nullptr, timeoutStruct);
      calloc.free(fdSet);
      calloc.free(timeoutStruct);
      if (result == 0) throw SocketException('Timeout');
      if (result == -1) throw SocketException('Select failed');
    }
    final buffer = calloc<Uint8>(data.length);
    for (int i = 0; i < data.length; i++) buffer[i] = data[i];
    int sent = Platform.isWindows
        ? _sendWin(_socket!, buffer, data.length, 0)
        : _sendUnix(_fd!, buffer, data.length, 0);
    calloc.free(buffer);
    if (sent == -1) throw SocketException('Send failed');
    return sent;
  }

  Uint8List recv(int bufferSize) {
    if (_timeout != null) {
      final fdSet = calloc<Uint8>(128); // Ajuste
      final timeoutStruct = calloc<Timeval>();
      timeoutStruct.ref.tv_sec = _timeout!.toInt();
      timeoutStruct.ref.tv_usec =
          ((_timeout! - _timeout!.toInt()) * 1000000).toInt();
      final maxFd = Platform.isWindows ? 0 : _fd! + 1;
      final result = _select(maxFd, fdSet, nullptr, nullptr, timeoutStruct);
      calloc.free(fdSet);
      calloc.free(timeoutStruct);
      if (result == 0) throw SocketException('Timeout');
      if (result == -1) throw SocketException('Select failed');
    }
    final buffer = calloc<Uint8>(bufferSize);
    int received = Platform.isWindows
        ? _recvWin(_socket!, buffer, bufferSize, 0)
        : _recvUnix(_fd!, buffer, bufferSize, 0);
    if (received == -1) {
      calloc.free(buffer);
      throw SocketException('Recv failed');
    }
    final data = Uint8List(received);
    for (int i = 0; i < received; i++) data[i] = buffer[i];
    calloc.free(buffer);
    return data;
  }

  void listen(int backlog) {
    int result = Platform.isWindows
        ? _listenWin(_socket!, backlog)
        : _listenUnix(_fd!, backlog);
    if (result != 0) throw SocketException('Listen failed');
  }

  void close() {
    if (_closed) return;
    int result =
        Platform.isWindows ? _closesocketWin(_socket!) : _closeUnix(_fd!);
    if (result != 0) throw SocketException('Close failed');
    _closed = true;
  }
}
