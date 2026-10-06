import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/remote_screen_coordinates.dart';
import 'package:remotex/core/models/screen_stream_snapshot.dart';
import 'package:remotex/core/models/screen_stream_state.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/models/web_pairing_payload.dart';
import 'package:remotex/core/services/pairing_failure.dart';
import 'package:remotex/services/relay/relay_session_transport.dart';

class WebRemoteScreen extends StatefulWidget {
  const WebRemoteScreen({
    super.key,
    required this.services,
    this.initialPayload,
  });

  final RemoteXServices services;
  final WebPairingPayload? initialPayload;

  @override
  State<WebRemoteScreen> createState() => _WebRemoteScreenState();
}

class _WebRemoteScreenState extends State<WebRemoteScreen> {
  final _payloadController = TextEditingController();
  final _focusNode = FocusNode();

  StreamSubscription<ScreenStreamSnapshot>? _streamSub;
  StreamSubscription<String>? _controlUpdatesSub;
  StreamSubscription<SessionState>? _sessionStateSub;

  ScreenStreamSnapshot _snapshot = const ScreenStreamSnapshot(
    state: ScreenStreamState.idle,
  );

  bool _isConnecting = false;
  bool _controlEnabled = false;
  bool _isFullscreen = false;
  double _zoomScale = 1.0;
  Offset _panOffset = Offset.zero;
  String? _statusText;
  String? _currentSessionId;
  PairedDevice? _hostDevice;

  @override
  void initState() {
    super.initState();
    if (widget.initialPayload != null) {
      _payloadController.text = widget.initialPayload!.encode();
      unawaited(_connectWithPayload(widget.initialPayload!));
    }
    _streamSub = widget.services.screenStreamService.updates.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    _controlUpdatesSub = widget.services.remoteControlService.updates.listen((sessionId) {
      if (mounted && sessionId == _currentSessionId) {
        setState(() {});
      }
    });
    _sessionStateSub = widget.services.sessionService.stateChanges.listen((state) {
      if (!mounted) return;
      setState(() {
        switch (state) {
          case SessionState.connected:
            _statusText = 'Connected to ${_hostDevice?.name ?? "Host"}';
            break;
          case SessionState.connecting:
            _statusText = 'Connecting to host…';
            break;
          case SessionState.authenticating:
            _statusText = 'Authenticating session…';
            break;
          case SessionState.reconnecting:
            _statusText = 'Reconnecting to host…';
            _controlEnabled = false;
            break;
          case SessionState.networkDisconnected:
            _statusText = 'Network connection lost. Retrying…';
            _controlEnabled = false;
            break;
          case SessionState.authenticationFailed:
            _statusText = 'Session authentication failed.';
            _controlEnabled = false;
            break;
          case SessionState.revoked:
            _statusText = 'Device authorization was revoked by host.';
            _controlEnabled = false;
            break;
          case SessionState.unknownDevice:
            _statusText = 'Device is not trusted by host.';
            _controlEnabled = false;
            break;
          case SessionState.disconnected:
            _statusText = 'Disconnected';
            _controlEnabled = false;
            break;
          case SessionState.disconnecting:
            _statusText = 'Disconnecting…';
            _controlEnabled = false;
            break;
        }
      });
    });
  }

  Future<void> _connectRawPayload() async {
    final text = _payloadController.text.trim();
    if (text.isEmpty) return;
    try {
      final payload = WebPairingPayload.parse(text);
      await _connectWithPayload(payload);
    } on FormatException catch (e) {
      setState(() => _statusText = 'Invalid pairing data: ${e.message}');
    } on Object catch (e) {
      setState(() => _statusText = 'Connection failed: $e');
    }
  }

  Future<void> _connectWithPayload(WebPairingPayload payload) async {
    setState(() {
      _isConnecting = true;
      _statusText = 'Connecting to relay server…';
    });

    try {
      final relayTransport = RelaySessionTransport(relayUrl: payload.relayUrl);
      final wire = await relayTransport.connect(
        PairedDevice(
          id: payload.hostId,
          name: payload.hostName,
          hostId: payload.hostId,
          publicKey: payload.hostPublicKey,
          addedAt: DateTime.now().toUtc(),
        ),
      );

      setState(() => _statusText = 'Authenticating web pairing session…');
      final webPairingService = widget.services.webPairingService;
      if (webPairingService != null) {
        final paired = await webPairingService.pairWebClient(
          payload: payload,
          wire: wire,
        );
        _hostDevice = paired;
      } else {
        _hostDevice = PairedDevice(
          id: payload.hostId,
          name: payload.hostName,
          hostId: payload.hostId,
          publicKey: payload.hostPublicKey,
          addedAt: DateTime.now().toUtc(),
        );
      }

      setState(() => _statusText = 'Opening session with host…');
      final sessionInfo = await widget.services.sessionService.connect(_hostDevice!);
      _currentSessionId = sessionInfo.sessionId;

      setState(() => _statusText = 'Starting screen stream…');
      await widget.services.screenStreamService.startViewing(sessionInfo.sessionId);

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _statusText = 'Connected to ${payload.hostName}';
        });
      }
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _statusText = 'Pairing failed: ${e.failure.name}';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _statusText = 'Could not connect. The host or relay server is unreachable.';
        });
      }
    }
  }

  Future<void> _disconnect() async {
    final sid = _currentSessionId;
    if (sid != null) {
      await widget.services.screenStreamService.stopViewing();
      await widget.services.sessionService.disconnect();
    }
    if (mounted) {
      setState(() {
        _currentSessionId = null;
        _hostDevice = null;
        _controlEnabled = false;
        _isConnecting = false;
        _statusText = 'Disconnected';
      });
    }
  }

  bool get _canControlMouse {
    final sid = _currentSessionId;
    if (sid == null || !_controlEnabled) return false;
    return widget.services.remoteControlService.canControlMouse(sid);
  }

  bool get _canControlKeyboard {
    final sid = _currentSessionId;
    if (sid == null || !_controlEnabled) return false;
    return widget.services.remoteControlService.canControlKeyboard(sid);
  }

  void _onPointerMove(PointerMoveEvent event, BoxConstraints constraints) {
    if (!_canControlMouse || _currentSessionId == null) return;
    final mapped = _mapToHostCoordinates(event.localPosition, constraints);
    if (mapped != null) {
      unawaited(
        widget.services.remoteControlService.sendMouseMove(
          _currentSessionId!,
          x: mapped.dx,
          y: mapped.dy,
        ),
      );
    }
  }

  void _onPointerDown(PointerDownEvent event, BoxConstraints constraints) {
    if (!_canControlMouse || _currentSessionId == null) return;
    _focusNode.requestFocus();
    final mapped = _mapToHostCoordinates(event.localPosition, constraints);
    if (mapped != null) {
      final button = event.buttons == kSecondaryMouseButton ? 'right' : 'left';
      unawaited(
        widget.services.remoteControlService.sendMouseButton(
          _currentSessionId!,
          button: button,
          action: 'down',
        ),
      );
    }
  }

  void _onPointerUp(PointerUpEvent event, BoxConstraints constraints) {
    if (!_canControlMouse || _currentSessionId == null) return;
    final mapped = _mapToHostCoordinates(event.localPosition, constraints);
    if (mapped != null) {
      final button = event.buttons == kSecondaryMouseButton ? 'right' : 'left';
      unawaited(
        widget.services.remoteControlService.sendMouseButton(
          _currentSessionId!,
          button: button,
          action: 'up',
        ),
      );
    }
  }

  void _onPointerSignal(PointerSignalEvent event, BoxConstraints constraints) {
    if (!_canControlMouse || _currentSessionId == null) return;
    if (event is PointerScrollEvent) {
      final dx = event.scrollDelta.dx.round().clamp(-2000, 2000);
      final dy = event.scrollDelta.dy.round().clamp(-2000, 2000);
      if (dx != 0 || dy != 0) {
        unawaited(
          widget.services.remoteControlService.sendMouseScroll(
            _currentSessionId!,
            deltaX: dx,
            deltaY: dy,
          ),
        );
      }
    }
  }

  void _onKeyEvent(KeyEvent event) {
    if (!_canControlKeyboard || _currentSessionId == null) return;
    final keyLabel = _mapLogicalKeyToRemote(event.logicalKey);
    if (keyLabel == null) return;
    final action = event is KeyDownEvent
        ? 'down'
        : event is KeyUpEvent
            ? 'up'
            : null;
    if (action != null) {
      unawaited(
        widget.services.remoteControlService.sendKeyboardKey(
          _currentSessionId!,
          key: keyLabel,
          action: action,
        ),
      );
    }
  }

  Offset? _mapToHostCoordinates(Offset localPos, BoxConstraints constraints) {
    final frame = _snapshot.frame;
    final screenW = frame?.width ?? 1920;
    final screenH = frame?.height ?? 1080;

    return RemoteScreenCoordinates.mapTransformedToNormalized(
      point: localPos,
      viewport: constraints.biggest,
      screenWidth: screenW,
      screenHeight: screenH,
      scale: _zoomScale,
      translation: _panOffset,
    );
  }

  String? _mapLogicalKeyToRemote(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.enter) return 'Enter';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
    if (key == LogicalKeyboardKey.arrowDown) return 'ArrowDown';
    if (key == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
    if (key == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
    if (key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight) return 'Control';
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight) return 'Alt';
    if (key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight) return 'Shift';
    if (key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) return 'Meta';
    if (key.keyLabel.isNotEmpty && key.keyLabel.length == 1) {
      final code = key.keyLabel.codeUnitAt(0);
      if (code >= 0x20 && code <= 0x7e) {
        return key.keyLabel;
      }
    }
    return null;
  }

  @override
  void dispose() {
    unawaited(_sessionStateSub?.cancel());
    unawaited(_streamSub?.cancel());
    unawaited(_controlUpdatesSub?.cancel());
    _focusNode.dispose();
    _payloadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _snapshot.state == ScreenStreamState.streaming;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteX Web Remote'),
        actions: [
          if (isConnected) ...[
            Row(
              children: [
                const Text('Control'),
                Switch(
                  value: _controlEnabled,
                  onChanged: (val) {
                    setState(() => _controlEnabled = val);
                  },
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.zoom_in),
              onPressed: () => setState(() => _zoomScale = (_zoomScale + 0.25).clamp(1.0, 3.0)),
              tooltip: 'Zoom In',
            ),
            IconButton(
              icon: const Icon(Icons.zoom_out),
              onPressed: () => setState(() {
                _zoomScale = (_zoomScale - 0.25).clamp(1.0, 3.0);
                if (_zoomScale == 1.0) _panOffset = Offset.zero;
              }),
              tooltip: 'Zoom Out',
            ),
            IconButton(
              icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
              onPressed: () => setState(() => _isFullscreen = !_isFullscreen),
              tooltip: 'Fullscreen',
            ),
            FilledButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Disconnect'),
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
      body: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) {
          _onKeyEvent(event);
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            if (_statusText != null)
              Container(
                width: double.infinity,
                color: isConnected ? Colors.green.shade800 : Colors.blueGrey.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  _statusText!,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            if (!isConnected && !_isConnecting)
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: Card(
                      margin: const EdgeInsets.all(24),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Connect to RemoteX Host',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _payloadController,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: 'Paste Web Pairing Payload JSON or URL…',
                                labelText: 'Pairing Payload',
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _connectRawPayload,
                              icon: const Icon(Icons.login),
                              label: const Text('Connect & Pair'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else if (_isConnecting)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Connecting to RemoteX Host…'),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final frame = _snapshot.frame;
                    return Listener(
                      onPointerDown: (e) => _onPointerDown(e, constraints),
                      onPointerUp: (e) => _onPointerUp(e, constraints),
                      onPointerMove: (e) => _onPointerMove(e, constraints),
                      onPointerSignal: (e) => _onPointerSignal(e, constraints),
                      child: GestureDetector(
                        onPanUpdate: _zoomScale > 1.0
                            ? (details) => setState(() => _panOffset += details.delta)
                            : null,
                        child: Container(
                          color: Colors.black,
                          width: double.infinity,
                          height: double.infinity,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (frame != null)
                                Transform.translate(
                                  offset: _panOffset,
                                  child: Transform.scale(
                                    scale: _zoomScale,
                                    child: Image.memory(
                                      Uint8List.fromList(frame.encodedBytes),
                                      fit: BoxFit.contain,
                                      gaplessPlayback: true,
                                    ),
                                  ),
                                )
                              else
                                const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              if (_snapshot.cursor != null && _snapshot.cursor!.visible)
                                Positioned(
                                  left: _snapshot.cursor!.x.toDouble(),
                                  top: _snapshot.cursor!.y.toDouble(),
                                  child: const Icon(
                                    Icons.navigation,
                                    size: 18,
                                    color: Colors.redAccent,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
