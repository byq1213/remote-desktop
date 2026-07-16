/// WebRTC peer connection manager for sending/receiving screen video.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Manages the WebRTC PeerConnection lifecycle.
/// Handles offer/answer exchange, ICE candidates, and media tracks.
class PeerManager {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final List<Function(MediaStream)> _onRemoteStreamListeners = [];
  final Map<String, RTCRtpSender> _senders = {};
  Function(RTCIceCandidate)? _externalIceCallback;

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
  Future<List<RTCRtpSender>> addTracks(MediaStream stream) async {
    final senders = <RTCRtpSender>[];
    for (final track in stream.getTracks()) {
      print('PeerManager: adding local ${track.kind} track');
      final sender = await _pc!.addTrack(track, stream);
      _senders[track.id!] = sender;
      senders.add(sender);
    }
    // macOS getDisplayMedia ignores the capture `max` constraint and hands
    // back the *entire* virtual desktop when an external display is attached
    // (e.g. 3840x4072 — a near-square, ~15.6M-pixel frame). Such a large /
    // odd frame fails to render on the viewer (blank/blue). Scale the long
    // side down to <= 1920 at the encoder so the viewer gets a renderable
    // frame. This is the real fix; the capture-side `max` cap is ineffective.
    _capOutgoingResolution(senders);
    return senders;
  }

  /// Scale outgoing video encodings so the long side is at most
  /// [maxLongSide] px. Reads the real capture size from [width]/[height]
  /// when given, else from the track's settings; falls back to a 2x
  /// downscale. This keeps even large single displays renderable on the
  /// viewer while preserving the source's aspect ratio (dynamic resolution).
  void _capOutgoingResolution(List<RTCRtpSender> senders,
      {double maxLongSide = 3840.0}) {
    _rescaleSenders(senders, maxLongSide: maxLongSide);
  }

  /// Re-apply the resolution cap using the *actual* captured dimensions. Call
  /// this after the local preview paints its first frame so we scale from the
  /// real source size (read from [width]/[height]) instead of an estimate.
  void rescaleOutgoing(
      {int? width, int? height, double maxLongSide = 3840.0}) {
    final senders = _senders.values.toList();
    _rescaleSenders(senders,
        width: width, height: height, maxLongSide: maxLongSide);
  }

  void _rescaleSenders(List<RTCRtpSender> senders,
      {int? width, int? height, double maxLongSide = 3840.0}) {
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
        final scale = _scaleFor(w, h, maxLongSide);
        final params = sender.parameters;
        final encodings = params.encodings ?? <RTCRtpEncoding>[];
        if (encodings.isEmpty) {
          encodings.add(RTCRtpEncoding(scaleResolutionDownBy: scale));
        } else {
          final e = encodings.first;
          encodings[0] = RTCRtpEncoding(
            rid: e.rid,
            active: e.active,
            maxBitrate: e.maxBitrate,
            maxFramerate: e.maxFramerate,
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
        print('PeerManager: outgoing video scale=$scale '
            '(longSide<=${maxLongSide.toInt()}, src=${w ?? '?'}x${h ?? '?'})');
      } catch (e) {
        print('PeerManager: failed to set outgoing resolution: $e');
      }
    }
  }

  /// Compute the downscale factor so the longer side fits within [maxLongSide]
  /// while keeping the source aspect ratio. Returns 1.0 when already small.
  double _scaleFor(int? w, int? h, double maxLongSide) {
    if (w == null || h == null || w <= 0 || h <= 0) return 2.0;
    final longSide = (w > h ? w : h).toDouble();
    if (longSide <= maxLongSide) return 1.0;
    final scale = longSide / maxLongSide;
    return scale.ceilToDouble();
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
    _senders.clear();
    _onRemoteStreamListeners.clear();
  }
}
