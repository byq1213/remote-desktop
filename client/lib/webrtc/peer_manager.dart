/// WebRTC peer connection manager for sending/receiving screen video.
///
/// Owns the [RTCPeerConnection] lifecycle: offer/answer exchange, ICE
/// candidate forwarding, media-track management, and the stride-safe local
/// preview loopback. Resolution/stride math lives in `utils/resolution.dart`
/// so it can be unit-tested in isolation.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/logger.dart';
import '../utils/resolution.dart';

/// Real, measured media statistics for the HUD.
class MediaStats {
  final double fps;
  final double rttMs;
  final int packetsLost;
  const MediaStats({this.fps = 0, this.rttMs = 0, this.packetsLost = 0});
  static const MediaStats empty = MediaStats();
}

class PeerManager {
  /// Target maximum length (px) of the long side of the outgoing screen video.
  /// Higher = sharper viewer image but more bandwidth/CPU. Tunable at build
  /// time via `--dart-define=TARGET_LONG_SIDE=<px>` (e.g. 3840 for 4K).
  static const int kDefaultTargetLongSide =
      int.fromEnvironment('TARGET_LONG_SIDE', defaultValue: 2560);

  RTCPeerConnection? _pc;
  MediaStream? localStream;
  final List<Function(MediaStream)> _onRemoteStreamListeners = [];
  final Map<String, RTCRtpSender> _senders = {};
  Function(RTCIceCandidate)? _externalIceCallback;

  // Local-preview loopback: a second PeerConnection pair that re-encodes the
  // (possibly non-64-aligned) raw capture and decodes it back so the preview
  // renderer gets a stride-safe frame.
  RTCPeerConnection? _lbSend;
  RTCPeerConnection? _lbRecv;
  MediaStream? _localPreviewStream;

  void onRemoteStream(Function(MediaStream) callback) {
    _onRemoteStreamListeners.add(callback);
  }

  void setIceCallback(Function(RTCIceCandidate) callback) {
    _externalIceCallback = callback;
  }

  Future<void> initialize({
    required List<Map<String, dynamic>> iceServers,
    required bool isController,
  }) async {
    _pc = await createPeerConnection(
      {'iceServers': iceServers},
      {'voice': false, 'datachannels': false, 'video': true},
    );

    _pc!.onTrack = (RTCTrackEvent event) {
      log.d('PeerManager: onTrack streams=${event.streams.length}');
      for (final stream in event.streams) {
        for (final track in stream.getTracks()) {
          if (track.kind == 'video') {
            log.d('PeerManager: remote VIDEO track received (${stream.id})');
            for (final listener in List.from(_onRemoteStreamListeners)) {
              listener(stream);
            }
          }
        }
      }
    };

    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      log.d('PeerManager: local ICE candidate (mid=${candidate.sdpMid})');
      _externalIceCallback?.call(candidate);
    };

    _pc!.onIceConnectionState = (state) {
      log.d('PeerManager: ICE connection state = $state');
    };

    _pc!.onConnectionState = (state) {
      log.d('PeerManager: PeerConnection state = $state');
    };

    log.d('PeerManager initialized (controller: $isController)');
  }

  Future<RTCSessionDescription> createOffer() async {
    final offer = await _pc!.createOffer();
    final preferred = preferCodec(offer.sdp ?? '', 'VP8') ?? offer.sdp ?? '';
    final desc = RTCSessionDescription(preferred, offer.type);
    await _pc!.setLocalDescription(desc);
    return desc;
  }

  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _pc!.createAnswer();
    final preferred = preferCodec(answer.sdp ?? '', 'VP8') ?? answer.sdp ?? '';
    final desc = RTCSessionDescription(preferred, answer.type);
    await _pc!.setLocalDescription(desc);
    return desc;
  }

  Future<void> setRemoteDescription(RTCSessionDescription sdp) async {
    await _pc!.setRemoteDescription(sdp);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _pc!.addCandidate(candidate);
  }

  Future<void> setRemoteDescriptionWithType(String type, String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
  }

  Future<List<RTCRtpSender>> addTracks(MediaStream stream,
      {int? width, int? height, double? maxLongSide}) async {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    final senders = <RTCRtpSender>[];
    for (final track in stream.getTracks()) {
      log.d('PeerManager: adding local ${track.kind} track');
      final sender = await _pc!.addTrack(track, stream);
      _senders[track.id!] = sender;
      senders.add(sender);
    }
    // macOS getDisplayMedia ignores the capture `max` constraint and hands
    // back the entire virtual desktop when an external display is attached.
    // Scale the long side down at the encoder so the viewer gets a renderable
    // frame; this is the real fix (the capture-side cap is ineffective).
    _rescaleSenders(senders,
        width: width, height: height, maxLongSide: maxLongSide);
    return senders;
  }

  void rescaleOutgoing(
      {int? width, int? height, double? maxLongSide, double dpr = 1.0}) {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    final senders = _senders.values.toList();
    _rescaleSenders(senders,
        width: width, height: height, maxLongSide: maxLongSide, dpr: dpr);
  }

  MediaStream? get localPreviewStream => _localPreviewStream;

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
          log.d('PeerManager: loopback preview stream id='
              '${_localPreviewStream!.id} (must differ from raw capture id)');
          got.complete(_localPreviewStream!);
        }
      };
      // NOTE: deliberately NO trickle ICE here. Exchanging candidates via
      // onIceCandidate risks feeding them to the peer before its remote
      // description is set, which silently drops them; ICE then never
      // connects and the loopback times out. Instead we wait for gathering to
      // complete and embed the candidates in the SDP (non-trickle).
      for (final t in source.getTracks()) {
        final loopSrc = await createLocalMediaStream(
            'loopback-src-${DateTime.now().microsecondsSinceEpoch}');
        await send.addTrack(t, loopSrc);
      }
      final lbSenders = await send.getSenders();
      _rescaleSenders(lbSenders,
          width: w, height: h, maxLongSide: maxLongSide, dpr: dpr);
      // IMPORTANT: prefer VP8 for the loopback too (see createOffer/createAnswer)
      // so the re-encoded preview stays stride-safe on every size.
      final offer = await send.createOffer();
      final offerSdp0 = preferCodec(offer.sdp ?? '', 'VP8') ?? offer.sdp ?? '';
      await send.setLocalDescription(
          RTCSessionDescription(offerSdp0, offer.type));
      await _waitForIceGathering(send);
      final offerFinal =
          (await send.getLocalDescription())?.sdp ?? offerSdp0;
      await recv.setRemoteDescription(
          RTCSessionDescription(offerFinal, offer.type));

      final answer = await recv.createAnswer();
      final answerSdp0 =
          preferCodec(answer.sdp ?? '', 'VP8') ?? answer.sdp ?? '';
      await recv.setLocalDescription(
          RTCSessionDescription(answerSdp0, answer.type));
      await _waitForIceGathering(recv);
      final answerFinal =
          (await recv.getLocalDescription())?.sdp ?? answerSdp0;
      await send.setRemoteDescription(
          RTCSessionDescription(answerFinal, answer.type));
      final stream = await got.future.timeout(const Duration(seconds: 15));
      _lbSend = send;
      _lbRecv = recv;
      log.d('PeerManager: local preview loopback ready (${stream.id})');
      return stream;
    } catch (e) {
      log.warning('PeerManager: local preview loopback failed: $e');
      send?.close();
      recv?.close();
      return null;
    }
  }

  Future<void> _waitForIceGathering(RTCPeerConnection pc) {
    final completer = Completer<void>();
    var done = false;
    void finish() {
      if (!done) {
        done = true;
        completer.complete();
      }
    }

    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      finish();
      return completer.future;
    }
    pc.onIceGatheringState = (RTCIceGatheringState state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) finish();
    };
    return completer.future
        .timeout(const Duration(seconds: 8), onTimeout: finish);
  }

  void _rescaleSenders(List<RTCRtpSender> senders,
      {int? width, int? height, double? maxLongSide, double dpr = 1.0}) {
    maxLongSide ??= kDefaultTargetLongSide.toDouble();
    for (final sender in senders) {
      final track = sender.track;
      if (track == null || track.kind != 'video') continue;
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
        final scale = scaleFor(w, h, maxLongSide, dpr: dpr);

        // ~2.5 bits per output pixel·second (~5 Mbps @1080p, ~9 Mbps @1440p),
        // clamped to a sane [2,16] Mbps window.
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
        log.d('PeerManager: outgoing video scale=$scale bitrate=$bitrate '
            '(longSide<=${maxLongSide.toInt()}, src=${w ?? '?'}x${h ?? '?'})');
      } catch (e) {
        log.warning('PeerManager: failed to set outgoing resolution: $e');
      }
    }
  }

  /// Real, measured media statistics (fps, RTT, packet loss) for the HUD.
  /// Falls back to [MediaStats.empty] if the connection isn't ready.
  Future<MediaStats> getStats() async {
    final pc = _pc;
    if (pc == null) return MediaStats.empty;
    try {
      final reports = await pc.getStats();
      double fps = 0;
      double rttMs = 0;
      int packetsLost = 0;
      for (final r in reports) {
        final v = r.values;
        final isVideo = v['kind'] == 'video' || v['mediaType'] == 'video';
        if ((r.type == 'inbound-rtp' || r.type == 'outbound-rtp') && isVideo) {
          final f = (v['framesPerSecond'] as num?)?.toDouble();
          if (f != null && f > 0) fps = f;
          final lost = (v['packetsLost'] as num?)?.toInt();
          if (lost != null) packetsLost = lost;
        }
        if (r.type == 'candidate-pair' && v['state'] == 'succeeded') {
          final rtt = (v['currentRoundTripTime'] as num?)?.toDouble();
          if (rtt != null) rttMs = rtt * 1000;
        }
      }
      return MediaStats(fps: fps, rttMs: rttMs, packetsLost: packetsLost);
    } catch (e) {
      log.warning('PeerManager: getStats failed: $e');
      return MediaStats.empty;
    }
  }

  Future<void> pause() async {
    await _pc?.close();
  }

  Future<void> resume({
    required List<Map<String, dynamic>> iceServers,
    required bool isController,
  }) async {
    await initialize(iceServers: iceServers, isController: isController);
  }

  void dispose() {
    localStream?.dispose();
    _pc?.close();
    _lbSend?.close();
    _lbRecv?.close();
    _senders.clear();
    _onRemoteStreamListeners.clear();
  }
}
