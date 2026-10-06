import 'dart:async';

import 'package:flutter/services.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/remote_cursor_position.dart';
import 'package:remotex/core/services/screen_capture_service.dart';

class WindowsScreenCaptureService implements ScreenCaptureService {
  WindowsScreenCaptureService({
    MethodChannel? channel,
    DateTime Function()? clock,
  }) : _channel = channel ?? const MethodChannel('remotex/screen_capture'),
       _clock = clock ?? DateTime.now;

  static const targetInterval = Duration(milliseconds: 100);
  final MethodChannel _channel;
  final DateTime Function() _clock;
  final _frames = StreamController<ScreenFrame>.broadcast();
  ScreenDimensions? _dimensions;
  Object? _lastError;
  bool _capturing = false;
  int _sequence = 0;
  Future<void>? _captureLoop;

  @override
  Stream<ScreenFrame> get frames => _frames.stream;

  @override
  Object? get lastError => _lastError;

  @override
  Future<ScreenDimensions> startCapture() async {
    if (_capturing) {
      throw StateError('Screen capture is already running.');
    }
    final result = await _channel.invokeMapMethod<String, Object?>('start');
    final width = result?['width'];
    final height = result?['height'];
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      await _channel.invokeMethod<void>('stop');
      throw StateError('Windows screen capture returned invalid dimensions.');
    }
    _dimensions = ScreenDimensions(width: width, height: height);
    _lastError = null;
    _sequence = 0;
    _capturing = true;
    _captureLoop = _runCaptureLoop();
    return _dimensions!;
  }

  @override
  Future<RemoteCursorPosition?> getCursorPosition() async {
    if (!_capturing) return null;
    final result = await _channel.invokeMapMethod<String, Object?>(
      'cursorPosition',
    );
    if (result == null) return null;
    final x = result['x'];
    final y = result['y'];
    final width = result['width'];
    final height = result['height'];
    final visible = result['visible'];
    if (x is! int ||
        y is! int ||
        width is! int ||
        height is! int ||
        visible is! bool ||
        width <= 0 ||
        height <= 0 ||
        x < 0 ||
        x >= width ||
        y < 0 ||
        y >= height) {
      throw StateError('Windows returned invalid cursor coordinates.');
    }
    return RemoteCursorPosition(
      x: x,
      y: y,
      width: width,
      height: height,
      visible: visible,
    );
  }

  Future<void> _runCaptureLoop() async {
    try {
      while (_capturing) {
        final startedAt = DateTime.now();
        final result = await _channel.invokeMapMethod<String, Object?>('frame');
        if (!_capturing) break;
        if (result != null && result['data'] is Uint8List) {
          final bytes = result['data']! as Uint8List;
          final width = result['width'];
          final height = result['height'];
          if (width is! int || height is! int) {
            throw StateError(
              'Windows screen capture returned invalid frame data.',
            );
          }
          _frames.add(
            ScreenFrame(
              sequence: _sequence++,
              timestamp: _clock().toUtc(),
              width: width,
              height: height,
              format: ScreenFrameFormat.jpeg,
              keyFrame: true,
              encodedBytes: bytes,
            ),
          );
        }
        final remaining = targetInterval - DateTime.now().difference(startedAt);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
    } on Object catch (error) {
      _lastError = error;
      _frames.addError(error);
      _capturing = false;
      try {
        await _channel.invokeMethod<void>('stop');
      } on Object catch (stopError) {
        _lastError = stopError;
        _frames.addError(stopError);
      }
    }
  }

  @override
  Future<void> stopCapture() async {
    if (!_capturing && _captureLoop == null) return;
    _capturing = false;
    await _captureLoop;
    _captureLoop = null;
    await _channel.invokeMethod<void>('stop');
    _dimensions = null;
  }

  Future<void> dispose() async {
    await stopCapture();
    await _frames.close();
  }
}

class UnavailableScreenCaptureService implements ScreenCaptureService {
  final _frames = StreamController<ScreenFrame>.broadcast();

  @override
  Stream<ScreenFrame> get frames => _frames.stream;

  @override
  Object? get lastError => null;

  @override
  Future<ScreenDimensions> startCapture() => Future.error(
    UnsupportedError('Screen capture is available on Windows only.'),
  );

  @override
  Future<RemoteCursorPosition?> getCursorPosition() async => null;

  @override
  Future<void> stopCapture() async {}
}
