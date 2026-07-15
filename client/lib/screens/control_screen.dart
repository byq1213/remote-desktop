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
    _initRenderers();

    _connectionManager = ConnectionManager(
      room: Room(id: widget.roomId, role: widget.role),
      serverBaseUrl: widget.serverBaseUrl,
      token: widget.token,
    );
    _connectionManager.addStateListener(_onConnectionStateChange);
    _connect();
  }

  Future<void> _initRenderers() async {
    await _remoteRenderer.initialize();
    await _localRenderer.initialize();
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

  void _wireRemoteVideo() {
    final stream = _connectionManager.remoteStream;
    if (stream != null && _remoteRenderer.srcObject != stream) {
      _remoteRenderer.srcObject = stream;
      print('Viewer: remote video renderer bound');
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _errorMsg = null;
    });

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
      // Try to wire remote video if it arrived asynchronously
      _wireRemoteVideo();
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
      const SizedBox(height: 32),
      OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.stop_circle_outlined, size: 16),
        label: const Text('Stop Sharing'),
        style: OutlinedButton.styleFrom(foregroundColor: Colors.red[300]),
      ),
    ]));
  }

  Widget _buildViewerView() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      ClipRRect(borderRadius: BorderRadius.circular(12), child: Container(
        width: 640, height: 360, color: Colors.grey[850],
        child: RTCVideoView(_remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          mirror: false)),
      ),
      const SizedBox(height: 16),
      Text('Watching: ${widget.userId}',
        style: const TextStyle(fontSize: 13, color: Colors.white54)),
    ]));
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
