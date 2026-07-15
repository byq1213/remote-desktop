/// Mouse and keyboard event handler for remote control.
/// Captures input events on the viewer side and sends them to the server.
library;

import 'dart:async';

/// Base class for input events.
abstract class InputEvent {
  final DateTime timestamp;
  InputEvent(this.timestamp);
}

class MouseEvent extends InputEvent {
  final String action; // 'move' | 'down' | 'up' | 'wheel'
  final double x;
  final double y;
  final int button;
  final double delta; // for scroll wheel

  MouseEvent({
    required this.action,
    required this.x,
    required this.y,
    this.button = 0,
    this.delta = 0,
    DateTime? timestamp,
  }) : super(timestamp ?? DateTime.now());
}

class KeyEvent extends InputEvent {
  final String key;
  final String code;
  final String action; // 'down' | 'up' | 'repeat'

  KeyEvent({
    required this.key,
    required this.code,
    required this.action,
    DateTime? timestamp,
  }) : super(timestamp ?? DateTime.now());
}

/// Manages input event collection and debouncing for the viewer client.
class InputEventHandler {
  final Function(InputEvent) _onEvent;
  Timer? _mouseMoveTimer;
  static const Duration _mouseDebounceDuration = Duration(milliseconds: 16); // ~60Hz

  InputEventHandler(this._onEvent);

  /// Subscribe to mouse movements with debouncing.
  void subscribeMouseMove(void Function(double x, double y) callback) {
    _mouseMoveTimer?.cancel();
    _mouseMoveTimer = Timer(_mouseDebounceDuration, () {
      // Debounce complete, emit event
      _onEvent(MouseEvent(
        action: 'move',
        x: callback.call(0, 0) as double, // Placeholder - will be overwritten in actual implementation
        y: 0,
        timestamp: DateTime.now(),
      ));
    });
  }

  /// Handle mouse button events (click, drag).
  void onMouseDown(int button, double x, double y) {
    _onEvent(MouseEvent(
      action: 'down',
      x: x,
      y: y,
      button: button,
      timestamp: DateTime.now(),
    ));
  }

  void onMouseUp(int button, double x, double y) {
    _onEvent(MouseEvent(
      action: 'up',
      x: x,
      y: y,
      button: button,
      timestamp: DateTime.now(),
    ));
  }

  void onWheel(double delta) {
    _onEvent(MouseEvent(
      action: 'wheel',
      x: 0,
      y: 0,
      delta: delta,
      timestamp: DateTime.now(),
    ));
  }

  /// Handle keyboard events.
  void onKeyDown(String key, String code) {
    _onEvent(KeyEvent(
      key: key,
      code: code,
      action: 'down',
      timestamp: DateTime.now(),
    ));
  }

  void onKeyUp(String key, String code) {
    _onEvent(KeyEvent(
      key: key,
      code: code,
      action: 'up',
      timestamp: DateTime.now(),
    ));
  }

  /// Clean up resources.
  void dispose() {
    _mouseMoveTimer?.cancel();
  }
}
