import 'package:flutter/services.dart';
import 'package:remotex/core/services/remote_input_service.dart';

class WindowsRemoteInputService implements RemoteInputService {
  WindowsRemoteInputService({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('remotex/remote_input');

  final MethodChannel _channel;

  @override
  Future<void> movePointer(double x, double y) =>
      _channel.invokeMethod<void>('movePointer', {'x': x, 'y': y});

  @override
  Future<void> mouseButton(String button, String action) =>
      _channel.invokeMethod<void>(
        'mouseButton',
        {'button': button, 'action': action},
      );

  @override
  Future<void> scroll(int deltaX, int deltaY) =>
      _channel.invokeMethod<void>(
        'scroll',
        {'deltaX': deltaX, 'deltaY': deltaY},
      );

  @override
  Future<void> keyboardKey(String key, String action) =>
      _channel.invokeMethod<void>(
        'keyboardKey',
        {'key': key, 'action': action},
      );

  @override
  Future<void> releaseAll() => _channel.invokeMethod<void>('releaseAll');
}

class UnavailableRemoteInputService implements RemoteInputService {
  @override
  Future<void> movePointer(double x, double y) =>
      _unavailable();

  @override
  Future<void> mouseButton(String button, String action) =>
      _unavailable();

  @override
  Future<void> scroll(int deltaX, int deltaY) =>
      _unavailable();

  @override
  Future<void> keyboardKey(String key, String action) =>
      _unavailable();

  @override
  Future<void> releaseAll() async {}

  Future<void> _unavailable() =>
      Future.error(UnsupportedError('Remote input is available on Windows only.'));
}
