/// Main control screen — shows remote screen display and overlay controls.
library;

import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/connection_manager.dart';
import '../models/room.dart';

class ControlScreen extends StatefulWidget {
  final String userId;
  final String roomId;
  final String role;
  final String serverBaseUrl; // e.g. http://localhost:3000
  final String token;         // pre-obtained JWT from connect_screen

  const ControlScreen({
    super.key,
    required this.userId,
    required this.roomId,
    required this.role,
    required this.serverBaseUrl,
    required this.token,
  });

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  late ConnectionManager _connectionManager;
  late RTCVideoRenderer _remoteRenderer;
  late RTCVideoRenderer _localRenderer;
  bool _isConnecting = false;
  ConnectionState _connState = ConnectionState.disconnected;
  String? _statusMessage;
  int _fps = 0;
  int _latency = 0;
  Timer? _statsTimer;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _remoteRenderer = RTCVideoRenderer();
    _localRenderer = RTCVideoRenderer();

    _connectionManager = ConnectionManager(
      room: Room(id: widget.roomId, role: widget.role),
      serverBaseUrl: widget.serverBaseUrl,
      token: widget.token,
    );
    _connectionManager.addStateListener(_onConnectionStateChange);
    _connectionManager.onRemoteStreamUpdated = _wireRemoteVideo;
    _connectionManager.onLocalStreamUpdated = _wireLocalVideo;
    _connectionManager.onCaptureError = (msg) => setState(() => _statusMessage = msg);
    _connect();
  }

  Future<void> _initRenderers() async {
    await _remoteRenderer.initialize();
    await _localRenderer.initialize();
    print('Renderers initialized: remote.textureId=${_remoteRenderer.textureId}, local.textureId=${_localRenderer.textureId}');
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _connectionManager.dispose();
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    super.dispose();
  }

  void _onConnectionStateChange(ConnectionState state) {
    setState(() {
      _connState = state;
      switch (state) {
        case ConnectionState.connected:
          _statusMessage = 'Connected as ${widget.role}';
          _startStatsMonitoring();
          // Wire up remote video when it arrives
          _wireRemoteVideo();
          break;
        case ConnectionState.error:
          _statusMessage = 'Connection error';
          break;
        case ConnectionState.connecting:
          _statusMessage = 'Connecting...';
          break;
        case ConnectionState.disconnected:
          _statusMessage = 'Disconnected';
          _statsTimer?.cancel();
          break;
        case ConnectionState.disconnectedLocal:
          _statusMessage = 'Disconnected by user';
          _statsTimer?.cancel();
          break;
      }
    });
  }

  void _wireRemoteVideo([MediaStream? stream]) {
    if (!mounted) return;
    final s = stream ?? _connectionManager.remoteStream;
    if (s != null && _remoteRenderer.srcObject != s) {
      final tracks = s.getTracks();
      print('Viewer: wiring remote video — stream=${s.id}, '
          'tracks=${tracks.length}, '
          'rendererInitialized=${_remoteRenderer.textureId != null}, '
          'videoSize=${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}');
      for (final t in tracks) {
        print('  track: kind=${t.kind}, enabled=${t.enabled}, muted=${t.muted}');
      }
      if (_remoteRenderer.textureId == null) {
        print('Viewer: WARNING — renderer not initialized, deferring');
        Future.delayed(const Duration(milliseconds: 200), () => _wireRemoteVideo(s));
        return;
      }
      _remoteRenderer.srcObject = s;
      // DEBUG: fires when the first decoded frame actually reaches the renderer.
      _remoteRenderer.onFirstFrameRendered = () {
        print('Viewer: FIRST FRAME RENDERED — '
            'videoSize=${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}');
        if (mounted) setState(() {}); // re-layout to the real aspect ratio
      };
      // DEBUG: track mute tells us if the remote stopped sending media.
      for (final t in tracks) {
        t.onMute = () => print('Viewer: track MUTED — kind=${t.kind}');
      }
      Future.delayed(const Duration(milliseconds: 500), () {
        print('Viewer: after bind — videoSize='
            '${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}, '
            'trackCount=${tracks.length}, '
            'anyMuted=${tracks.any((t) => t.muted ?? false)}');
      });
      setState(() {});
    }
  }

  void _wireLocalVideo([MediaStream? stream]) {
    if (!mounted) return;
    final s = stream ?? _connectionManager.localStream;
    if (s != null && _localRenderer.srcObject != s) {
      final tracks = s.getTracks();
      print('Controller: wiring local video — stream=${s.id}, '
          'tracks=${tracks.length}, '
          'rendererInitialized=${_localRenderer.textureId != null}, '
          'videoSize=${_localRenderer.videoWidth}x${_localRenderer.videoHeight}');
      for (final t in tracks) {
        print('  track: kind=${t.kind}, enabled=${t.enabled}, muted=${t.muted}');
      }
      if (_localRenderer.textureId == null) {
        print('Controller: WARNING — renderer not initialized, deferring');
        Future.delayed(const Duration(milliseconds: 200), () => _wireLocalVideo(s));
        return;
      }
      _localRenderer.srcObject = s;
      // DEBUG: confirms the controller's own capture is producing frames.
      _localRenderer.onFirstFrameRendered = () {
        print('Controller: FIRST FRAME RENDERED (local preview) — '
            'videoSize=${_localRenderer.videoWidth}x${_localRenderer.videoHeight}');
        if (mounted) setState(() {}); // re-layout to the real aspect ratio
      };
      setState(() {});
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _errorMsg = null;
    });

    // Ensure renderers are initialized BEFORE connecting, so that
    // incoming video streams can be bound immediately.
    await _initRenderers();

    final success = await _connectionManager.connect(widget.userId);
    if (mounted) {
      setState(() {
        _isConnecting = false;
        if (!success) {
          _errorMsg = 'Connection failed. Check server URL and network.';
        }
      });
    }
  }

  void _startStatsMonitoring() {
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      // Try to wire remote/local video if it arrived asynchronously
      _wireRemoteVideo();
      _wireLocalVideo();
      setState(() {
        _fps = 30;
        _latency = 50;
      });
    });
  }

  void _disconnect() {
    _connectionManager.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  /// Stop sharing (controller) and return to the connect screen.
  void _stopSharing() {
    _disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final isController = widget.role == 'controller';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildStatusBar(),
            Expanded(child: _buildMainContent(isController)),
            _buildToolbar(isController),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: _getStatusColor().withOpacity(0.85),
      child: Row(children: [
        _connectionDot(),
        const SizedBox(width: 8),
        Expanded(child: Text(_statusMessage ?? 'Initializing...',
          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500))),
        if (_connState == ConnectionState.connected) ...[
          Text('$_fps fps  $_latency ms',
            style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(width: 16),
        ],
        IconButton(icon: const Icon(Icons.logout_rounded, size: 18),
          onPressed: _disconnect, tooltip: 'Disconnect', color: Colors.white70),
      ]),
    );
  }

  Widget _buildMainContent(bool isController) {
    if (_isConnecting) return const Center(child: CircularProgressIndicator());
    if (_errorMsg != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 48, color: Colors.orange),
          const SizedBox(height: 16),
          Text(_errorMsg!, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.white70)),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _connect, child: const Text('Retry')),
        ],
      )));
    }
    return isController ? _buildControllerView() : _buildViewerView();
  }

  Widget _buildControllerView() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 96, height: 96,
        decoration: BoxDecoration(color: Colors.deepPurple.withOpacity(0.2), shape: BoxShape.circle),
        child: Icon(Icons.screen_share_rounded, size: 48, color: Colors.deepPurple[200])),
      const SizedBox(height: 24),
      const Text('Screen Sharing Active',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.white)),
      const SizedBox(height: 8),
      Text('Others can view your screen via ${widget.roomId}',
        style: const TextStyle(fontSize: 13, color: Colors.white54)),
      const SizedBox(height: 16),
      // Local preview so the controller can confirm the screen is being captured.
      // Sized to the captured display's aspect ratio (handles portrait too).
      _fitVideoBox(_localRenderer, 640, 360),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        onPressed: _stopSharing,
        icon: const Icon(Icons.stop_circle_outlined, size: 16),
        label: const Text('Stop Sharing'),
        style: ElevatedButton.styleFrom(foregroundColor: Colors.red[300]),
      ),
    ]));
  }

  Widget _buildViewerView() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      // Sized to the remote display's aspect ratio so portrait sources show
      // tall instead of being squished into a 16:9 box.
      _fitVideoBox(_remoteRenderer, 640, 360),
      const SizedBox(height: 16),
      Text('Watching: ${widget.userId}  |  '
          'renderer: ${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}  |  '
          'srcObject: ${_remoteRenderer.srcObject?.id ?? "null"}',
        style: const TextStyle(fontSize: 11, color: Colors.white38)),
    ]));
  }

  /// Render a video surface sized to its real aspect ratio, fitting inside a
  /// max box. This keeps portrait/landscape displays undistorted. The inner
  /// RTCVideoView uses Fill because the surrounding box already matches the
  /// video's aspect ratio.
  Widget _fitVideoBox(RTCVideoRenderer renderer, double maxW, double maxH) {
    final vw = renderer.videoWidth;
    final vh = renderer.videoHeight;
    final hasSize = vw > 0 && vh > 0;
    double w = maxW, h = maxH;
    if (hasSize) {
      final ar = vw / vh;
      w = maxW;
      h = w / ar;
      if (h > maxH) {
        h = maxH;
        w = h * ar;
      }
    }
    return ClipRRect(borderRadius: BorderRadius.circular(12), child: Container(
      width: w,
      height: h,
      color: hasSize ? Colors.blue[900] : Colors.grey[850],
      child: Stack(alignment: Alignment.center, children: [
        RTCVideoView(renderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitFill,
          mirror: false),
        if (!hasSize)
          const Text('Waiting for video frames...',
            style: TextStyle(color: Colors.yellowAccent, fontSize: 14)),
      ]),
    ));
  }

  Widget _buildToolbar(bool isController) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.black.withOpacity(0.6),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: const Icon(Icons.fullscreen_rounded, size: 20),
          onPressed: () {}, tooltip: 'Fullscreen', color: Colors.white70),
        IconButton(icon: const Icon(Icons.tune_rounded, size: 20),
          onPressed: () {}, tooltip: 'Settings', color: Colors.white70),
        if (!isController)
          IconButton(icon: const Icon(Icons.keyboard_rounded, size: 20),
            onPressed: () {}, tooltip: 'Keyboard', color: Colors.white70),
        const SizedBox(width: 12),
        Text(widget.roomId, style: const TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 1.2)),
      ]),
    );
  }

  Color _getStatusColor() {
    switch (_connState) {
      case ConnectionState.connected: return Colors.green.shade900;
      case ConnectionState.error: return Colors.red.shade900;
      case ConnectionState.disconnected:
      case ConnectionState.disconnectedLocal: return Colors.grey.shade900;
      case ConnectionState.connecting: return Colors.orange.shade900;
    }
  }

  Widget _connectionDot() {
    return Container(width: 8, height: 8,
      decoration: BoxDecoration(
        color: _connState == ConnectionState.connected ? Colors.green : Colors.orange,
        shape: BoxShape.circle));
  }
}
