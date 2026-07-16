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
///
/// IMPORTANT (extended / multiple displays):
/// The macOS native implementation captures the *entire virtual desktop*
/// (every display stitched together) when no `sourceId` is supplied. With an
/// external display attached that yields a huge, odd frame (e.g. 3840x4072),
/// which fails to render on the viewer (blue/blank). We therefore enumerate
/// the available screens and capture a SINGLE display by default, and let the
/// caller pass an explicit `sourceId` when the user wants a specific screen.

library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureManager {
  MediaStream? _screenStream;
  bool _isCapturing = false;

  bool get isCapturing => _isCapturing;

  /// List the screens available for sharing. Use this to build a picker UI so
  /// the user can choose which display to share (essential with an extended
  /// display attached). Returns `DesktopCapturerSource` with `id` (pass to
  /// [startCapture]) and `name` (e.g. "Screen 1").
  Future<List<DesktopCapturerSource>> listScreens() async {
    return desktopCapturer.getSources(types: [SourceType.Screen]);
  }

  /// Start screen capture (desktop mode).
  ///
  /// Uses `getDisplayMedia`. If [sourceId] is omitted we enumerate the screens
  /// and capture the first one (usually the primary display) so we never fall
  /// back to the merged virtual-desktop capture that breaks the viewer.
  Future<MediaStream> startCapture({
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 30,
    String? sourceId,
  }) async {
    if (_isCapturing) {
      throw StateError('Screen capture already in progress');
    }
    _screenStream = await _startDisplayCapture(
      fps: fps,
      sourceId: sourceId,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
    _isCapturing = true;
    return _screenStream!;
  }

  /// Capture a single display/screen via `getDisplayMedia`.
  ///
  /// Passing a [sourceId] selects exactly one display (the macOS native layer
  /// reads `video.deviceId.exact`). With no [sourceId] we auto-pick the first
  /// enumerated screen to avoid the merged-virtual-desktop capture.
  Future<MediaStream> _startDisplayCapture({
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 30,
    String? sourceId,
  }) async {
    String? resolvedSourceId = sourceId;
    if (resolvedSourceId == null) {
      try {
        final sources =
            await desktopCapturer.getSources(types: [SourceType.Screen]);
        if (sources.isNotEmpty) {
          resolvedSourceId = sources.first.id;
          print('ScreenCapture: auto-selected screen "${sources.first.name}" '
              '(id=$resolvedSourceId); ${sources.length} screen(s): '
              '${sources.map((s) => s.name).join(', ')}');
        }
      } catch (e) {
        print('ScreenCapture: enumerate screens failed, using default: $e');
      }
    }

    // NOTE: on macOS desktop capture the native layer ignores width/height
    // `max` constraints and captures the source at native resolution; the
    // encode-side downscale (see PeerManager._capOutgoingResolution) bounds
    // the resolution the viewer receives.
    final constraints = <String, dynamic>{
      'audio': false,
      'video': resolvedSourceId != null
          ? {
              'deviceId': {'exact': resolvedSourceId},
              'mandatory': {'frameRate': fps},
            }
          : {
              'frameRate': fps,
            },
    };

    try {
      _screenStream =
          await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (e) {
      print('ScreenCapture: getDisplayMedia failed: $e');
      rethrow;
    }
    final suffix = resolvedSourceId != null
        ? ' (source=$resolvedSourceId)'
        : ' (default screen)';
    print('ScreenCapture: screen capture started$suffix');
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
