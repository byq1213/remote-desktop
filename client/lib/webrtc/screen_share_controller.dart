/// Controller-side screen-capture orchestration.
///
/// Owns the capture lifecycle: derives a stride-safe capture size, adds the
/// tracks to the PeerConnection, applies the 64-aligned encoder scale, and
/// runs the stride-safe local-preview loopback. All resolution/stride math is
/// delegated to `utils/resolution.dart`.
library;

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:screen_retriever/screen_retriever.dart';

import '../core/logger.dart';
import 'peer_manager.dart';
import 'screen_capture.dart';

class ScreenShareController {
  final PeerManager peerManager;
  final ScreenCaptureManager _capture = ScreenCaptureManager();

  MediaStream? _screenStream;
  bool _captureStarted = false;
  bool _loopbackStarted = false;
  bool _realSizeApplied = false;
  int _realAppliedW = 0;
  int _realAppliedH = 0;

  /// Local display size (logical px) + DPR, used to estimate DPR and to derive
  /// a fallback capture size when the native size is unreadable.
  Size localScreenSize = const Size(1920, 1080);
  double localScreenScaleFactor = 1.0;

  Function(MediaStream)? onLocalStreamUpdated;
  Function(MediaStream)? onLocalPreviewReady;
  Function(String)? onCaptureError;
  /// Fired once the capture is added to the PeerConnection, so the orchestrator
  /// can (re)create an offer to a known viewer.
  Function()? onCaptureReady;

  static const int targetLongSide = PeerManager.kDefaultTargetLongSide;

  ScreenShareController(this.peerManager);

  /// The live capture stream (null until started).
  MediaStream? get stream => _screenStream;

  /// Real captured frame size, read from track settings / the native bridge.
  (int, int)? get capturedSize => _capture.capturedSize;

  /// Read the controller's primary display size (logical px + DPR).
  Future<void> fetchLocalScreenSize() async {
    try {
      final display = await ScreenRetriever.instance.getPrimaryDisplay();
      localScreenSize = Size(display.size.width, display.size.height);
      localScreenScaleFactor = display.scaleFactor?.toDouble() ?? 1.0;
      log.d('ScreenShare: local screen size = '
          '${localScreenSize.width}x${localScreenSize.height} '
          '@${localScreenScaleFactor}x');
    } catch (e) {
      log.warning('ScreenShare: failed to read screen size ($e), '
          'falling back to $localScreenSize');
    }
  }

  Future<void> start({String? sourceId}) async {
    if (_captureStarted) return;
    _captureStarted = true;
    try {
      _screenStream = await _capture.startCapture(
        fps: 30,
        sourceId: sourceId,
        maxWidth: targetLongSide,
        maxHeight: targetLongSide,
      );
      peerManager.localStream = _screenStream;
      onLocalStreamUpdated?.call(_screenStream!);

      final real = capturedSize;
      if (real != null && real.$1 > 0 && real.$2 > 0) {
        await peerManager.addTracks(_screenStream!,
            width: real.$1, height: real.$2);
        peerManager.rescaleOutgoing(width: real.$1, height: real.$2);
        log.d('ScreenShare: tracks added, initial scale from $real');
      } else {
        await peerManager.addTracks(_screenStream!);
        log.d('ScreenShare: tracks added (native size)');
      }
      onCaptureReady?.call();
    } catch (e) {
      _captureStarted = false;
      log.warning('ScreenShare: start failed — ${e.toString()}');
      onCaptureError?.call('Screen capture failed: grant Screen Recording '
          'permission (macOS) or run a build signed with that entitlement.');
    }
  }

  /// DPR estimate from a captured physical size vs the logical primary size.
  /// Retina screens report physical ≈ dpr× logical; clamped to [1.0, 3.0].
  double estimateDpr(int? w, int? h) {
    if (w == null || h == null) return 1.0;
    final logicalLong = localScreenSize.width >= localScreenSize.height
        ? localScreenSize.width
        : localScreenSize.height;
    final physicalLong = (w > h ? w : h).toDouble();
    if (logicalLong <= 0) return 1.0;
    final ratio = physicalLong / logicalLong;
    if (ratio >= 1.5) return ratio > 3.0 ? 3.0 : ratio;
    return 1.0;
  }

  /// Called once the raw preview paints its first frame (true capture size).
  /// Re-applies the 64-aligned encoder scale and starts the loopback preview.
  void applyRealCaptureSize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    if (_realSizeApplied) {
      log.d('ScreenShare: real capture size already applied '
          '($_realAppliedW x $_realAppliedH); ignoring $w x $h');
      return;
    }
    _realSizeApplied = true;
    _realAppliedW = w;
    _realAppliedH = h;
    peerManager.rescaleOutgoing(width: w, height: h);
    log.d('ScreenShare: real capture size = $w x $h — applied 64-aligned scale');
    _startLoopback(w, h);
  }

  Future<void> _startLoopback(int w, int h) async {
    if (_loopbackStarted) return;
    _loopbackStarted = true;
    final stream = peerManager.localStream;
    if (stream == null) return;
    final dpr = estimateDpr(w, h);
    log.d('ScreenShare: starting stride-safe loopback from $w x $h '
        '(dpr=${dpr.toStringAsFixed(2)})');
    final preview = await peerManager.startLocalPreviewLoopback(
      stream, w, h,
      maxLongSide: targetLongSide.toDouble(), dpr: dpr,
    );
    onLocalStreamUpdated?.call(preview ?? stream);
    onLocalPreviewReady?.call(preview ?? stream);
  }

  Future<void> stop() async {
    await _capture.stopCapture();
    _screenStream = null;
    _captureStarted = false;
    _loopbackStarted = false;
  }
}
