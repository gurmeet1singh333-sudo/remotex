import 'package:remotex/core/models/paired_device.dart';

abstract interface class SessionTransport {
  Stream<SessionWire> get incomingConnections;

  Future<void> startHost(String hostId);

  Future<SessionWire> connect(PairedDevice host);

  Future<void> stopHost();
}

abstract interface class SessionWire {
  Future<Map<String, Object?>> readMessage();

  Future<void> writeMessage(Map<String, Object?> message);

  Future<void> close();
}
