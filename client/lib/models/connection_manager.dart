/// Connection orchestrator — the thin facade that wires together signaling,
/// the WebRTC peer connection, screen capture, and input control.
///
/// Its only responsibility is *coordination*; the heavy logic lives in the
/// collaborators it composes:
///   - [SignalClient]         : WebSocket transport + auto-reconnect
///   - [PeerManager]          : RTCPeerConnection lifecycle / SDP / ICE / stats
///   - [ScreenShareController]: controller-side capture, scaling, loopback
///   - [InputController]      : viewer capture + controller replay
library;

import 'dart:ui' show Size;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/logger.dart';
import '../input/input_controller.dart';
import '../signal/protocol.dart';
import '../signal/signal_client.dart';
import '../utils/resolution.dart';
import '../webrtc/peer_manager.dart';
import '../webrtc/screen_share_controller.dart';
import 'room.dart';

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  disconnectedLocal,
  error,
}

class ConnectionManager {
  static const int targetLongSide = PeerManager.kDefaultTargetLongSide;

  final Room room;
  final String serverBaseUrl;
  final String token;
  final String? screenSourceId;

  late final SignalClient _signal;
  late final PeerManager _peer;
  late final ScreenShareController _screenShare;
  late final InputController _input;

  ConnectionState _state = ConnectionState.disconnected;
  final List<Function(ConnectionState)> _stateListeners = [];

  String? _remoteUserId;
  MediaStream? _remoteStream;
  bool _captureReady = false;

  Function(MediaStream)? onRemoteStreamUpdated;
  Function(MediaStream)? onLocalStreamUpdated;
  Function(MediaStream)? onLocalPreviewReady;
  Function(String)? onCaptureError;

  ConnectionManager({
    required this.room,
    required this.serverBaseUrl,
    required this.token,
    this.screenSourceId,
  }) {
    _signal = SignalClient(buildWsUrl(serverBaseUrl));
    _peer = PeerManager();
    _screenShare = ScreenShareController(_peer);
    _input = InputController(
      isController: room.role == 'controller',
      localScreenSize: const Size(1920, 1080),
    );

    _signal.addListener(_onSignalMessage);
    _peer.onRemoteStream(_onRemoteStreamReceived);
    _peer.setIceCallback((c) => _signal.sendIceCandidate(c, room.id, _remoteUserId));

    _screenShare.onLocalStreamUpdated = (s) => onLocalStreamUpdated?.call(s);
    _screenShare.onLocalPreviewReady = (s) => onLocalPreviewReady?.call(s);
    _screenShare.onCaptureError = (m) => onCaptureError?.call(m);
    _screenShare.onCaptureReady = _onCaptureReady;

    _signal.onConnected = _onSignalConnected;
    _signal.onDisconnected = _onSignalDisconnected;
    _signal.onReconnected = _onSignalReconnected;
  }

  // ========== Public getters ==========
  ConnectionState get state => _state;
  String? get remoteUserId => _remoteUserId;
  MediaStream? get remoteStream => _remoteStream;
  MediaStream? get localStream => _screenShare.stream ?? _peer.localStream;
  (int, int)? get capturedSize => _screenShare.capturedSize;

  void addStateListener(Function(ConnectionState) l) => _stateListeners.add(l);
  void removeStateListener(Function(ConnectionState) l) =>
      _stateListeners.remove(l);

  void _notifyState(ConnectionState s) {
    _state = s;
    for (final l in List.from(_stateListeners)) {
      l(s);
    }
  }

  // ========== Connection lifecycle ==========
  Future<bool> connect(String userId) async {
    if (_state == ConnectionState.connected ||
        _state == ConnectionState.connecting) {
      return false;
    }
    _notifyState(ConnectionState.connecting);
    try {
      await _peer.initialize(
        iceServers: [
          {'urls': ['stun:stun.l.google.com:19302']}
        ],
        isController: room.role == 'controller',
      );
      if (room.role == 'controller') {
        await _screenShare.fetchLocalScreenSize();
        _input.localScreenSize = _screenShare.localScreenSize;
      }
      await _signal.connect(token, room.id, room.role);
      return true;
    } catch (e) {
      log.warning('Connection error: $e');
      _notifyState(ConnectionState.error);
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _signal.leaveRoom();
    } catch (e) {
      log.warning('Connection: leaveRoom failed: $e');
    }
    _signal.disconnect();
    _cleanup();
    _notifyState(ConnectionState.disconnectedLocal);
  }

  void _onSignalConnected() {
    _notifyState(ConnectionState.connected);
    _setupRole();
  }

  void _onSignalDisconnected() {
    // Unexpected drop; SignalClient is already retrying with backoff.
    _notifyState(ConnectionState.connecting);
  }

  void _onSignalReconnected() {
    _notifyState(ConnectionState.connected);
    _setupRole();
    if (room.role == 'controller' && _captureReady) _maybeCreateOffer();
  }

  void _setupRole() {
    if (room.role == 'controller') {
      _screenShare.start(sourceId: screenSourceId);
    }
    // Viewer input is captured directly by the UI (Listener/Focus) and
    // forwarded through sendInputMouse/sendInputKey; nothing to start here.
  }

  // ========== Signal message dispatch ==========
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
      case SignalType.mouseEvent:
        _onRemoteMouseEvent(msg);
        break;
      case SignalType.keyEvent:
        _onRemoteKeyEvent(msg);
        break;
      case SignalType.peerLeft:
        _onPeerLeft(msg);
        break;
      case SignalType.authError:
        log.warning(
            'Auth error: ${(msg.payload as Map?)?['message'] ?? 'unknown'}');
        _notifyState(ConnectionState.error);
        break;
    }
  }

  Future<void> _onRoomJoined(SignalMessage msg) async {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    final peers =
        (payload?['peers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (final p in peers) {
      if (p['role'] == 'viewer') {
        _remoteUserId = p['userId'] as String?;
        break;
      }
    }
    if (_remoteUserId != null) {
      _maybeCreateOffer();
    } else {
      log.d('Controller: joined, waiting for a viewer to join...');
    }
  }

  Future<void> _onPeerJoined(SignalMessage msg) async {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;
    if (payload['role'] == 'viewer' && payload['userId'] != null) {
      _remoteUserId = payload['userId'] as String?;
      log.d('Controller: viewer "$_remoteUserId" joined');
      _maybeCreateOffer();
    }
  }

  void _onCaptureReady() {
    _captureReady = true;
    _maybeCreateOffer();
  }

  void _maybeCreateOffer() {
    if (room.role != 'controller') return;
    if (!_captureReady) {
      log.d('Controller: delay offer — capture not ready');
      return;
    }
    if (_remoteUserId == null) {
      log.d('Controller: delay offer — no viewer known');
      return;
    }
    _createAndSendOffer();
  }

  Future<void> _createAndSendOffer() async {
    try {
      final offer = await _peer.createOffer();
      log.d('Controller: creating OFFER to $_remoteUserId');
      await _signal.sendOffer(offer, room.id, _remoteUserId);
    } catch (e) {
      log.warning('Controller: createOffer failed: $e');
    }
  }

  Future<void> _onOffer(SignalMessage msg) async {
    if (room.role != 'viewer') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;
    final sdpMap = payload['sdp'] as Map<String, dynamic>;
    _remoteUserId = msg.from;
    log.d('Viewer: received OFFER from ${msg.from}');
    try {
      await _peer.setRemoteDescriptionWithType(
          sdpMap['type'] as String, sdpMap['sdp'] as String);
      final answer = await _peer.createAnswer();
      log.d('Viewer: created ANSWER to $_remoteUserId');
      await _signal.sendAnswer(answer, room.id, _remoteUserId);
    } catch (e) {
      log.warning('Viewer: createAnswer failed: $e');
    }
  }

  Future<void> _onAnswer(SignalMessage msg) async {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;
    final sdpMap = payload['sdp'] as Map<String, dynamic>;
    log.d('Controller: received ANSWER from ${msg.from}');
    try {
      await _peer.setRemoteDescriptionWithType(
          sdpMap['type'] as String, sdpMap['sdp'] as String);
    } catch (e) {
      log.warning('Controller: setRemoteDescription failed: $e');
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
      log.warning('ICE candidate parse failed: $e');
    }
  }

  void _onPeerLeft(SignalMessage msg) {
    final payload = msg.payload as Map<String, dynamic>?;
    log.d('Peer left: ${payload?['userId']}');
    _remoteUserId = null;
    _notifyState(ConnectionState.disconnected);
  }

  // ========== Controller-side input replay ==========
  void _onRemoteMouseEvent(SignalMessage msg) {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;
    final action = payload['action'] as String? ?? 'move';
    final nx = (payload['x'] as num?)?.toDouble() ?? 0;
    final ny = (payload['y'] as num?)?.toDouble() ?? 0;
    final button = (payload['button'] as int?) ?? 0;
    final delta = (payload['delta'] as num?)?.toDouble() ?? 0;
    _input.applyRemoteMouse(action, nx, ny, button, delta);
  }

  void _onRemoteKeyEvent(SignalMessage msg) {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;
    final action = payload['action'] as String? ?? 'down';
    final keyCode = (payload['keyCode'] as int?) ?? 0;
    _input.applyRemoteKey(action, keyCode);
  }

  void _onRemoteStreamReceived(MediaStream stream) {
    _remoteStream = stream;
    log.d('Remote video stream received: ${stream.id}');
    onRemoteStreamUpdated?.call(stream);
  }

  // ========== Public input API (viewer side) ==========
  void sendInputMouse(String action, double nx, double ny,
      {int button = 0, double delta = 0}) {
    _signal.sendMouseEvent(action, nx, ny, button, room.id);
  }

  void sendInputKey(String action, int keyCode) {
    _signal.sendKeyEventWithCode(action, keyCode, room.id);
  }

  // ========== Capture / scaling (delegated) ==========
  void applyRealCaptureSize(int w, int h) =>
      _screenShare.applyRealCaptureSize(w, h);

  void rescaleOutgoing(
          {int? width, int? height, double? maxLongSide, double? dpr}) {
    _peer.rescaleOutgoing(
        width: width, height: height, maxLongSide: maxLongSide, dpr: dpr ?? 1.0);
  }

  /// Real, measured media statistics for the HUD.
  Future<MediaStats> getMediaStats() => _peer.getStats();

  // ========== Cleanup ==========
  void _cleanup() {
    _signal.removeListener(_onSignalMessage);
    _signal.disconnect();
    _peer.dispose();
    _screenShare.stop();
    _input.dispose();
  }

  void dispose() => _cleanup();
}
