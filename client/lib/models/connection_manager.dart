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
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:screen_retriever/screen_retriever.dart';

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
  /// Target max long-side (px) of the shared screen video. Mirrors
  /// [PeerManager.kDefaultTargetLongSide] so it can be tuned once via
  /// --dart-define=TARGET_LONG_SIDE=<px> at build time.
  static const int targetLongSide = PeerManager.kDefaultTargetLongSide;

  final Room room;
  final String serverBaseUrl; // e.g. http://localhost:3000
  final String token;          // pre-obtained JWT
  final String? screenSourceId; // macOS display id to share (null = auto-pick)

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

  /// Channel to the native (macOS) input simulator that replays incoming
  /// mouse/keyboard events on the controller's local machine.
  static const MethodChannel _inputChannel =
      MethodChannel('remote_desktop/input');

  /// Local display size (logical pixels), used by the controller to map
  /// normalized viewer coordinates back to screen pixels.
  Size _localScreenSize = const Size(1920, 1080);

  /// Device-pixel-ratio of the primary display (logical × dpr = physical).
  double _localScreenScaleFactor = 1.0;

  /// Ensures clean-up runs only once (disconnect() may be followed by dispose()).
  bool _cleanedUp = false;

  /// Local (controller) stream for preview. Prefers the stride-safe loopback
  /// stream (see PeerManager.startLocalPreviewLoopback) so the renderer never
  /// shows the raw, non-64-aligned capture frame.
  MediaStream? get localStream => _peer.localPreviewStream ?? _peer.localStream;

  /// Real captured frame size (may differ from the requested size because
  /// macOS getDisplayMedia ignores width/height). Exposed so the UI can
  /// re-apply the outgoing scale from the true source size.
  ///
  /// `track.getSettings()` returns `0x0` on macOS screen capture, so when that
  /// is unusable we derive the native physical capture size from the primary
  /// display the controller shares (logical size × device-pixel-ratio).
  (int, int)? get capturedSize {
    final cs = _screenCapture?.capturedSize;
    if (cs != null && cs.$1 > 0 && cs.$2 > 0) return cs;
    final w = (_localScreenSize.width * _localScreenScaleFactor).round();
    final h = (_localScreenSize.height * _localScreenScaleFactor).round();
    if (w > 0 && h > 0) return (w, h);
    return null;
  }

  /// Called when the remote stream becomes available (viewer side).
  Function(MediaStream)? onRemoteStreamUpdated;

  /// Called when the local screen-capture stream is ready (controller side).
  Function(MediaStream)? onLocalStreamUpdated;

  /// Called once the stride-safe local-preview loopback has produced its
  /// decoded (64-aligned) stream. The UI uses this to stop hiding the raw
  /// capture behind a placeholder — the raw frame is non-64-aligned and would
  /// render sheared, so we only reveal the surface once this clean stream is
  /// bound.
  Function(MediaStream)? onLocalPreviewReady;

  /// Called when screen capture fails to start (e.g. permission denied).
  Function(String)? onCaptureError;

  /// Re-apply the outgoing video resolution cap from the *real* captured size.
  /// The UI calls this after the local preview paints its first frame so the
  /// encoder downscales the chosen display's actual resolution (dynamic
  /// resolution) rather than an estimate.
  ///
  /// [dpr] is the source display's device-pixel-ratio. If omitted we estimate
  /// it from the captured physical size vs. the logical primary-screen size we
  /// read in [_fetchLocalScreenSize] — this is what lets a Retina (HiDPI)
  /// screen be scaled to its natural logical resolution instead of shearing.
  void rescaleOutgoing(
      {int? width,
      int? height,
      double? maxLongSide,
      double? dpr}) {
    maxLongSide ??= targetLongSide.toDouble();
    dpr ??= _estimateDpr(width, height);
    _peer.rescaleOutgoing(
        width: width, height: height, maxLongSide: maxLongSide, dpr: dpr);
  }

  /// Estimate the device-pixel-ratio of the shared screen: compare its captured
  /// *physical* long side against the *logical* primary-display long side.
  /// Retina screens report a physical size ≈ dpr× the logical size; standard
  /// external screens report ≈ 1×. Clamped to a sane [1.0, 3.0] range.
  double _estimateDpr(int? w, int? h) {
    if (w == null || h == null) return 1.0;
    final logicalLong = _localScreenSize.width >= _localScreenSize.height
        ? _localScreenSize.width
        : _localScreenSize.height;
    final physicalLong = (w > h ? w : h).toDouble();
    if (logicalLong <= 0) return 1.0;
    final ratio = physicalLong / logicalLong;
    if (ratio >= 1.5) return ratio > 3.0 ? 3.0 : ratio;
    return 1.0;
  }

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
    this.screenSourceId,
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
  bool _loopbackStarted = false;
  bool _realSizeApplied = false;
  int _realAppliedW = 0;
  int _realAppliedH = 0;

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

  /// Read the controller's primary display size so incoming normalized
  /// viewer coordinates can be mapped to local screen pixels.
  Future<void> _fetchLocalScreenSize() async {
    try {
      final display = await ScreenRetriever.instance.getPrimaryDisplay();
      _localScreenSize = Size(display.size.width, display.size.height);
      _localScreenScaleFactor = display.scaleFactor?.toDouble() ?? 1.0;
      print('Controller: local screen size = '
          '${_localScreenSize.width}x${_localScreenSize.height} '
          '@${_localScreenScaleFactor}x');
    } catch (e) {
      print('Controller: failed to read screen size ($e), '
          'falling back to $_localScreenSize');
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
        await _fetchLocalScreenSize();
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
        .startCapture(
          fps: 30,
          sourceId: screenSourceId,
          // Let non-macOS captures request up to the target long side so the
          // encoder (below) isn't starved by a low capture cap. macOS ignores
          // this anyway and returns the full native resolution.
          maxWidth: targetLongSide,
          maxHeight: targetLongSide,
        )
        .then((stream) async {
      _peer.localStream = stream;
      onLocalStreamUpdated?.call(stream);
      // Add every track (the screen video) to the PeerConnection BEFORE
      // any offer is created, otherwise the SDP would have no media.
      // Pass the best-known capture size so addTracks applies the CORRECT
      // 64-aligned encoder scale immediately — on macOS a later
      // setParameters(scaleResolutionDownBy) often does NOT re-apply, so the
      // scale chosen here is what the viewer actually receives.
      final real = capturedSize;
      if (real != null && real.$1 > 0 && real.$2 > 0) {
        await _peer.addTracks(stream,
            width: real.$1, height: real.$2);
        print('Controller: ${stream.getTracks().length} local track(s) added '
            '(initial scale from derived capture size ${real.$1}x${real.$2})');
      } else {
        await _peer.addTracks(stream);
        print('Controller: ${stream.getTracks().length} local track(s) added '
            '(no derived size — sending native)');
      }
      // Re-apply from the derived size as a belt-and-braces backup. The
      // *true* capture size is only known once the raw renderer paints its
      // first frame (getSettings() returns 0x0 and the display DPR is
      // unreliable on macOS), so the authoritative rescale + stride-safe
      // loopback preview is triggered from there (see applyRealCaptureSize).
      if (real != null && real.$1 > 0 && real.$2 > 0) {
        rescaleOutgoing(width: real.$1, height: real.$2);
        print('Controller: backup outgoing rescale from derived '
            'capture size ${real.$1}x${real.$2}');
      }
      _screenCaptureReady = true;
      _maybeCreateOffer();
    }).catchError((e) {
      print('Controller: screen capture failed — ${e.toString().substring(0, 100)}');
      onCaptureError?.call(
          'Screen capture failed: grant Screen Recording permission (macOS) or run a build signed with that entitlement.');
    });
  }

  /// Called once the raw preview renderer paints its first frame, which is the
  /// only reliable source of the *true* capture size on macOS (track
  /// getSettings() returns 0x0 and the display DPR is unreliable). Re-applies
  /// the 64-aligned encoder scale from the real dimensions and, if not already
  /// done, starts the stride-safe local-preview loopback.
  void applyRealCaptureSize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    // Guard: this is only ever authorized from the RAW capture's first frame
    // (the true source size, e.g. 2940x1912). The stride-safe loopback preview
    // rebinds the same renderer to its own decoded stream (e.g. 1280x832), and
    // *that* stream also fires onFirstFrameRendered — re-entering this method.
    // If we let it apply again from the decoded size, _scaleFor(1280, 832) is
    // already 64-aligned & ≤ budget, so it returns scale=1.0 and the MAIN
    // PeerConnection would then ship the raw, sheared 2940x1912 to the viewer.
    // Run exactly once from the raw frame and ignore all later (loopback) frames.
    if (_realSizeApplied) {
      print('Controller: real capture size already applied '
          '(${_realAppliedW}x${_realAppliedH}); ignoring ${w}x$h '
          'from loopback preview frame');
      return;
    }
    _realSizeApplied = true;
    _realAppliedW = w;
    _realAppliedH = h;
    rescaleOutgoing(width: w, height: h);
    print('Controller: real capture size from first frame = ${w}x$h '
        '— re-applied 64-aligned outgoing scale');
    _startLoopback(w, h);
  }

  Future<void> _startLoopback(int w, int h) async {
    if (_loopbackStarted) return;
    _loopbackStarted = true;
    final stream = _peer.localStream;
    if (stream == null) return;
    // Use the SAME budget + DPR as the main outgoing stream so the preview
    // resolution matches what the viewer receives, and so the loopback scaler
    // snaps to a 64-aligned width / even height (stride-safe decode).
    final dpr = _estimateDpr(w, h);
    print('Controller: starting stride-safe local preview loopback '
        'from ${w}x$h (budget=${targetLongSide}, dpr=${dpr.toStringAsFixed(2)})');
    final preview = await _peer.startLocalPreviewLoopback(stream, w, h,
        maxLongSide: targetLongSide.toDouble(), dpr: dpr);
    // Reveal the surface only once we have the clean, decoded stream. If the
    // loopback failed we still reveal (falling back to the raw capture) so the
    // placeholder doesn't hang forever.
    onLocalStreamUpdated?.call(preview ?? stream);
    onLocalPreviewReady?.call(preview ?? stream);
  }

  // ========== Viewer Side ==========

  void _setupViewer() {
    _inputHandler = InputEventHandler((event) {
      if (event is RemoteMouseEvent) {
        _signal.sendMouseEvent(
            event.action, event.x, event.y, event.button, room.id);
      } else if (event is RemoteKeyEvent) {
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

  // ========== Remote Control (controller applies viewer input) ==========

  /// Apply an incoming mouse event on the controller's local machine.
  /// The viewer sends normalized [0..1] coordinates relative to the video
  /// box; we scale them to the local display size before replaying.
  void _onRemoteMouseEvent(SignalMessage msg) {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;

    final action = payload['action'] as String? ?? 'move';
    final nx = (payload['x'] as num?)?.toDouble() ?? 0;
    final ny = (payload['y'] as num?)?.toDouble() ?? 0;
    final button = (payload['button'] as int?) ?? 0;
    final delta = (payload['delta'] as num?)?.toDouble() ?? 0;

    final px = nx * _localScreenSize.width;
    final py = ny * _localScreenSize.height;

    print('Controller: apply MOUSE $action @ ($px, $py) button=$button');
    _inputChannel.invokeMethod('mouse', {
      'action': action,
      'x': px,
      'y': py,
      'button': button,
      'delta': delta,
    }).catchError((e) {
      print('Controller: failed to dispatch mouse event to native ($e)');
    });
  }

  /// Apply an incoming keyboard event on the controller's local machine.
  void _onRemoteKeyEvent(SignalMessage msg) {
    if (room.role != 'controller') return;
    final payload = msg.payload as Map<String, dynamic>?;
    if (payload == null) return;

    final action = payload['action'] as String? ?? 'down';
    final keyCode = (payload['keyCode'] as int?) ?? 0;

    print('Controller: apply KEY $action keyCode=$keyCode');
    _inputChannel.invokeMethod('key', {
      'action': action,
      'keyCode': keyCode,
    }).catchError((e) {
      print('Controller: failed to dispatch key event to native ($e)');
    });
  }

  // ========== Remote Control (viewer sends input) ==========

  /// Send a mouse event to the controller. Coordinates are normalized to
  /// [0..1] relative to the displayed video so they are resolution-independent.
  void sendInputMouse(String action, double nx, double ny,
      {int button = 0, double delta = 0}) {
    _signal.sendMouseEvent(action, nx, ny, button, room.id);
  }

  /// Send a keyboard event (by native key code) to the controller.
  void sendInputKey(String action, int keyCode) {
    _signal.sendKeyEventWithCode(action, keyCode, room.id);
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
    if (_cleanedUp) return;
    _cleanedUp = true;
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
