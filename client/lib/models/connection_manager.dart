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
import 'dart:convert';
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

  ConnectionManager({
    required this.room,
    required this.serverBaseUrl,
    required this.token,
  }) {
    // Derive WS URL: http://host:3000 → ws://host:3000/signal
    final wsUrl = serverBaseUrl
        .replaceAll('http://', 'ws://')
        .replaceAll('https://', 'wss://')
        + '/signal';
    _signal = SignalClient(wsUrl);
    _peer = PeerManager();

    _signal.addListener(_onSignalMessage);
    _peer.onRemoteStream(_onRemoteStreamReceived);

    // Connect ICE candidate forwarding
    _peer.setIceCallback(_onLocalIceCandidate);
  }

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
      // Connect WebSocket with the pre-obtained JWT token
      await _signal.connect(token, room.id, room.role);

      // Setup role-specific resources
      if (room.role == 'controller') {
        _setupController();
      } else {
        _setupViewer();
      }

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
    _peer.initialize(
      iceServers: [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
      isController: true,
    ).then((_) {
      _screenCapture = ScreenCaptureManager();
      _screenCapture!
          .startCapture(fps: 30, maxWidth: 1920, maxHeight: 1080)
          .then((stream) {
        _peer.localStream = stream;
        for (final track in stream.getTracks()) {
          if (track.kind == 'video') {
            _peer.addTrack(stream).then((sender) {
              print('Controller: video track added');
            });
          }
        }
      }).catchError((e) {
        print('Controller: screen capture failed — ${e.toString().substring(0, 100)}');
      });
    });
  }

  // ========== Viewer Side ==========

  void _setupViewer() {
    _peer.initialize(
      iceServers: [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
      isController: false,
    );
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
    if (room.role == 'controller') {
      try {
        final offer = await _peer.createOffer();
        await _signal.sendOffer(offer, room.id);
        print('Controller: sent OFFER');
      } catch (e) {
        print('Controller: createOffer failed: $e');
      }
    }
  }

  Future<void> _onOffer(SignalMessage msg) async {
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null || room.role != 'viewer') return;
    final sdpJSON = payload['sdp'];
    _remoteUserId = msg.from;
    try {
      await _peer.setRemoteDescriptionWithType('offer', jsonEncode(sdpJSON));
      final answer = await _peer.createAnswer();
      await _signal.sendAnswer(answer, room.id);
      print('Viewer: sent ANSWER');
    } catch (e) {
      print('Viewer: createAnswer failed: $e');
    }
  }

  Future<void> _onAnswer(SignalMessage msg) async {
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null || room.role != 'controller') return;
    try {
      await _peer.setRemoteDescriptionWithType(
          'answer', jsonEncode(payload['sdp']));
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
