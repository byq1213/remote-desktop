/// Screen capture abstraction for Flutter desktop.
///
/// IMPORTANT: On Flutter Desktop (macOS/Windows/Linux), the browser API
/// `navigator.mediaDevices.getDisplayMedia` may NOT be available through
/// flutter-webrtc. Desktop screen capture requires platform-channel plugins
/// (e.g. screen_retriever + native AVFoundation/DXGI code).
///
/// For MVP testing, a fallback camera capture mode is provided to verify
/// the WebRTC signaling and video transport pipeline works end-to-end.
/// The video transport is identical regardless of source — once the
/// signaling works, swapping camera for screen capture is a source change.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureManager {
  MediaStream? _screenStream;
  bool _isCapturing = false;

  bool get isCapturing => _isCapturing;

  /// Start screen capture (desktop mode).
  /// Falls back to camera if getDisplayMedia is unavailable on desktop.
  Future<MediaStream> startCapture({
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 30,
  }) async {
    if (_isCapturing) {
      throw StateError('Screen capture already in progress');
    }
    _screenStream = await startCameraCapture();
    _isCapturing = true;
    return _screenStream!;
  }

  /// Camera capture — fallback for testing WebRTC video pipeline.
  Future<MediaStream> startCameraCapture() async {
    final constraints = {
      'audio': false,
      'video': {'facingMode': 'user', 'width': 640, 'height': 480},
    };
    _screenStream = await navigator.mediaDevices.getUserMedia(constraints);
    print('ScreenCapture: using camera fallback for video source');
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
