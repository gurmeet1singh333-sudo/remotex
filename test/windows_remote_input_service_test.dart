import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/session/windows_remote_input_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'maps the typed input service calls to the runner channel contract',
    () async {
      const channel = MethodChannel('remotex/test_remote_input');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final service = WindowsRemoteInputService(channel: channel);
      await service.movePointer(0.25, 0.75);
      await service.mouseButton('left', 'down');
      await service.scroll(2, -3);
      await service.keyboardKey('Control', 'up');
      await service.releaseAll();

      expect(calls.map((call) => call.method), [
        'movePointer',
        'mouseButton',
        'scroll',
        'keyboardKey',
        'releaseAll',
      ]);
      expect(calls[0].arguments, {'x': 0.25, 'y': 0.75});
      expect(calls[1].arguments, {'button': 'left', 'action': 'down'});
      expect(calls[2].arguments, {'deltaX': 2, 'deltaY': -3});
      expect(calls[3].arguments, {'key': 'Control', 'action': 'up'});
    },
  );
}
