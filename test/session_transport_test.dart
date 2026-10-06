import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/services/session/lan_session_transport.dart';

void main() {
  test('bounds raw session-frame input before JSON parsing', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    final subscription = server.listen(accepted.complete);
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final wire = JsonSocketSessionWire(await accepted.future);
    client.add(List<int>.filled(16385, 0x61));
    await client.flush();

    await expectLater(
      wire.readMessage(),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.malformedMessage,
        ),
      ),
    );

    await wire.close();
    client.destroy();
    await subscription.cancel();
    await server.close();
  });

  test(
    'reads multiple bounded messages coalesced into one TCP chunk',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final subscription = server.listen(accepted.complete);
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final wire = JsonSocketSessionWire(await accepted.future);
      client.add('{"first":1}\n{"second":2}\n'.codeUnits);
      await client.flush();

      expect(await wire.readMessage(), {'first': 1});
      expect(await wire.readMessage(), {'second': 2});

      await wire.close();
      client.destroy();
      await subscription.cancel();
      await server.close();
    },
  );
}
