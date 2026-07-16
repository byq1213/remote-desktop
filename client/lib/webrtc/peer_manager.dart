/// WebRTC peer connection manager for sending/receiving screen video.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Manages the WebRTC PeerConnection lifecycle.
/// Handles offer/answer exchange, ICE candidates, and media tracks.
class PeerManager {
  /// Target maximum length (px) of the long side of the outgoing screen
  /// video. Higher = sharper viewer image but more bandwidth/CPU. Tunable at
  /// build time via --dart-define=TARGET_LONG_SIDE=<px> (e.g. 3840 for 4K).
  static const int kDefaultTargetLongSide =
      int.fromEnvironment('TARGET_LONG_SIDE', defaultValue: 2560);
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final List<Function(MediaStream)> _onRemoteStreamListeners = [];
  final Map<String, RTCRtpSender> _senders = {};
  Function(RTCIceCandidate)? _externalIceCallback;

  // Local-preview loopback: a second PeerConnection pair that re-encodes the
  // (possibly non-64-aligned) raw capture and decodes it back so the preview
  // renderer gets a stride-safe frame (see startLocalPreviewLoopback).
  RTCPeerConnection? _lbSend;
  RTCPeerConnection? _lbRecv;
  MediaStream? _localPreviewStream;

  /// Callback when remote stream is received.
  void onRemoteStream(Function(MediaStream) callback) {
    _onRemoteStreamListeners.add(callback);
  }

  /// Register an external handler for locally-generated ICE candidates.
  /// Called by ConnectionManager to forward candidates to the remote peer via server.
  void setIceCallback(Function(RTCIceCandidate) callback) {
    _externalIceCallback = callback;
  }

  /// Create and configure PeerConnection.
  Future<void> initialize({
    required List<Map<String, dynamic>> iceServers,
    required bool isController,
  }) async {
    _pc = await createPeerConnection(
      {
        'iceServers': iceServers,
      },
      {
        'voice': false,
        'datachannels': false,
        'video': true,
      },
    );

    // Handle remote tracks
    _pc!.onTrack = (RTCTrackEvent event) {
      print('PeerManager: onTrack event, streams=${event.streams.length}, '
          'tracks=${event.track != null ? 1 : 0}');
      if (event.streams.isNotEmpty) {
        for (final stream in event.streams) {
          for (final track in stream.getTracks()) {
            if (track.kind == 'video') {
              print('PeerManager: remote VIDEO track received (${stream.id})');
              for (final listener in List.from(_onRemoteStreamListeners)) {
                listener(stream);
              }
            }
          }
        }
      }
    };

    // Handle ICE candidates — forward to external callback for server relay
    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      print('PeerManager: local ICE candidate (mid=${candidate.sdpMid}, '
          'foundation=${candidate.candidate?.substring(0, 20)})');
      _externalIceCallback?.call(candidate);
    };

    // Handle connection state changes
    _pc!.onIceConnectionState = (state) {
      print('PeerManager: ICE connection state = $state');
    };

    _pc!.onConnectionState = (state) {
      print('PeerManager: PeerConnection state = $state');
    };

    print('PeerManager initialized (controller: $isController)');
  }

  /// Create and set local SDP offer.
  Future<RTCSessionDescription> createOffer() async {
    final offer = await _pc!.createOffer();
    final preferred =
        _preferCodec(offer.sdp ?? '', 'VP8') ?? offer.sdp ?? '';
    final desc = RTCSessionDescription(preferred, offer.type);
    await _pc!.setLocalDescription(desc);
    return desc;
  }

  /// Create and set local SDP answer.
  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _pc!.createAnswer();
    final preferred =
        _preferCodec(answer.sdp ?? '', 'VP8') ?? answer.sdp ?? '';
    final desc = RTCSessionDescription(preferred, answer.type);
    await _pc!.setLocalDescription(desc);
    return desc;
  }

  /// Reorder the m=video payload types so the given codec (e.g. VP8) is
  /// first, steering macOS WebRTC away from the flaky H.264 VideoToolbox
  /// screencast path. Returns null if the codec isn't present.
  String? _preferCodec(String sdp, String codec) {
    final videoMatch = RegExp(r'm=video.*').firstMatch(sdp);
    if (videoMatch == null) return null;
    final codecMatch =
        RegExp(r'a=rtpmap:(\d+) $codec/90000').firstMatch(sdp);
    if (codecMatch == null) return null;
    final pt = codecMatch.group(1)!;
    final mLine = videoMatch.group(0)!;
    final parts = mLine.split(' ');
    if (parts.length < 4) return null;
    final head = parts.take(3).join(' ');
    final rest = parts.skip(3).where((p) => p != pt).join(' ');
    return sdp.replaceFirst(mLine, '$head $pt $rest');
  }

  /// Set remote description (offer or answer received from peer).
  Future<void> setRemoteDescription(RTCSessionDescription sdp) async {
    await _pc!.setRemoteDescription(sdp);
  }

  /// Add ICE candidate received from peer.
  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _pc!.addCandidate(candidate);
  }

  /// Set remote description with type and SDP string.
  Future<void> setRemoteDescriptionWithType(String type, String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
  }

  /// Add all local media tracks (used by controller for screen capture).
  ///
  /// [width]/[height] are the *best-known* capture dimensions at add time
  /// (the controller derives them from the display's logical size × DPR before
  /// the raw frame arrives). Passing them here applies the correct 64-aligned
  /// encoder scale IMMEDIATELY — crucial because on macOS a later
  /// `setParameters(scaleResolutionDownBy)` frequently does NOT re-apply, so
  /// the scale set at addTrack time is what the viewer actually receives.
  Future<List<RTCRtpSender>> addTracks(MediaStream stream,
      {int? width, int? height, double? maxLongSide}) async {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    final senders = <RTCRtpSender>[];
    for (final track in stream.getTracks()) {
      print('PeerManager: adding local ${track.kind} track');
      final sender = await _pc!.addTrack(track, stream);
      _senders[track.id!] = sender;
      senders.add(sender);
    }
    // macOS getDisplayMedia ignores the capture `max` constraint and hands
    // back the *entire* virtual desktop when an external display is attached
    // (e.g. 3840x4072 — a near-square, ~15.6M-pixel frame). Scale the long
    // side down to <= [maxLongSide] at the encoder so the viewer gets a
    // renderable frame. This is the real fix; the capture-side `max` cap is
    // ineffective.
    _capOutgoingResolution(senders,
        width: width, height: height, maxLongSide: maxLongSide);
    return senders;
  }

  /// Scale outgoing video encodings so the long side is at most
  /// [maxLongSide] px. Reads the real capture size from [width]/[height]
  /// when given, else from the track's settings; falls back to sending the
  /// source as-is (scale 1.0) — NOT a 2x downscale — so an unknown size
  /// is never silently halved. This keeps even large single displays
  /// renderable on the viewer while preserving the source's aspect ratio.
  void _capOutgoingResolution(List<RTCRtpSender> senders,
      {int? width, int? height, double? maxLongSide}) {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    _rescaleSenders(senders,
        width: width, height: height, maxLongSide: maxLongSide);
  }

  /// Re-apply the resolution cap using the *actual* captured dimensions. Call
  /// this after the local preview paints its first frame so we scale from the
  /// real source size (read from [width]/[height]) instead of an estimate.
  ///
  /// [dpr] is the source display's device-pixel-ratio (physical ÷ logical).
  /// Passing it lets us pick a HiDPI-aware target (see [_scaleFor]).
  void rescaleOutgoing(
      {int? width, int? height, double? maxLongSide, double dpr = 1.0}) {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    final senders = _senders.values.toList();
    _rescaleSenders(senders,
        width: width, height: height, maxLongSide: maxLongSide, dpr: dpr);
  }

  /// The stride-safe, decoded local-preview stream produced by the loopback
  /// PeerConnection pair (null until/unless the loopback is established).
  MediaStream? get localPreviewStream => _localPreviewStream;

  /// Produce a stride-safe local-preview stream by looping the captured
  /// [source] back through a second PeerConnection pair.
  ///
  /// On macOS `getDisplayMedia` ignores the requested capture size and returns
  /// a non-64-aligned frame (e.g. 2940x1912). The Flutter renderer's texture
  /// uploader assumes `width × 4` row stride, so such a frame is sheared in the
  /// local preview. Re-encoding + decoding the frame through libwebrtc
  /// resamples it to a 64-aligned size (driven by [w]/[h]), which the renderer
  /// then shows without shear. Returns the decoded stream, or null if the
  /// loopback could not be established (caller falls back to the raw source).
  Future<MediaStream?> startLocalPreviewLoopback(
    MediaStream source,
    int w,
    int h, {
    double maxLongSide = 1920.0,
    double dpr = 1.0,
  }) async {
    RTCPeerConnection? send;
    RTCPeerConnection? recv;
    try {
      const cfg = <String, dynamic>{
        'iceServers': <Map<String, dynamic>>[],
        'video': true,
        'audio': false,
        'datachannels': false,
      };
      send = await createPeerConnection(cfg, cfg);
      recv = await createPeerConnection(cfg, cfg);
      final got = Completer<MediaStream>();
      recv.onTrack = (RTCTrackEvent e) {
        if (e.streams.isNotEmpty && !got.isCompleted) {
          _localPreviewStream = e.streams.first;
          got.complete(_localPreviewStream!);
        }
      };
      send.onIceCandidate = (c) => recv!.addCandidate(c);
      recv.onIceCandidate = (c) => send!.addCandidate(c);
      for (final t in source.getTracks()) {
        await send.addTrack(t, source);
      }
      // Scale the loopback sender to a 64-aligned size from the real capture.
      final lbSenders = await send.getSenders();
      _rescaleSenders(lbSenders,
          width: w, height: h, maxLongSide: maxLongSide, dpr: dpr);
      final offer = await send.createOffer();
      await send.setLocalDescription(offer);
      await recv.setRemoteDescription(offer);
      final answer = await recv.createAnswer();
      await recv.setLocalDescription(answer);
      await send.setRemoteDescription(answer);
      final stream = await got.future.timeout(const Duration(seconds: 5));
      _lbSend = send;
      _lbRecv = recv;
      print('PeerManager: local preview loopback ready (${stream.id})');
      return stream;
    } catch (e) {
      print('PeerManager: local preview loopback failed: $e');
      send?.close();
      recv?.close();
      return null;
    }
  }

  void _rescaleSenders(List<RTCRtpSender> senders,
      {int? width, int? height, double? maxLongSide, double dpr = 1.0}) {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    for (final sender in senders) {
      final track = sender.track;
      if (track == null) continue;
      if (track.kind != 'video') continue;
      try {
        var w = width;
        var h = height;
        if (w == null || h == null) {
          try {
            final s = track.getSettings();
            w ??= s['width'] as int?;
            h ??= s['height'] as int?;
          } catch (_) {
            // getSettings unsupported for this source — fall through to estimate
          }
        }
        final scale = _scaleFor(w, h, maxLongSide, dpr: dpr);

        // Pick a bitrate that keeps the (downscaled) frame crisp. Screen
        // content needs more bits than a webcam feed; ~2.5 bits per output
        // pixel·second yields ~5 Mbps @1080p and ~9 Mbps @1440p, clamped to
        // a sane [2,16] Mbps window so low-res stays cheap and high-res stays
        // sharp without exploding the bitrate on weak links.
        final lw = (w ?? 0).toDouble();
        final lh = (h ?? 0).toDouble();
        final outLong = max(lw, lh) / scale;
        final outShort = min(lw, lh) / scale;
        final outPixels = outLong * outShort;
        var bitrate = (outPixels * 2.5).round();
        bitrate = bitrate.clamp(2000000, 16000000);

        final params = sender.parameters;
        final encodings = params.encodings ?? <RTCRtpEncoding>[];
        if (encodings.isEmpty) {
          encodings.add(RTCRtpEncoding(
            scaleResolutionDownBy: scale,
            maxBitrate: bitrate,
            maxFramerate: 30,
          ));
        } else {
          final e = encodings.first;
          encodings[0] = RTCRtpEncoding(
            rid: e.rid,
            active: e.active,
            maxBitrate: bitrate,
            maxFramerate: e.maxFramerate ?? 30,
            minBitrate: e.minBitrate,
            numTemporalLayers: e.numTemporalLayers,
            scaleResolutionDownBy: scale,
            ssrc: e.ssrc,
            scalabilityMode: e.scalabilityMode,
            priority: e.priority,
            networkPriority: e.networkPriority,
          );
        }
        params.encodings = encodings;
        sender.setParameters(params);
        print('PeerManager: outgoing video scale=$scale bitrate=$bitrate '
            '(longSide<=${maxLongSide.toInt()}, src=${w ?? '?'}x${h ?? '?'})');
      } catch (e) {
        print('PeerManager: failed to set outgoing resolution: $e');
      }
    }
  }

  /// Compute the downscale factor so the longer side fits within [maxLongSide]
  /// while keeping the source aspect ratio. Returns 1.0 when no scaling is
  /// needed *and* the frame is already 64-aligned.
  ///
  /// ## Why width must be 64-aligned (but height only needs to be even)
  /// The shear we actually hit is a macOS *row-stride* problem: a captured or
  /// encoded frame's `bytesPerRow` is aligned to 256 bytes, so `width × 4` must
  /// be a multiple of 256 → **width a multiple of 64**. Height is independent of
  /// the per-row stride, so it only needs to be EVEN (so the chroma plane can be
  /// sampled); it does NOT need to be 64-aligned. Force-aligning height to 64
  /// needlessly crushes ordinary screens (1080/1200/1440/2160 are none of them)
  /// — e.g. a 1080p screen was being downscaled to 1024×576 just to satisfy a
  /// bogus height constraint. Aligning to 16 (VP8 macroblock size) is NOT enough
  /// for width — a 16-aligned width like 1376 gives bytesPerRow=5504, still not
  /// ÷256, so the viewer would shear. But height only needs evenness. The old
  /// code only aligned the *budget* and applied one uniform
  /// `scaleResolutionDownBy`, so the short side frequently landed on a non-64
  /// value — exactly the Retina bug: a 1080p external screen needs no scaling
  /// (and is 64-aligned on width), while a Retina screen always needs scaling.
  ///
  /// ## Dynamic HiDPI budget ([dpr])
  /// A Retina screen's *physical* pixel count is `dpr×` its *logical* size (the
  /// size the user actually sees). Scaling down by ≈ dpr lands on that logical
  /// resolution — crisp and correctly proportioned — instead of blind-squashing
  /// a ~3000px-wide frame into 1920. For a DPR-1 external screen [dpr] is 1.0
  /// and this is a no-op.
  double _scaleFor(int? w, int? h, double maxLongSide, {double dpr = 1.0}) {
    // Unknown dimensions: send at native size (1.0) rather than halving.
    // A 2.0 fallback here would permanently crush resolution because, on
    // macOS, a later setParameters(scaleResolutionDownBy) often does NOT
    // re-apply — so this initial value is what the viewer keeps.
    if (w == null || h == null || w <= 0 || h <= 0) return 1.0;
    final longSide = (w > h ? w : h).toDouble();
    final shortSide = (w < h ? w : h).toDouble();
    // Only the WIDTH needs 64 alignment (its row stride `width×4` must be ÷256).
    // HEIGHT is independent of per-row stride and only needs to be EVEN for
    // chroma sampling, so we keep a separate `block` (64) for width checks and
    // require only evenness for height. Forcing height to 64 crushed normal
    // screens (e.g. 1080p → 1024×576), which is wrong.
    const block = 64;

    // Adaptive budget for HiDPI: prefer the display's logical long side when
    // it is smaller than the hard cap, so Retina shares at its natural size.
    var budget = maxLongSide;
    if (dpr > 1.0) {
      final logicalLong = longSide / dpr;
      budget = logicalLong < maxLongSide ? logicalLong : maxLongSide;
    }

    // If it fits AND width is 64-aligned (stride-safe) AND height is even
    // (chroma-safe), send as-is — no downscale.
    if (longSide <= budget && w % block == 0 && h % 2 == 0) return 1.0;

    // Find the largest target long side (a multiple of `block`, and no greater
    // than min(budget, native long side) so we never upscale) such that the
    // SCALED WIDTH is a multiple of `block` (stride-safe) and the SCALED HEIGHT
    // is even (chroma-safe). Shrink the long side in `block` steps until the
    // short side lands on an even value.
    var target = ((min(budget, longSide).toInt() ~/ block) * block);
    if (target < block) target = block;
    while (target >= block) {
      final scale = longSide / target;
      final shortOut = _roundEven(shortSide / scale);
      if (shortOut % 2 == 0) break;
      target -= block;
    }
    return longSide / target;
  }

  /// Round to the nearest EVEN number, matching how libwebrtc's scaler snaps
  /// each output dimension (it never emits odd widths/heights).
  int _roundEven(double v) {
    var r = v.round();
    if (r.isOdd) r += 1;
    return r;
  }

  /// Get local stream (for controller's screen capture).
  MediaStream? get localStream => _localStream;

  /// Set local stream (for controller).
  set localStream(MediaStream? stream) {
    _localStream = stream;
  }

  /// Pause/resume the connection.
  Future<void> pause() async {
    await _pc?.close();
  }

  /// Resume the connection.
  Future<void> resume({
    required List<Map<String, dynamic>> iceServers,
    required bool isController,
  }) async {
    await initialize(iceServers: iceServers, isController: isController);
  }

  /// Clean up resources.
  void dispose() {
    _localStream?.dispose();
    _pc?.close();
    _lbSend?.close();
    _lbRecv?.close();
    _senders.clear();
    _onRemoteStreamListeners.clear();
  }
}
