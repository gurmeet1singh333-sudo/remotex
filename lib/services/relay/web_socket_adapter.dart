export 'web_socket_adapter_stub.dart'
    if (dart.library.io) 'web_socket_adapter_vm.dart'
    if (dart.library.html) 'web_socket_adapter_web.dart';
