/// Connection manager — the central orchestrator for all WebRTC and signaling logic.
///
/// Ties together:
/// - SignalClient (WebSocket signaling)
/// - PeerManager (WebRTC PeerConnection)
/// - ScreenCaptureManager (screen capture for controller)
/// - InputEventHandler (mouse/keyboard for viewer)
///
/// Architecture note (MVP): Current implementation uses P2P WebRTC with signaling
/// relay. The mediasoup SFU is initialized for future upgrade to 1:N broadcast.
/// For the MVP scope (1 controller → 1 viewer), P2P provides lower latency and
/// simpler implementation. Upgrade path: replace P2P Offer/Answer with mediasoup
/// Producer/Consumer when multi-viewer support is needed.
library;

import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/room.dart';
import '../signal/signal_client.dart';
import '../input/event_handler.dart';
import '../webrtc/peer_manager.dart';
import '../webrtc/screen_capture.dart';

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  disconnectedLocal,
  error,
}

class ConnectionManager {
  final Room room;
  final String serverBaseUrl; // e.g. http://localhost:3000
  final String token;          // pre-obtained JWT

  late SignalClient _signal;
  late PeerManager _peer;
  ScreenCaptureManager? _screenCapture;
  InputEventHandler? _inputHandler;

  ConnectionState _state = ConnectionState.disconnected;
  final List<Function(ConnectionState)> _stateListeners = [];

  String? _remoteUserId;
  Timer? _reconnectTimer;
  static const int _maxReconnectAttempts = 3;
  int _reconnectAttempts = 0;

  ConnectionState get state => _state;
  String? get remoteUserId => _remoteUserId;
  MediaStream? _remoteStream;
  MediaStream? get remoteStream => _remoteStream;

  /// Local (controller) screen-capture stream, for preview.
  MediaStream? get localStream => _peer.localStream;

  /// Called when the remote stream becomes available (viewer side).
  Function(MediaStream)? onRemoteStreamUpdated;

  /// Called when the local screen-capture stream is ready (controller side).
  Function(MediaStream)? onLocalStreamUpdated;

  /// Called when screen capture fails to start (e.g. permission denied).
  Function(String)? onCaptureError;

  /// Build a clean WebSocket URL from a base HTTP(S) URL, stripping any
  /// fragment, query string, or trailing slash that could break the
  /// server's exact `/signal` path match.
  static String _buildWsUrl(String base) {
    var s = base.trim();
    final hash = s.indexOf('#');
    if (hash != -1) s = s.substring(0, hash);
    final q = s.indexOf('?');
    if (q != -1) s = s.substring(0, q);
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    s = s.replaceAll('http://', 'ws://').replaceAll('https://', 'wss://');
    if (!s.endsWith('/signal')) s = '$s/signal';
    return s;
  }

  ConnectionManager({
    required this.room,
    required this.serverBaseUrl,
    required this.token,
  }) {
    // Derive WS URL: http://host:3000 → ws://host:3000/signal
    final wsUrl = _buildWsUrl(serverBaseUrl);
    _signal = SignalClient(wsUrl);
    _peer = PeerManager();

    _signal.addListener(_onSignalMessage);
    _peer.onRemoteStream(_onRemoteStreamReceived);

    // Connect ICE candidate forwarding
    _peer.setIceCallback(_onLocalIceCandidate);
  }

  /// True once the controller's local screen-capture stream has been added
  /// to the PeerConnection. Offers must only be created after this is true,
  /// otherwise the SDP would contain no media tracks.
  bool _screenCaptureReady = false;

  void addStateListener(Function(ConnectionState) listener) {
    _stateListeners.add(listener);
  }

  void removeStateListener(Function(ConnectionState) listener) {
    _stateListeners.remove(listener);
  }

  void _notifyState(ConnectionState newState) {
    _state = newState;
    for (final listener in List.from(_stateListeners)) {
      listener(newState);
    }
  }

  // ========== Main Connection Flow ==========

  Future<bool> connect(String userId) async {
    if (_state == ConnectionState.connected ||
        _state == ConnectionState.connecting) {
      return false;
    }

    _notifyState(ConnectionState.connecting);
    _reconnectAttempts = 0;

    try {
      // Initialize PeerConnection BEFORE connecting WebSocket so that
      // incoming offers/answers/candidates can be processed immediately.
      await _peer.initialize(
        iceServers: [
          {'urls': ['stun:stun.l.google.com:19302']},
        ],
        isController: room.role == 'controller',
      );

      // Setup role-specific resources
      if (room.role == 'controller') {
        _setupController();
      } else {
        _setupViewer();
      }

      // Connect WebSocket with the pre-obtained JWT token
      await _signal.connect(token, room.id, room.role);

      _notifyState(ConnectionState.connected);
      return true;
    } catch (e) {
      print('Connection error: $e');
      _notifyState(ConnectionState.error);
      return false;
    }
  }

  Future<void> disconnect() async {
    await _signal.leaveRoom();
    _cleanup();
    _notifyState(ConnectionState.disconnectedLocal);
  }

  // ========== Controller Side ==========

  void _setupController() {
    _screenCapture = ScreenCaptureManager();
    _screenCapture!
        .startCapture(fps: 30, maxWidth: 1920, maxHeight: 1080)
        .then((stream) async {
      _peer.localStream = stream;
      onLocalStreamUpdated?.call(stream);
      // Add every track (the screen video) to the PeerConnection BEFORE
      // any offer is created, otherwise the SDP would have no media.
      await _peer.addTracks(stream);
      print('Controller: ${stream.getTracks().length} local track(s) added');
      _screenCaptureReady = true;
      _maybeCreateOffer();
    }).catchError((e) {
      print('Controller: screen capture failed — ${e.toString().substring(0, 100)}');
      onCaptureError?.call(
          'Screen capture failed: grant Screen Recording permission (macOS) or run a build signed with that entitlement.');
    });
  }

  // ========== Viewer Side ==========

  void _setupViewer() {
    _inputHandler = InputEventHandler((event) {
      if (event is MouseEvent) {
        _signal.sendMouseEvent(
            event.action, event.x, event.y, event.button, room.id);
      } else if (event is KeyEvent) {
        _signal.sendKeyEvent(event.key, event.code, event.action, room.id);
      }
    });
  }

  // ========== Signal Message Handling ==========

  Future<void> _onSignalMessage(SignalMessage msg) async {
    switch (msg.type) {
      case SignalType.roomJoined:
        await _onRoomJoined(msg);
        break;
      case SignalType.peerJoined:
        await _onPeerJoined(msg);
        break;
      case SignalType.offer:
        await _onOffer(msg);
        break;
      case SignalType.answer:
        await _onAnswer(msg);
        break;
      case SignalType.iceCandidate:
        await _onIceCandidate(msg);
        break;
      case SignalType.peerLeft:
        _onPeerLeft(msg);
        break;
      case SignalType.authError:
        print(
            'Auth error: ${(msg.payload as Map?)?['message'] ?? 'unknown'}');
        _notifyState(ConnectionState.error);
        break;
    }
  }

  Future<void> _onRoomJoined(SignalMessage msg) async {
    if (room.role != 'controller') return;

    // Learn about any peers (viewers) already in the room.
    final payload = msg.payload as Map<String, dynamic>?;
    final peers = (payload?['peers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (final p in peers) {
      if (p['role'] == 'viewer') {
        _remoteUserId = p['userId'] as String?;
        break;
      }
    }

    if (_remoteUserId != null) {
      _maybeCreateOffer();
    } else {
      print('Controller: joined, waiting for a viewer to join...');
    }
  }

  /// Called when another peer joins the room (relayed by the server).
  /// The controller uses this to (re)negotiate with a newly arrived viewer.
  Future<void> _onPeerJoined(SignalMessage msg) async {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;

    final newUserId = payload['userId'] as String?;
    final newRole = payload['role'] as String?;
    if (newRole == 'viewer' && newUserId != null) {
      _remoteUserId = newUserId;
      print('Controller: viewer "$newUserId" joined');
      _maybeCreateOffer();
    }
  }

  /// Create and send an offer only when both preconditions are met:
  /// the local screen capture is ready AND we know the viewer's id.
  void _maybeCreateOffer() {
    if (room.role != 'controller') return;
    if (!_screenCaptureReady) {
      print('Controller: delay offer — screen capture not ready yet');
      return;
    }
    if (_remoteUserId == null) {
      print('Controller: delay offer — no viewer known yet');
      return;
    }
    _createAndSendOffer();
  }

  /// Build a local SDP offer and send it to the known viewer peer.
  Future<void> _createAndSendOffer() async {
    try {
      final offer = await _peer.createOffer();
      final desc = offer.toMap();
      print('Controller: creating OFFER (type=${desc['type']}, '
          'sdp length=${(desc['sdp'] as String?)?.length ?? 0}) to ${_remoteUserId ?? 'unknown'}');
      await _signal.sendOffer(offer, room.id, _remoteUserId);
      print('Controller: sent OFFER to ${_remoteUserId ?? 'unknown'}');
    } catch (e) {
      print('Controller: createOffer failed: $e');
    }
  }

  Future<void> _onOffer(SignalMessage msg) async {
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null || room.role != 'viewer') return;
    final sdpMap = payload['sdp'] as Map<String, dynamic>;
    _remoteUserId = msg.from;
    print('Viewer: received OFFER from ${msg.from} '
        '(sdp length=${(sdpMap['sdp'] as String?)?.length ?? 0})');
    try {
      await _peer.setRemoteDescriptionWithType(
          sdpMap['type'] as String, sdpMap['sdp'] as String);
      final answer = await _peer.createAnswer();
      print('Viewer: created ANSWER, sending to ${_remoteUserId ?? 'unknown'}');
      await _signal.sendAnswer(answer, room.id, _remoteUserId);
      print('Viewer: sent ANSWER to ${_remoteUserId ?? 'unknown'}');
    } catch (e) {
      print('Viewer: createAnswer failed: $e');
    }
  }

  Future<void> _onAnswer(SignalMessage msg) async {
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null || room.role != 'controller') return;
    print('Controller: received ANSWER from ${msg.from}');
    try {
      final sdpMap = payload['sdp'] as Map<String, dynamic>;
      await _peer.setRemoteDescriptionWithType(
          sdpMap['type'] as String, sdpMap['sdp'] as String);
      print('Controller: remote description set from ANSWER');
    } catch (e) {
      print('Controller: setRemoteDescription failed: $e');
    }
  }

  Future<void> _onIceCandidate(SignalMessage msg) async {
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;
    try {
      final candidate = RTCIceCandidate(
        payload['candidate'] as String,
        payload['sdpMid'] as String?,
        payload['sdpMLineIndex'] as int?,
      );
      await _peer.addIceCandidate(candidate);
    } catch (e) {
      print('ICE candidate parse failed: $e');
    }
  }

  void _onPeerLeft(SignalMessage msg) {
    final payload = msg.payload as Map<String, dynamic>?;
    print('Peer left: ${payload?['userId']}');
    _remoteUserId = null;
    _notifyState(ConnectionState.disconnected);
  }

  void _onRemoteStreamReceived(MediaStream stream) {
    _remoteStream = stream;
    print('Remote video stream received: ${stream.id}');
    onRemoteStreamUpdated?.call(stream);
  }

  // ========== ICE Candidate Forwarding (local → remote) ==========

  void _onLocalIceCandidate(RTCIceCandidate candidate) {
    _signal.sendIceCandidate(candidate, room.id, _remoteUserId);
    print('ICE candidate forwarded to ${_remoteUserId ?? 'unknown'}');
  }

  // ========== Cleanup ==========

  void _cleanup() {
    _signal.removeListener(_onSignalMessage);
    _signal.close();
    _peer.dispose();
    _screenCapture?.stopCapture();
    _inputHandler?.dispose();
    _reconnectTimer?.cancel();
  }

  void dispose() {
    _cleanup();
  }
}
