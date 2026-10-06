import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/core/models/screen_stream_snapshot.dart';
import 'package:remotex/core/models/screen_stream_state.dart';
import 'package:remotex/core/models/remote_screen_coordinates.dart';

class RemoteScreenView extends StatefulWidget {
  const RemoteScreenView({
    super.key,
    required this.services,
    required this.sessionId,
  });

  final RemoteXServices services;
  final String sessionId;

  @override
  State<RemoteScreenView> createState() => _RemoteScreenViewState();
}

class _RemoteScreenViewState extends State<RemoteScreenView> {
  StreamSubscription<ScreenStreamSnapshot>? _subscription;
  StreamSubscription<String>? _controlSubscription;
  final TextEditingController _textController = TextEditingController();
  final Set<String> _heldModifiers = {};
  final Map<int, Offset> _activePointers = {};
  late ScreenStreamSnapshot _snapshot;
  RemoteScreenTransform _transform = const RemoteScreenTransform();
  RemoteScreenTransform _gestureStartTransform = const RemoteScreenTransform();
  Offset _gestureStartFocalPoint = Offset.zero;
  bool _stopping = false;
  bool _controlMode = false;
  bool _resettingText = false;
  bool _remoteButtonDown = false;
  bool _remoteDragActive = false;
  bool _controlGestureHadMultiplePointers = false;
  Offset? _controlPointerStart;
  String _previousText = '';
  String? _controlError;

  @override
  void initState() {
    super.initState();
    final stream = widget.services.screenStreamService;
    _snapshot = stream.snapshot;
    _subscription = stream.updates.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    _controlSubscription = widget.services.remoteControlService.updates.listen((
      sessionId,
    ) {
      if (mounted && sessionId == widget.sessionId) {
        setState(() {
          if (!_keyboardAuthorized) _heldModifiers.clear();
          if (!_mouseAuthorized && !_keyboardAuthorized) {
            _controlMode = false;
          }
        });
      }
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await widget.services.screenStreamService.startViewing(widget.sessionId);
    } on Object {
      if (mounted) {
        setState(
          () => _snapshot = widget.services.screenStreamService.snapshot,
        );
      }
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await widget.services.screenStreamService.stopViewing();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  bool get _mouseAuthorized =>
      widget.services.remoteControlService.canControlMouse(widget.sessionId);

  bool get _keyboardAuthorized =>
      widget.services.remoteControlService.canControlKeyboard(widget.sessionId);

  Future<void> _runControl(Future<void> action) async {
    try {
      await action;
      if (mounted && _controlError != null) {
        setState(() => _controlError = null);
      }
    } on Object {
      if (mounted) {
        setState(() => _controlError = 'Remote control command was rejected.');
      }
    }
  }

  void _click(String button, {String action = 'click'}) {
    if (!_controlMode || !_mouseAuthorized) return;
    unawaited(
      _runControl(
        widget.services.remoteControlService.sendMouseButton(
          widget.sessionId,
          button: button,
          action: action,
        ),
      ),
    );
  }

  Offset? _remotePosition(Offset scenePosition, Size canvasSize) {
    if (!_controlMode || !_mouseAuthorized) return null;
    final frame = _snapshot.frame;
    if (frame == null || canvasSize.isEmpty) return null;
    return RemoteScreenCoordinates.mapToNormalized(
      point: scenePosition,
      viewport: canvasSize,
      screenWidth: frame.width,
      screenHeight: frame.height,
    );
  }

  void _handlePointerDown(PointerDownEvent event, Size canvasSize) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length == 1) {
      _controlGestureHadMultiplePointers = false;
    }
    if (_activePointers.length == 1 &&
        _controlMode &&
        _mouseAuthorized &&
        _remotePosition(event.localPosition, canvasSize) != null) {
      _controlPointerStart = event.localPosition;
      _remoteDragActive = false;
      return;
    }
    if (_activePointers.length > 1) {
      _controlGestureHadMultiplePointers = true;
      _controlPointerStart = null;
      _remoteDragActive = false;
      _releaseRemoteButton();
    }
  }

  void _handlePointerMove(PointerMoveEvent event, Size canvasSize) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length != 1 ||
        !_controlMode ||
        !_mouseAuthorized ||
        _controlPointerStart == null) {
      return;
    }
    final position = _remotePosition(event.localPosition, canvasSize);
    if (position == null) return;
    _moveToRemotePosition(position);
    final start = _controlPointerStart;
    if (!_remoteButtonDown &&
        start != null &&
        (event.localPosition - start).distance > kTouchSlop) {
      _remoteDragActive = true;
      _sendMouseButton('down');
    }
  }

  void _handlePointerUp(PointerEvent event, Size canvasSize) {
    final position = _remotePosition(event.localPosition, canvasSize);
    final wasSinglePointer = _activePointers.length == 1;
    _activePointers.remove(event.pointer);
    if (!wasSinglePointer ||
        _controlGestureHadMultiplePointers ||
        !_controlMode ||
        !_mouseAuthorized) {
      if (_activePointers.isEmpty) _controlGestureHadMultiplePointers = false;
      return;
    }
    if (_remoteButtonDown) {
      _releaseRemoteButton();
    } else if (!_remoteDragActive && position != null) {
      _moveToRemotePosition(position);
      _sendMouseButton('click');
    }
    _controlPointerStart = null;
    _remoteDragActive = false;
    _controlGestureHadMultiplePointers = false;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _controlPointerStart = null;
    _remoteDragActive = false;
    _releaseRemoteButton();
  }

  void _moveToRemotePosition(Offset position) {
    unawaited(
      _runControl(
        widget.services.remoteControlService.sendMouseMove(
          widget.sessionId,
          x: position.dx,
          y: position.dy,
        ),
      ),
    );
  }

  void _sendMouseButton(String action) {
    _remoteButtonDown = action == 'down';
    unawaited(
      _runControl(
        widget.services.remoteControlService.sendMouseButton(
          widget.sessionId,
          button: 'left',
          action: action,
        ),
      ),
    );
  }

  void _releaseRemoteButton() {
    if (!_remoteButtonDown) return;
    _sendMouseButton('up');
  }

  void _handleScroll(PointerSignalEvent event, Size canvasSize) {
    if (event is! PointerScrollEvent ||
        !_controlMode ||
        !_mouseAuthorized ||
        _remotePosition(event.localPosition, canvasSize) == null) {
      return;
    }
    final deltaX = event.scrollDelta.dx.round().clamp(-2000, 2000);
    final deltaY = event.scrollDelta.dy.round().clamp(-2000, 2000);
    if (deltaX == 0 && deltaY == 0) return;
    unawaited(
      _runControl(
        widget.services.remoteControlService.sendMouseScroll(
          widget.sessionId,
          deltaX: deltaX,
          deltaY: deltaY,
        ),
      ),
    );
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _gestureStartTransform = _transform;
    _gestureStartFocalPoint = details.localFocalPoint;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details, Size viewport) {
    final frame = _snapshot.frame;
    if (frame == null) return;
    final contentSize = _fittedScreenSize(viewport, frame.width, frame.height);
    if (details.pointerCount == 1) {
      if (_controlMode) return;
      setState(() {
        _transform = RemoteScreenCoordinates.panBy(
          transform: _gestureStartTransform,
          delta: details.localFocalPoint - _gestureStartFocalPoint,
          viewport: viewport,
          contentSize: contentSize,
        );
      });
      return;
    }
    setState(() {
      _transform = RemoteScreenCoordinates.zoomAt(
        transform: _gestureStartTransform,
        anchorPoint: _gestureStartFocalPoint,
        focalPoint: details.localFocalPoint,
        scaleFactor: details.scale,
        viewport: viewport,
        contentSize: contentSize,
      );
    });
  }

  void _fitScreen() {
    setState(() => _transform = const RemoteScreenTransform());
  }

  Offset? _remoteCursorPosition(ScreenStreamSnapshot snapshot) {
    final cursor = snapshot.cursor;
    if (cursor == null || !cursor.visible) return null;
    return Offset(cursor.normalizedX, cursor.normalizedY);
  }

  Size _fittedScreenSize(Size viewport, int width, int height) {
    final fitScale = (viewport.width / width).clamp(
      0.0,
      viewport.height / height,
    );
    return Size(width * fitScale, height * fitScale);
  }

  void _onTextChanged(String value) {
    if (_resettingText) {
      _previousText = value;
      return;
    }
    if (!_controlMode || !_keyboardAuthorized) {
      _previousText = value;
      return;
    }
    var prefix = 0;
    while (prefix < _previousText.length &&
        prefix < value.length &&
        _previousText.codeUnitAt(prefix) == value.codeUnitAt(prefix)) {
      prefix++;
    }
    final removed = _previousText.length - prefix;
    for (var index = 0; index < removed; index++) {
      _sendKey('Backspace', 'press');
    }
    for (final codeUnit in value.substring(prefix).codeUnits) {
      if (codeUnit < 0x20 || codeUnit > 0x7e) {
        _controlError = 'Only basic Latin keyboard input is supported yet.';
        continue;
      }
      _sendKey(String.fromCharCode(codeUnit), 'press');
    }
    _previousText = value;
  }

  void _sendKey(String key, String action) {
    unawaited(
      _runControl(
        widget.services.remoteControlService.sendKeyboardKey(
          widget.sessionId,
          key: key,
          action: action,
        ),
      ),
    );
  }

  Future<void> _toggleModifier(String key) async {
    if (!_controlMode || !_keyboardAuthorized) return;
    final down = !_heldModifiers.contains(key);
    setState(() {
      if (down) {
        _heldModifiers.add(key);
      } else {
        _heldModifiers.remove(key);
      }
    });
    await _runControl(
      widget.services.remoteControlService.sendKeyboardKey(
        widget.sessionId,
        key: key,
        action: down ? 'down' : 'up',
      ),
    );
  }

  Future<void> _setControlMode(bool enabled) async {
    if (!enabled) {
      _releaseRemoteButton();
      _activePointers.clear();
      _controlPointerStart = null;
      for (final modifier in _heldModifiers.toList()) {
        _sendKey(modifier, 'up');
      }
      _heldModifiers.clear();
    }
    setState(() {
      _controlMode = enabled;
      _controlError = null;
      _previousText = '';
      _textController.clear();
    });
  }

  Future<void> _sendShortcut(String modifier, String key) async {
    if (!_controlMode || !_keyboardAuthorized) return;
    await _runControl(
      widget.services.remoteControlService.sendKeyboardKey(
        widget.sessionId,
        key: modifier,
        action: 'down',
      ),
    );
    await _runControl(
      widget.services.remoteControlService.sendKeyboardKey(
        widget.sessionId,
        key: key.length == 1 ? key.toLowerCase() : key,
        action: 'press',
      ),
    );
    await _runControl(
      widget.services.remoteControlService.sendKeyboardKey(
        widget.sessionId,
        key: modifier,
        action: 'up',
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_controlSubscription?.cancel());
    _textController.dispose();
    _releaseRemoteButton();
    for (final modifier in _heldModifiers) {
      unawaited(
        widget.services.remoteControlService.sendKeyboardKey(
          widget.sessionId,
          key: modifier,
          action: 'up',
        ),
      );
    }
    if (!_stopping) {
      unawaited(widget.services.screenStreamService.stopViewing());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _snapshot.frame;
    final stateLabel = switch (_snapshot.state) {
      ScreenStreamState.idle => 'Ready',
      ScreenStreamState.requesting => 'Requesting permission…',
      ScreenStreamState.starting => 'Starting capture…',
      ScreenStreamState.streaming => 'Live',
      ScreenStreamState.stopping => 'Stopping…',
      ScreenStreamState.failed => 'Unable to stream',
      ScreenStreamState.disconnected => 'Session disconnected',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote screen'),
        actions: [
          TextButton.icon(
            onPressed: _snapshot.state == ScreenStreamState.streaming
                ? () => _setControlMode(!_controlMode)
                : null,
            icon: Icon(_controlMode ? Icons.touch_app : Icons.pan_tool_alt),
            label: Text(_controlMode ? 'Control on' : 'Control'),
          ),
          IconButton(
            onPressed: frame == null ? null : _fitScreen,
            tooltip: 'Fit screen',
            icon: const Icon(Icons.fit_screen),
          ),
          TextButton.icon(
            onPressed: _stopping ? null : _stop,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: frame == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_snapshot.state == ScreenStreamState.requesting ||
                              _snapshot.state == ScreenStreamState.starting)
                            const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(_snapshot.error ?? stateLabel),
                        ],
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final size = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        final cursor = _remoteCursorPosition(_snapshot);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: _handleScaleStart,
                          onScaleUpdate: (details) =>
                              _handleScaleUpdate(details, size),
                          child: ClipRect(
                            child: Transform.translate(
                              offset: _transform.translation,
                              child: Transform.scale(
                                scale: _transform.scale,
                                alignment: Alignment.topLeft,
                                child: Listener(
                                  onPointerSignal: (event) =>
                                      _handleScroll(event, size),
                                  onPointerDown: (event) =>
                                      _handlePointerDown(event, size),
                                  onPointerMove: (event) =>
                                      _handlePointerMove(event, size),
                                  onPointerUp: (event) =>
                                      _handlePointerUp(event, size),
                                  onPointerCancel: _handlePointerCancel,
                                  child: SizedBox(
                                    width: size.width,
                                    height: size.height,
                                    child: FittedBox(
                                      fit: BoxFit.contain,
                                      child: SizedBox(
                                        width: frame.width.toDouble(),
                                        height: frame.height.toDouble(),
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.memory(
                                              frame.encodedBytes,
                                              cacheWidth: frame.width,
                                              cacheHeight: frame.height,
                                              gaplessPlayback: true,
                                              fit: BoxFit.fill,
                                              filterQuality: FilterQuality.low,
                                            ),
                                            if (cursor != null)
                                              Positioned(
                                                left: cursor.dx * frame.width,
                                                top: cursor.dy * frame.height,
                                                child: const IgnorePointer(
                                                  child: CustomPaint(
                                                    size: Size(24, 28),
                                                    painter:
                                                        _RemoteCursorPainter(),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            ListTile(
              leading: Icon(
                Icons.circle,
                size: 12,
                color: _snapshot.state == ScreenStreamState.streaming
                    ? Colors.green
                    : Colors.grey,
              ),
              title: Text(stateLabel),
              subtitle: Text(
                '${_snapshot.dimensions ?? '--'} · '
                '${_snapshot.framesPerSecond.toStringAsFixed(1)} FPS · '
                '${_controlMode ? 'Control enabled' : 'View only'}',
              ),
              trailing: _snapshot.error == null
                  ? null
                  : IconButton(
                      tooltip: _snapshot.error,
                      icon: const Icon(Icons.error_outline),
                      onPressed: () => ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(_snapshot.error!))),
                    ),
            ),
            if (_controlMode) ...[
              if (!_mouseAuthorized)
                const ListTile(
                  dense: true,
                  leading: Icon(Icons.info_outline),
                  title: Text('Mouse control is not authorized by this host.'),
                ),
              if (!_keyboardAuthorized)
                const ListTile(
                  dense: true,
                  leading: Icon(Icons.info_outline),
                  title: Text(
                    'Keyboard control is not authorized by this host.',
                  ),
                ),
              if (_keyboardAuthorized)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _textController,
                    enabled: _controlMode && _keyboardAuthorized,
                    onChanged: _onTextChanged,
                    onSubmitted: (_) {
                      _sendKey('Enter', 'press');
                      _resettingText = true;
                      _textController.clear();
                      _previousText = '';
                      _resettingText = false;
                    },
                    decoration: const InputDecoration(
                      hintText: 'Type on the remote computer',
                      prefixIcon: Icon(Icons.keyboard),
                    ),
                  ),
                ),
              if (_keyboardAuthorized)
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  children: [
                    for (final key in ['Control', 'Alt', 'Shift', 'Meta'])
                      FilterChip(
                        selected: _heldModifiers.contains(key),
                        label: Text(key == 'Control' ? 'Ctrl' : key),
                        onSelected: (_) => _toggleModifier(key),
                      ),
                    for (final key in ['C', 'V', 'A', 'Tab'])
                      ActionChip(
                        label: Text(key == 'Tab' ? 'Alt+Tab' : 'Ctrl+$key'),
                        onPressed: () => _sendShortcut(
                          key == 'Tab' ? 'Alt' : 'Control',
                          key,
                        ),
                      ),
                  ],
                ),
              if (_mouseAuthorized)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _click('right'),
                    icon: const Icon(Icons.mouse),
                    label: const Text('Right click'),
                  ),
                ),
              if (_controlError != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _controlError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RemoteCursorPainter extends CustomPainter {
  const _RemoteCursorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(1, 1)
      ..lineTo(1, 21)
      ..lineTo(6, 16)
      ..lineTo(11, 27)
      ..lineTo(15, 25)
      ..lineTo(10, 14)
      ..lineTo(19, 14)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _RemoteCursorPainter oldDelegate) => false;
}
