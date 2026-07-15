/// Screen capture abstraction for Flutter desktop.
///
/// On Flutter Desktop (macOS/Windows/Linux), screen sharing uses
/// `navigator.mediaDevices.getDisplayMedia`, which presents the OS-native
/// screen/window picker and requests the *screen-recording* permission —
/// NOT the camera. This keeps the "share screen" flow semantically correct
/// and avoids prompting for camera access.
///
/// NOTE: On macOS, `getDisplayMedia` for desktop requires the
/// `com.apple.security.screen-recording` entitlement to be signed (a paid
/// Apple Developer account is needed for that restricted entitlement). If the
/// capability is unavailable, the call throws and the caller surfaces a clear
/// error instead of silently falling back to the camera.

library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureManager {
  MediaStream? _screenStream;
  bool _isCapturing = false;

  bool get isCapturing => _isCapturing;

  /// Start screen capture (desktop mode).
  ///
  /// Uses `getDisplayMedia` so the OS picker appears and only the
  /// screen-recording permission is requested.
  Future<MediaStream> startCapture({
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 30,
  }) async {
    if (_isCapturing) {
      throw StateError('Screen capture already in progress');
    }
    _screenStream = await _startDisplayCapture(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      fps: fps,
    );
    _isCapturing = true;
    return _screenStream!;
  }

  /// Capture the display/screen via `getDisplayMedia`.
  ///
  /// This triggers the platform screen picker and the screen-recording
  /// permission prompt — never the camera.
  Future<MediaStream> _startDisplayCapture({
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 30,
  }) async {
    // Cap the *longer* side only, so the source's aspect ratio is preserved
    // for both landscape and portrait (e.g. vertical external) displays.
    // Capping width AND height independently would squash a portrait source
    // into a 16:9 box and distort it.
    final cap = maxWidth > maxHeight ? maxWidth : maxHeight;
    final constraints = {
      'audio': false,
      'video': {
        'frameRate': fps,
        'width': {'max': cap},
        'height': {'max': cap},
      },
    };
    try {
      _screenStream = await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (e) {
      print('ScreenCapture: getDisplayMedia failed: $e');
      rethrow;
    }
    print('ScreenCapture: screen capture started via getDisplayMedia');
    return _screenStream!;
  }

  /// Stop capture.
  Future<void> stopCapture() async {
    if (_screenStream != null) {
      for (final track in _screenStream!.getTracks()) {
        track.stop();
      }
      _screenStream!.dispose();
      _screenStream = null;
    }
    _isCapturing = false;
  }
}
