/// Main control screen — shows the remote screen and overlay controls.
library;

import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent, KeyUpEvent;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:window_manager/window_manager.dart';

import '../core/logger.dart';
import '../models/connection_manager.dart';
import '../models/room.dart';
import 'connect_screen.dart';

class ControlScreen extends StatefulWidget {
  final String userId;
  final String roomId;
  final String role;
  final String serverBaseUrl;
  final String token;
  final String? screenSourceId;

  const ControlScreen({
    super.key,
    required this.userId,
    required this.roomId,
    required this.role,
    required this.serverBaseUrl,
    required this.token,
    this.screenSourceId,
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
  int _packetsLost = 0;
  Timer? _statsTimer;
  String? _errorMsg;

  bool _isFullscreen = false;
  bool _leaving = false;
  bool _controlEnabled = true;
  int _lastButton = 0;
  Size _remoteBoxSize = const Size(640, 360);
  bool _localPreviewReady = false;
  String? _lastLocalStreamId;
  bool _remoteFirstFrame = false;
  bool _isRemoteMuted = false;
  final FocusNode _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _remoteRenderer = RTCVideoRenderer();
    _localRenderer = RTCVideoRenderer();
    _connectionManager = ConnectionManager(
      room: Room(id: widget.roomId, role: widget.role),
      serverBaseUrl: widget.serverBaseUrl,
      token: widget.token,
      screenSourceId: widget.screenSourceId,
    );
    _connectionManager.addStateListener(_onConnectionStateChange);
    _connectionManager.onRemoteStreamUpdated = _wireRemoteVideo;
    _connectionManager.onLocalStreamUpdated = _wireLocalVideo;
    _connectionManager.onLocalPreviewReady = (stream) {
      if (mounted && !_leaving) {
        _localPreviewReady = true;
        setState(() {});
      }
    };
    _connectionManager.onCaptureError =
        (msg) => setState(() => _statusMessage = msg);
    _connect();
  }

  Future<void> _initRenderers() async {
    await _remoteRenderer.initialize();
    await _localRenderer.initialize();
    log.d('Renderers initialized: '
        'remote=${_remoteRenderer.textureId}, local=${_localRenderer.textureId}');
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _inputFocus.dispose();
    _connectionManager.dispose();
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    super.dispose();
  }

  void _onConnectionStateChange(ConnectionState state) {
    if (_leaving) return;
    setState(() {
      _connState = state;
      switch (state) {
        case ConnectionState.connected:
          _statusMessage = 'Connected as ${widget.role}';
          _startStatsMonitoring();
          _wireRemoteVideo();
          break;
        case ConnectionState.error:
          _statusMessage = 'Connection error';
          break;
        case ConnectionState.connecting:
          _statusMessage = 'Connecting…';
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
    if (!mounted || _leaving) return;
    final s = stream ?? _connectionManager.remoteStream;
    if (s != null && _remoteRenderer.srcObject != s) {
      final tracks = s.getTracks();
      log.d('Viewer: wiring remote video — stream=${s.id}, tracks=${tracks.length}');
      if (_remoteRenderer.textureId == null) {
        Future.delayed(const Duration(milliseconds: 200), () => _wireRemoteVideo(s));
        return;
      }
      _remoteRenderer.srcObject = s;
      _remoteRenderer.onFirstFrameRendered = () {
        log.d('Viewer: FIRST FRAME RENDERED — '
            '${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}');
        if (mounted && !_leaving) {
          _remoteFirstFrame = true;
          setState(() {});
        }
      };
      for (final t in tracks) {
        t.onMute = () {
          if (mounted && !_leaving) {
            _isRemoteMuted = true;
            setState(() {});
          }
        };
        t.onUnMute = () {
          if (mounted && !_leaving) {
            _isRemoteMuted = false;
            setState(() {});
          }
        };
      }
      setState(() {});
    }
  }

  void _wireLocalVideo([MediaStream? stream]) {
    if (!mounted || _leaving) return;
    final s = stream ?? _connectionManager.localStream;
    if (s != null && _localRenderer.srcObject != s) {
      final tracks = s.getTracks();
      final swapped = s.id != _lastLocalStreamId;
      log.d('Controller: wiring local video — stream=${s.id}, tracks=${tracks.length}'
          '${_lastLocalStreamId != null ? ' (swap=${swapped ? "YES" : "NO"})' : ""}');
      _lastLocalStreamId = s.id;
      if (_localRenderer.textureId == null) {
        Future.delayed(const Duration(milliseconds: 200), () => _wireLocalVideo(s));
        return;
      }
      _localRenderer.srcObject = s;
      _localRenderer.onFirstFrameRendered = () {
        log.d('Controller: FIRST FRAME RENDERED (local) — '
            '${_localRenderer.videoWidth}x${_localRenderer.videoHeight}');
        if (mounted && !_leaving) {
          final rw = _localRenderer.videoWidth;
          final rh = _localRenderer.videoHeight;
          if (rw > 0 && rh > 0) {
            _connectionManager.applyRealCaptureSize(rw, rh);
          }
          setState(() {});
        }
      };
      setState(() {});
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _errorMsg = null;
    });
    await _initRenderers();
    final success = await _connectionManager.connect(widget.userId);
    if (mounted) {
      setState(() {
        _isConnecting = false;
        if (!success) {
          _errorMsg = 'Connection failed. Check the server URL and your network.';
        }
      });
    }
  }

  /// Poll real WebRTC stats (fps / RTT / packet loss) for the HUD.
  void _startStatsMonitoring() {
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_leaving) return;
      _wireRemoteVideo();
      _wireLocalVideo();
      final stats = await _connectionManager.getMediaStats();
      if (mounted && !_leaving) {
        setState(() {
          _fps = stats.fps.round();
          _latency = stats.rttMs.round();
          _packetsLost = stats.packetsLost;
        });
      }
    });
  }

  Future<void> _disconnect() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    _connectionManager.disconnect();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ConnectScreen()),
      );
    }
  }

  void _stopSharing() => _disconnect();

  Future<void> _toggleFullscreen() async {
    await WindowManager.instance.ensureInitialized();
    final fs = await WindowManager.instance.isFullScreen();
    await WindowManager.instance.setFullScreen(!fs);
    if (mounted) setState(() => _isFullscreen = !fs);
  }

  Offset _normalize(Offset local) {
    final size = _remoteBoxSize;
    final dx = size.width > 0 ? (local.dx / size.width).clamp(0.0, 1.0) : 0.0;
    final dy = size.height > 0 ? (local.dy / size.height).clamp(0.0, 1.0) : 0.0;
    return Offset(dx, dy);
  }

  int _buttonIndex(int buttons) {
    if (buttons & 0x2 != 0) return 1;
    if (buttons & 0x4 != 0) return 2;
    return 0;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_controlEnabled || widget.role != 'viewer') return KeyEventResult.ignored;
    final keyCode = event.physicalKey.usbHidUsage & 0xFFFF;
    if (event is KeyDownEvent) {
      _connectionManager.sendInputKey('down', keyCode);
      return KeyEventResult.handled;
    } else if (event is KeyUpEvent) {
      _connectionManager.sendInputKey('up', keyCode);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_leaving) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final isController = widget.role == 'controller';
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Focus(
          focusNode: _inputFocus,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Column(
            children: [
              _buildStatusBar(),
              Expanded(child: _buildMainContent(isController)),
              _buildToolbar(isController),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: _getStatusColor().withValues(alpha: 0.85),
      child: Row(children: [
        _connectionDot(),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_statusMessage ?? 'Initializing…',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
        ),
        if (_connState == ConnectionState.connected) ...[
          Text(
              '$_fps fps  $_latency ms'
              '${_packetsLost > 0 ? '  $_packetsLost lost' : ''}',
              style: const TextStyle(
                  color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(width: 16),
        ],
        IconButton(
          icon: const Icon(Icons.logout_rounded, size: 18),
          onPressed: _disconnect,
          tooltip: 'Disconnect',
          color: Colors.white70,
        ),
      ]),
    );
  }

  Widget _buildMainContent(bool isController) {
    if (_isConnecting) return const Center(child: CircularProgressIndicator());
    if (_errorMsg != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(_errorMsg!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.white70)),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _connect, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    return isController ? _buildControllerView() : _buildViewerView();
  }

  Widget _buildControllerView() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.2), shape: BoxShape.circle),
          child: Icon(Icons.screen_share_rounded,
              size: 48, color: scheme.primary.withValues(alpha: 0.8)),
        ),
        const SizedBox(height: 16),
        const Text('Screen Sharing Active',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.white)),
        const SizedBox(height: 8),
        Text('Others can view your screen via ${widget.roomId}',
            style: const TextStyle(fontSize: 13, color: Colors.white54)),
        const SizedBox(height: 16),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            return Center(
              child: _fitVideoBox(_localRenderer, constraints.maxWidth,
                  constraints.maxHeight,
                  firstFrame: _localPreviewReady),
            );
          }),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _stopSharing,
          icon: const Icon(Icons.stop_circle_outlined, size: 16),
          label: const Text('Stop Sharing'),
          style: ElevatedButton.styleFrom(foregroundColor: Colors.red[300]),
        ),
      ]),
    );
  }

  Widget _buildViewerView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            return Center(
              child: _buildVideoWithInput(_fitVideoBox(
                _remoteRenderer,
                constraints.maxWidth,
                constraints.maxHeight,
                firstFrame: _remoteFirstFrame,
              )),
            );
          }),
        ),
        const SizedBox(height: 16),
        Text(
            'Watching: ${widget.userId}  |  '
            'renderer: ${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}  |  '
            '${_remoteFirstFrame ? "frames OK" : "no frames yet"}'
            '${_isRemoteMuted ? "  |  TRACK MUTED" : ""}',
            style: const TextStyle(fontSize: 11, color: Colors.white38)),
        if (!_controlEnabled)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Remote control paused — tap the keyboard icon to resume',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          ),
      ]),
    );
  }

  Widget _buildVideoWithInput(Widget video) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (!_controlEnabled || widget.role != 'viewer') return;
        final idx = _buttonIndex(e.buttons);
        _lastButton = idx;
        final p = _normalize(e.localPosition);
        _connectionManager.sendInputMouse('down', p.dx, p.dy, button: idx);
      },
      onPointerUp: (e) {
        if (!_controlEnabled || widget.role != 'viewer') return;
        final p = _normalize(e.localPosition);
        _connectionManager.sendInputMouse('up', p.dx, p.dy, button: _lastButton);
      },
      onPointerMove: (e) {
        if (!_controlEnabled || widget.role != 'viewer') return;
        final p = _normalize(e.localPosition);
        _connectionManager.sendInputMouse('move', p.dx, p.dy);
      },
      onPointerSignal: (e) {
        if (!_controlEnabled || widget.role != 'viewer') return;
        if (e is PointerScrollEvent) {
          _connectionManager.sendInputMouse('wheel', 0, 0, delta: e.scrollDelta.dy);
        }
      },
      child: video,
    );
  }

  Widget _fitVideoBox(RTCVideoRenderer renderer, double maxW, double maxH,
      {bool firstFrame = false}) {
    final size = _videoBoxSize(renderer, maxW, maxH);
    if (identical(renderer, _remoteRenderer)) _remoteBoxSize = size;
    final hasVideo = renderer.videoWidth > 0 && renderer.videoHeight > 0;
    final waiting = !hasVideo || !firstFrame;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: size.width,
        height: size.height,
        color: hasVideo ? Colors.black : Colors.grey[850],
        child: Stack(alignment: Alignment.center, children: [
          RTCVideoView(renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: false),
          if (waiting)
            IgnorePointer(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Text(
                  hasVideo ? 'Rendering first frame…' : 'Waiting for video frames…',
                  style: const TextStyle(color: Colors.yellowAccent, fontSize: 14),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Size _videoBoxSize(RTCVideoRenderer renderer, double maxW, double maxH) {
    final vw = renderer.videoWidth;
    final vh = renderer.videoHeight;
    if (vw > 0 && vh > 0) {
      final ar = vw / vh;
      var w = maxW;
      var h = w / ar;
      if (h > maxH) {
        h = maxH;
        w = h * ar;
      }
      return Size(w, h);
    }
    return Size(maxW, maxH);
  }

  Widget _buildToolbar(bool isController) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.black.withValues(alpha: 0.6),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
          icon: Icon(_isFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
              size: 20),
          onPressed: _toggleFullscreen,
          tooltip: 'Fullscreen',
          color: Colors.white70,
        ),
        if (!isController)
          IconButton(
            icon: Icon(_controlEnabled
                ? Icons.keyboard_rounded
                : Icons.keyboard_alt_rounded,
                size: 20),
            onPressed: () => setState(() => _controlEnabled = !_controlEnabled),
            tooltip: _controlEnabled ? 'Remote control: ON' : 'Remote control: OFF',
            color: _controlEnabled ? Colors.greenAccent : Colors.white70,
          ),
        const SizedBox(width: 12),
        Text(widget.roomId,
            style: const TextStyle(
                fontSize: 11, color: Colors.white38, letterSpacing: 1.2)),
      ]),
    );
  }

  Color _getStatusColor() {
    switch (_connState) {
      case ConnectionState.connected:
        return Colors.green.shade900;
      case ConnectionState.error:
        return Colors.red.shade900;
      case ConnectionState.disconnected:
      case ConnectionState.disconnectedLocal:
        return Colors.grey.shade900;
      case ConnectionState.connecting:
        return Colors.orange.shade900;
    }
  }

  Widget _connectionDot() {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: _connState == ConnectionState.connected
            ? Colors.green
            : Colors.orange,
        shape: BoxShape.circle,
      ),
    );
  }
}
