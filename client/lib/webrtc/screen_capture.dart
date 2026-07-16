/// Screen capture abstraction for Flutter desktop.
///
/// On macOS the native ScreenCaptureKit bridge (`ScreenCaptureKitManager.swift`)
/// is preferred: it produces a stride-safe frame (width a multiple of 64,
/// height even) so the renderer never shows a sheared image. `getDisplayMedia`
/// is kept only as a fallback for older macOS. Capture resolution/stride math
/// is delegated to `utils/resolution.dart`.
library;

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
// The native ScreenCaptureKit bridge returns a raw map; only the package's
// concrete implementation can reconstruct a MediaStream from it.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_impl.dart' show MediaStreamNative;
import 'package:screen_retriever/screen_retriever.dart';

import '../core/logger.dart';
import '../utils/resolution.dart';

const MethodChannel _sckChannel =
    MethodChannel('dev.remotedesktop/screen_capture_kit');

class ScreenCaptureManager {
  MediaStream? _screenStream;
  bool _isCapturing = false;
  String? _lastNativeStreamId;

  /// Real captured frame size, read from track settings / the native bridge.
  (int, int)? _realCapturedSize;
  (int, int)? get capturedSize => _realCapturedSize;

  bool get isCapturing => _isCapturing;

  /// List the screens available for sharing (build a picker UI from these).
  Future<List<DesktopCapturerSource>> listScreens() async {
    return desktopCapturer.getSources(types: [SourceType.Screen]);
  }

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
          log.d('ScreenCapture: auto-selected screen "${sources.first.name}" '
              '(${sources.length} screen(s))');
        }
      } catch (e) {
        log.warning('ScreenCapture: enumerate screens failed: $e');
      }
    }

    // Derive a stride-safe capture size from the chosen display's physical
    // resolution and DPR.
    Display? display;
    if (resolvedSourceId != null) {
      display = await _matchDisplay(resolvedSourceId);
    }
    final size = display != null
        ? resolveCaptureSize(
            (display.size.width * (display.scaleFactor ?? 1.0)).round(),
            (display.size.height * (display.scaleFactor ?? 1.0)).round(),
            max(maxWidth, maxHeight).toDouble(),
          )
        : null;
    final haveSize = size != null;
    final capW = size?.$1 ?? 1920;
    final capH = size?.$2 ?? 1080;

    final video = <String, dynamic>{
      'frameRate': fps,
      if (resolvedSourceId != null) 'deviceId': {'exact': resolvedSourceId},
    };
    if (haveSize) {
      // An *exact* size is honored by macOS capture and yields a tightly
      // packed buffer (no 256-byte row-stride padding), which is what fixes
      // the shear. A bare `width` is treated as `ideal` and ignored.
      video['width'] = {'exact': capW};
      video['height'] = {'exact': capH};
    }

    // Plan A: native ScreenCaptureKit (stride-safe).
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
        log.d('ScreenCapture: native ScreenCaptureKit started '
            'stream=$streamId size=$_realCapturedSize '
            '(width ${rw % 64 == 0 ? "IS" : "is NOT"} 64-aligned)');
        _screenStream = _buildNativeStream(streamId, trackId);
        return _screenStream!;
      }
    } on PlatformException catch (e) {
      log.d('ScreenCapture: native ScreenCaptureKit unavailable ($e), '
          'falling back to getDisplayMedia');
    }

    // Plan B: getDisplayMedia fallback.
    final constraints = <String, dynamic>{
      'audio': false,
      'video': video,
    };
    try {
      _screenStream = await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (e) {
      log.warning('ScreenCapture: getDisplayMedia with exact size failed: $e');
      if (haveSize) {
        video.remove('width');
        video.remove('height');
        try {
          _screenStream =
              await navigator.mediaDevices.getDisplayMedia(constraints);
        } catch (e2) {
          log.warning('ScreenCapture: getDisplayMedia fallback failed: $e2');
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    try {
      final vt = _screenStream!.getVideoTracks().first;
      final s = vt.getSettings();
      final w = s['width'] as int?;
      final h = s['height'] as int?;
      if (w != null && h != null) {
        _realCapturedSize = (w, h);
        log.d('ScreenCapture: REAL captured size = ${w}x$h '
            '(width ${w % 64 == 0 ? "IS" : "is NOT"} 64-aligned)');
      }
    } catch (e) {
      log.warning('ScreenCapture: could not read track settings: $e');
    }
    return _screenStream!;
  }

  /// Map a flutter_webrtc screen [sourceId] to a [ScreenRetriever] display so we
  /// can read its physical size + DPI. Returns null on a miss.
  Future<Display?> _matchDisplay(String sourceId) async {
    try {
      final displays = await ScreenRetriever.instance.getAllDisplays();
      for (final d in displays) {
        if (d.id == sourceId) return d;
      }
      return null;
    } catch (e) {
      log.warning('ScreenCapture: display lookup failed ($e)');
      return null;
    }
  }

  Future<void> stopCapture() async {
    if (_screenStream != null) {
      for (final track in _screenStream!.getTracks()) {
        track.stop();
      }
      _screenStream!.dispose();
      _screenStream = null;
    }
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
