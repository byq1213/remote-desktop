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
    return senders;
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
