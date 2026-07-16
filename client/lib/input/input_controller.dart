/// Remote-control input replay for the controller side.
///
/// The viewer captures input directly through the UI (`Listener`/`Focus`) and
/// forwards it via [ConnectionManager.sendInputMouse]/[sendInputKey]; this
/// class only replays *incoming* events onto the local machine through the
/// native macOS input simulator ([MethodChannel]). Coordinate scaling uses
/// [localScreenSize] because the payload carries normalized [0..1] values.
library;

import 'package:flutter/services.dart';

import '../core/logger.dart';

class InputController {
  final MethodChannel _inputChannel =
      const MethodChannel('remote_desktop/input');

  final bool isController;
  Size localScreenSize;

  InputController({
    required this.isController,
    required this.localScreenSize,
  });

  /// Controller side: replay an incoming mouse event on the local machine.
  ///
  /// [nx]/[ny] are normalized [0..1]; they are mapped onto [localScreenSize].
  void applyRemoteMouse(
      String action, double nx, double ny, int button, double delta) {
    if (!isController) return;
    final px = nx * localScreenSize.width;
    final py = ny * localScreenSize.height;
    log.d('Input: apply MOUSE $action @ ($px, $py) button=$button');
    _inputChannel
        .invokeMethod('mouse', {
          'action': action,
          'x': px,
          'y': py,
          'button': button,
          'delta': delta,
        })
        .catchError((e) => log.w('Input: dispatch mouse failed: $e'));
  }

  /// Controller side: replay an incoming keyboard event on the local machine.
  ///
  /// [keyCode] is a USB HID usage id (see `MainFlutterWindow.macVK`).
  void applyRemoteKey(String action, int keyCode) {
    if (!isController) return;
    log.d('Input: apply KEY $action keyCode=$keyCode');
    _inputChannel
        .invokeMethod('key', {'action': action, 'keyCode': keyCode})
        .catchError((e) => log.w('Input: dispatch key failed: $e'));
  }

  void dispose() {}
}
