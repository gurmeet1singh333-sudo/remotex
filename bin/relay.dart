import 'dart:async';
import 'dart:io';

import 'package:remotex/services/relay/relay_server.dart';

Future<void> main() async {
  final config = RemoteXRelayConfig.fromEnvironment();
  final relay = RemoteXRelayServer(config: config);
  await relay.start();
  // ignore: avoid_print
  print('RemoteX Relay Server listening on http://${config.host}:${config.port}');

  Future<void> shutdown() async {
    // ignore: avoid_print
    print('Shutting down RemoteX Relay Server...');
    await relay.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown()));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown()));
  }
}
