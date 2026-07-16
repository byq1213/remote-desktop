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

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/native/media_stream_impl.dart'
    show MediaStreamNative;
import 'package:screen_retriever/screen_retriever.dart';

/// Channel to the native macOS ScreenCaptureKit bridge
/// (`macos/Runner/ScreenCaptureKitManager.swift`). It produces a
/// stride-safe capture sized to a 64-aligned width + even height and feeds
/// frames through `RTCCVPixelBuffer` (reads the real `bytesPerRow`), which
/// is what actually fixes the macOS "歪扭" shear. `getDisplayMedia` is kept
/// only as a fallback for macOS < 12.3.
const MethodChannel _sckChannel =
    MethodChannel('dev.remotedesktop/screen_capture_kit');

class ScreenCaptureManager {
  MediaStream? _screenStream;
  bool _isCapturing = false;
  /// streamId of the last native ScreenCaptureKit capture, so [stopCapture]
  /// can tear it down. Null when using the getDisplayMedia fallback.
  String? _lastNativeStreamId;

  /// Real captured frame size, read from the track settings right after
  /// `getDisplayMedia` returns. On macOS the capturer routinely IGNORES the
  /// requested `width`/`height`, so this — not the requested size — is the
  /// source of truth for the actual (possibly non-64-aligned) frame the
  /// encoder and the local preview have to deal with.
  (int, int)? _realCapturedSize;
  (int, int)? get capturedSize => _realCapturedSize;

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
  ///
  /// ## HiDPI / Retina stride fix
  /// A macOS screen capture returns frames whose `bytesPerRow` (row stride) is
  /// aligned to a 256-byte boundary. When `width × 4` is NOT a multiple of 256
  /// (e.g. a Retina built-in at 3024 → 12096, /256 = 47.25), the capture's
  /// tight row copy and the renderer disagree on stride and the image comes out
  /// sheared / "歪歪扭扭" — and it shows up in the *local preview too*, because
  /// the preview renders the raw captured frame, not the (post-encode) stream.
  /// A standard DPR-1 external 1080p screen (1920×4 = 7680, exactly ÷256) has
  /// no padding, hence it looks fine. The fix: request an **exact** capture
  /// size whose width is a multiple of 64 (so `width × 4` is a multiple of 256)
  /// and whose height is even. Unlike the `max` constraint (which the macOS
  /// native layer ignores), an *exact* `width`/`height` is honored and the
  /// captured buffer stays tightly packed → no shear, on both preview and the
  /// transmitted stream. The size is derived per-display from its physical
  /// resolution ÷ DPR, so Retina and external screens are handled dynamically.
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

    // Resolve the chosen display's physical size + DPR so we can compute a
    // 64-aligned capture size (dynamic per-screen compatibility).
    Display? display;
    if (resolvedSourceId != null) {
      display = await _matchDisplay(resolvedSourceId);
    }
    final size = display != null
        ? _resolveCaptureSize(display, max(maxWidth, maxHeight).toDouble())
        : null;
    // ## Stride-safe capture (the ACTUAL fix for the shear)
    // A bare `width` is treated as `ideal` by macOS screen capture and ignored,
    // so it falls back to the display's native resolution. A native frame whose
    // width is not a multiple of 64 makes `width × 4` != the 256-byte row
    // stride, shearing the frame (TECHNICAL_NOTES #13.4). Critically, that
    // shear lives in the RAW CVPixelBuffer: re-encoding it (e.g. via the local
    // preview loopback) just reproduces a *smaller but still sheared* frame, so
    // the loopback can never fix it. The only real fix is to capture a frame
    // whose buffer is tightly packed — i.e. request an EXACT size whose width is
    // a multiple of 64 and height even. macOS then SCALES the capture to that
    // tightly-packed frame (bytesPerRow == width×4, no 256-byte padding) and the
    // shear disappears at the source. If `exact` is unsupported and
    // getDisplayMedia rejects, we retry without the size constraint (falling
    // back to the native, sheared frame) so capture never hard-fails.
    final haveSize = size != null;
    final capW = size?.$1 ?? 1920;
    final capH = size?.$2 ?? 1080;

    final video = <String, dynamic>{
      'frameRate': fps,
      if (resolvedSourceId != null) 'deviceId': {'exact': resolvedSourceId},
    };
    if (haveSize) {
      video['width'] = {'exact': capW};
      video['height'] = {'exact': capH};
    }

    // --- Plan C: native ScreenCaptureKit (stride-safe) -----------------------
    // Ask the OS to scale the display to an EXACT 64-aligned size and feed
    // frames through RTCCVPixelBuffer (reads the real bytesPerRow). This kills
    // the macOS stride shear at the source. The getDisplayMedia path below
    // is only a fallback for macOS < 12.3.
    try {
      final resp = await _sckChannel.invokeMethod<Map<dynamic, dynamic>>(
        'start',
        <String, dynamic>{
          'width': capW,
          'height': capH,
          'fps': fps,
          if (resolvedSourceId != null) 'sourceId': resolvedSourceId,
        },
      );
      if (resp != null) {
        final streamId = resp['streamId'] as String;
        final trackId = resp['trackId'] as String;
        final rw = resp['width'] as int;
        final rh = resp['height'] as int;
        _realCapturedSize = (rw, rh);
        print('ScreenCapture: native ScreenCaptureKit started '
            'stream=$streamId track=$trackId size=${_realCapturedSize} '
            '(width ${rw % 64 == 0 ? "IS" : "is NOT"} 64-aligned)');
        _screenStream = _buildNativeStream(streamId, trackId);
        return _screenStream!;
      }
    } on PlatformException catch (e) {
      print('ScreenCapture: native ScreenCaptureKit unavailable ($e), '
          'falling back to getDisplayMedia');
    }

    final constraints = <String, dynamic>{
      'audio': false,
      'video': video,
    };

    try {
      _screenStream = await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (e) {
      print('ScreenCapture: getDisplayMedia with exact size '
          '${capW}x$capH failed: $e');
      if (haveSize) {
        // `exact` likely unsupported on this capturer — retry without the size
        // constraint (native, possibly sheared, frame) instead of failing.
        print('ScreenCapture: retrying without exact size constraint');
        video.remove('width');
        video.remove('height');
        try {
          _screenStream =
              await navigator.mediaDevices.getDisplayMedia(constraints);
        } catch (e2) {
          print('ScreenCapture: getDisplayMedia fallback failed: $e2');
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    // Read the ACTUAL captured dimensions. The capturer may have ignored the
    // requested size, so this is what we must feed the encoder and the preview.
    try {
      final vt = _screenStream!.getVideoTracks().first;
      final s = vt.getSettings();
      final w = s['width'] as int?;
      final h = s['height'] as int?;
      if (w != null && h != null) {
        _realCapturedSize = (w, h);
        final aligned = (w % 64 == 0);
        print('ScreenCapture: REAL captured size = ${w}x$h '
            '(width ${aligned ? "IS" : "is NOT"} 64-aligned'
            '${aligned ? "" : " -> local preview may shear"}))');
      }
    } catch (e) {
      print('ScreenCapture: could not read track settings ($e)');
    }
    final suffix = resolvedSourceId != null
        ? ' (source=$resolvedSourceId)'
        : ' (default screen)';
    final sizeNote = size != null ? ' captureSize=${size.$1}x${size.$2}' : '';
    print('ScreenCapture: screen capture started$suffix$sizeNote');
    return _screenStream!;
  }

  /// Map a flutter_webrtc screen [sourceId] to a [ScreenRetriever] display so we
  /// can read its physical size + DPI. Ids may use different formats between the
  /// two packages, so on a miss we return null and the caller falls back to a
  /// width-only (aspect-preserving) capture constraint.
  Future<Display?> _matchDisplay(String sourceId) async {
    try {
      final displays = await ScreenRetriever.instance.getAllDisplays();
      for (final d in displays) {
        if (d.id == sourceId) return d;
      }
      return null;
    } catch (e) {
      print('ScreenCapture: display lookup failed ($e)');
      return null;
    }
  }

  /// Compute a stride-safe, DPI-aware capture size for [display].
  ///
  /// Returns `(width, height)` where `width` (the long side when landscape) is
  /// snapped DOWN to a multiple of 64 so `width × 4` is a multiple of 256 (no
  /// row-stride padding → no shear), and the other side is even. The long side
  /// is capped at [maxLongSide] so we never upscale a small display.
  (int, int)? _resolveCaptureSize(Display display, double maxLongSide) {
    final dpr = (display.scaleFactor ?? 1.0).toDouble();
    final physW = (display.size.width.toDouble() * dpr).round();
    final physH = (display.size.height.toDouble() * dpr).round();
    if (physW <= 0 || physH <= 0) return null;
    final landscape = physW >= physH;
    final long = (landscape ? physW : physH).toDouble();
    final short = (landscape ? physH : physW).toDouble();
    const block = 64;
    // The LONG side must be 64-aligned so `width × 4` is a multiple of 256
    // (row-stride safe → no shear). The SHORT side only needs to be EVEN for
    // chroma sampling, so we snap it to the nearest even number rather than to
    // 64 — otherwise ordinary heights (1080 etc.) get crushed. The long side is
    // capped at [maxLongSide] so we never upscale a small display.
    var targetLong = ((min(maxLongSide, long) ~/ block) * block).toInt();
    if (targetLong < block) targetLong = block;
    var targetShort = (short * targetLong / long).round();
    if (targetShort.isOdd) targetShort += 1;
    if (targetShort < 2) targetShort = 2;
    return landscape ? (targetLong, targetShort) : (targetShort, targetLong);
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
    // Tell the native ScreenCaptureKit bridge to tear down the SCStream.
    if (_lastNativeStreamId != null) {
      try {
        await _sckChannel.invokeMethod<void>('stop', <String, dynamic>{
          'streamId': _lastNativeStreamId,
        });
      } on PlatformException catch (_) {
        // Native capture may already be stopped; ignore.
      }
    }
    _lastNativeStreamId = null;
    _isCapturing = false;
  }

  /// Builds a [MediaStream] that references a video track created natively by
  /// the macOS ScreenCaptureKit bridge. The native side registers the
  /// streamId/trackId with flutter_webrtc's peerConnectionFactory registries,
  /// so the returned object behaves exactly like one from `getDisplayMedia`
  /// (addTrack / RTCVideoRenderer resolve it by id).
  MediaStream _buildNativeStream(String streamId, String trackId) {
    _lastNativeStreamId = streamId;
    final map = <String, dynamic>{
      'streamId': streamId,
      'ownerTag': 'local',
      'audioTracks': <Map<String, dynamic>>[],
      'videoTracks': <Map<String, dynamic>>[
        {
          'id': trackId,
          'label': trackId,
          'kind': 'video',
          'enabled': true,
          'settings': <String, dynamic>{},
        }
      ],
    };
    return MediaStreamNative.fromMap(map);
  }
}
