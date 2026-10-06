import 'dart:async';
import 'dart:collection';

import 'package:remotex/core/services/secure_session_channel.dart';

class SessionPacketMultiplexer {
  SessionPacketMultiplexer(this._secureChannel) {
    unawaited(_pump());
  }

  static const frameMagic = [0x52, 0x58, 0x46, 0x31];
  static const maximumQueuedControlPackets = 64;
  static const maximumPendingControlSends = 64;

  final SecureSessionChannel _secureChannel;
  final Queue<List<int>> _controlPackets = Queue<List<int>>();
  final Queue<List<int>> _framePackets = Queue<List<int>>();
  final List<Completer<List<int>>> _controlWaiters = [];
  final List<Completer<List<int>>> _frameWaiters = [];
  final Queue<_PendingControl> _pendingControls = Queue<_PendingControl>();
  _PendingFrame? _pendingFrame;
  bool _sending = false;
  bool _closed = false;
  Object? _failure;

  Future<void> sendControl(List<int> packet) {
    if (_closed) {
      return Future.error(StateError('Session packet transport is closed.'));
    }
    if (_pendingControls.length >= maximumPendingControlSends) {
      return Future.error(StateError('Session control send queue is full.'));
    }
    final pending = _PendingControl([...packet]);
    _pendingControls.add(pending);
    unawaited(_drainSends());
    return pending.completer.future;
  }

  Future<bool> sendFrame(List<int> packet) {
    if (_closed) {
      return Future.error(StateError('Session packet transport is closed.'));
    }
    final previous = _pendingFrame;
    if (previous != null && !previous.completer.isCompleted) {
      previous.completer.complete(false);
    }
    final pending = _PendingFrame([...frameMagic, ...packet]);
    _pendingFrame = pending;
    unawaited(_drainSends());
    return pending.completer.future;
  }

  Future<List<int>> receiveControl() => _receive(frame: false);

  Future<List<int>> receiveFrame() => _receive(frame: true);

  Future<void> _drainSends() async {
    if (_sending) return;
    _sending = true;
    try {
      while (!_closed &&
          (_pendingControls.isNotEmpty || _pendingFrame != null)) {
        final control = _pendingControls.isNotEmpty
            ? _pendingControls.removeFirst()
            : null;
        final frame = control == null ? _pendingFrame : null;
        if (frame != null) _pendingFrame = null;
        try {
          await _secureChannel.send(control?.packet ?? frame!.packet);
          if (control != null) {
            control.completer.complete();
          } else {
            frame!.completer.complete(true);
          }
        } on Object catch (error, stackTrace) {
          if (control != null) {
            control.completer.completeError(error, stackTrace);
          } else {
            frame!.completer.completeError(error, stackTrace);
          }
        }
      }
    } finally {
      _sending = false;
      if (!_closed && (_pendingControls.isNotEmpty || _pendingFrame != null)) {
        unawaited(_drainSends());
      }
    }
  }

  Future<List<int>> _receive({required bool frame}) {
    final packets = frame ? _framePackets : _controlPackets;
    if (packets.isNotEmpty) {
      return Future.value(packets.removeFirst());
    }
    final failure = _failure;
    if (failure != null) {
      return Future.error(failure);
    }
    if (_closed) {
      return Future.error(StateError('Session packet transport is closed.'));
    }
    final completer = Completer<List<int>>();
    (frame ? _frameWaiters : _controlWaiters).add(completer);
    return completer.future;
  }

  Future<void> _pump() async {
    try {
      while (!_closed) {
        final packet = await _secureChannel.receive();
        if (_hasFramePrefix(packet)) {
          _deliver(
            _frameWaiters,
            _framePackets,
            packet.sublist(frameMagic.length),
          );
        } else {
          _deliver(_controlWaiters, _controlPackets, packet);
        }
      }
    } on Object catch (error, stackTrace) {
      _failure = error;
      for (final waiter in [..._controlWaiters, ..._frameWaiters]) {
        if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
      }
      _controlWaiters.clear();
      _frameWaiters.clear();
    }
  }

  bool _hasFramePrefix(List<int> packet) {
    if (packet.length < frameMagic.length) return false;
    for (var index = 0; index < frameMagic.length; index++) {
      if (packet[index] != frameMagic[index]) return false;
    }
    return true;
  }

  void _deliver(
    List<Completer<List<int>>> waiters,
    Queue<List<int>> packets,
    List<int> packet,
  ) {
    if (waiters.isNotEmpty) {
      waiters.removeAt(0).complete(packet);
    } else {
      if (identical(packets, _framePackets)) {
        packets.clear();
      } else if (packets.length >= maximumQueuedControlPackets) {
        throw StateError('Session control queue limit exceeded.');
      }
      packets.add(packet);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final closedError = StateError('Session packet transport is closed.');
    for (final pending in _pendingControls) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(closedError);
      }
    }
    _pendingControls.clear();
    final pendingFrame = _pendingFrame;
    _pendingFrame = null;
    if (pendingFrame != null && !pendingFrame.completer.isCompleted) {
      pendingFrame.completer.complete(false);
    }
    for (final waiter in [..._controlWaiters, ..._frameWaiters]) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Session packet transport is closed.'));
      }
    }
    _controlWaiters.clear();
    _frameWaiters.clear();
  }
}

class _PendingControl {
  _PendingControl(this.packet);

  final List<int> packet;
  final Completer<void> completer = Completer<void>();
}

class _PendingFrame {
  _PendingFrame(this.packet);

  final List<int> packet;
  final Completer<bool> completer = Completer<bool>();
}
