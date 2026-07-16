/// Mouse and keyboard event handler for remote control.
/// Captures input events on the viewer side and sends them to the server.
library;

import 'dart:async';

/// Base class for input events.
abstract class InputEvent {
  final DateTime timestamp;
  InputEvent(this.timestamp);
}

class RemoteMouseEvent extends InputEvent {
  final String action; // 'move' | 'down' | 'up' | 'wheel'
  final double x;
  final double y;
  final int button;
  final double delta; // for scroll wheel

  RemoteMouseEvent({
    required this.action,
    required this.x,
    required this.y,
    this.button = 0,
    this.delta = 0,
    DateTime? timestamp,
  }) : super(timestamp ?? DateTime.now());
}

class RemoteKeyEvent extends InputEvent {
  final String key;
  final String code;
  final String action; // 'down' | 'up' | 'repeat'

  RemoteKeyEvent({
    required this.key,
    required this.code,
    required this.action,
    DateTime? timestamp,
  }) : super(timestamp ?? DateTime.now());
}

/// Manages input event collection and throttling for the viewer client.
class InputEventHandler {
  final Function(InputEvent) _onEvent;
  Timer? _mouseMoveTimer;
  double _pendingX = 0;
  double _pendingY = 0;
  bool _hasPending = false;
  static const Duration _mouseThrottleDuration = Duration(milliseconds: 16); // ~60Hz

  InputEventHandler(this._onEvent);

  /// Report a mouse movement. Coordinates are emitted (coalesced) at a fixed
  /// rate so a fast stream of pointer events does not flood the signaling
  /// channel. Latest position within the throttle window wins.
  void onMouseMove(double x, double y) {
    _pendingX = x;
    _pendingY = y;
    _hasPending = true;
    if (_mouseMoveTimer?.isActive != true) {
      _mouseMoveTimer = Timer(_mouseThrottleDuration, () {
        _mouseMoveTimer = null;
        if (_hasPending) {
          _hasPending = false;
          _emitMove(_pendingX, _pendingY);
        }
      });
    }
  }

  void _emitMove(double x, double y) {
    _onEvent(RemoteMouseEvent(
      action: 'move',
      x: x,
      y: y,
      timestamp: DateTime.now(),
    ));
  }

  /// Handle mouse button press (click, drag start).
  void onMouseDown(int button, double x, double y) {
    _flushPendingMove();
    _onEvent(RemoteMouseEvent(
      action: 'down',
      x: x,
      y: y,
      button: button,
      timestamp: DateTime.now(),
    ));
  }

  void onMouseUp(int button, double x, double y) {
    _flushPendingMove();
    _onEvent(RemoteMouseEvent(
      action: 'up',
      x: x,
      y: y,
      button: button,
      timestamp: DateTime.now(),
    ));
  }

  void onWheel(double delta) {
    _onEvent(RemoteMouseEvent(
      action: 'wheel',
      x: 0,
      y: 0,
      delta: delta,
      timestamp: DateTime.now(),
    ));
  }

  /// Handle keyboard events.
  void onKeyDown(String key, String code) {
    _onEvent(RemoteKeyEvent(
      key: key,
      code: code,
      action: 'down',
      timestamp: DateTime.now(),
    ));
  }

  void onKeyUp(String key, String code) {
    _onEvent(RemoteKeyEvent(
      key: key,
      code: code,
      action: 'up',
      timestamp: DateTime.now(),
    ));
  }

  void _flushPendingMove() {
    if (_hasPending) {
      _hasPending = false;
      _mouseMoveTimer?.cancel();
      _mouseMoveTimer = null;
      _emitMove(_pendingX, _pendingY);
    }
  }

  /// Clean up resources.
  void dispose() {
    _mouseMoveTimer?.cancel();
    _mouseMoveTimer = null;
  }
}
