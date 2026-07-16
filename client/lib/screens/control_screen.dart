/// Main control screen — shows remote screen display and overlay controls.
library;

import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent, KeyUpEvent;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:window_manager/window_manager.dart';

import '../models/connection_manager.dart';
import '../models/room.dart';
import 'connect_screen.dart';

class ControlScreen extends StatefulWidget {
  final String userId;
  final String roomId;
  final String role;
  final String serverBaseUrl; // e.g. http://localhost:3000
  final String token;         // pre-obtained JWT from connect_screen
  final String? screenSourceId; // macOS display id to share (null = auto-pick)

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
  Timer? _statsTimer;
  String? _errorMsg;

  bool _isFullscreen = false;
  bool _leaving = false;
  bool _controlEnabled = true; // viewer → controller remote input on/off
  int _lastButton = 0;         // last pressed mouse button (for up events)
  Size _remoteBoxSize = const Size(640, 360); // actual on-screen remote video box
  bool _localFirstFrame = false;  // controller raw capture painted a frame
  bool _localPreviewReady = false; // stride-safe loopback preview is bound
  String? _lastLocalStreamId;      // for diagnosing renderer srcObject swap
  bool _remoteFirstFrame = false; // viewer received & painted a remote frame
  bool _isRemoteMuted = false;    // remote video track reported muted
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
    _inputFocus.dispose();
    _connectionManager.dispose();
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    super.dispose();
  }

  void _onConnectionStateChange(ConnectionState state) {
    if (_leaving) return; // we've already navigated away / are leaving
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
    if (!mounted || _leaving) return;
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
      // Fires when the first decoded frame actually reaches the renderer.
      _remoteRenderer.onFirstFrameRendered = () {
        print('Viewer: FIRST FRAME RENDERED — '
            'videoSize=${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}');
        if (mounted && !_leaving) {
          _remoteFirstFrame = true;
          setState(() {}); // re-layout to the real aspect ratio
        }
      };
      // Track mute tells us if the remote stopped sending media — surface it
      // in the HUD so a blank surface can be distinguished from a blue source.
      for (final t in tracks) {
        t.onMute = () {
          print('Viewer: track MUTED — kind=${t.kind}');
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
    if (!mounted || _leaving) return;
    final s = stream ?? _connectionManager.localStream;
    if (s != null && _localRenderer.srcObject != s) {
      final tracks = s.getTracks();
      final swapped = s.id != _lastLocalStreamId;
      print('Controller: wiring local video — stream=${s.id}, '
          'tracks=${tracks.length}, '
          'rendererInitialized=${_localRenderer.textureId != null}, '
          'videoSize=${_localRenderer.videoWidth}x${_localRenderer.videoHeight}'
          '${_lastLocalStreamId != null ? ' (renderer swap=${swapped ? "YES" : "NO!"})' : ""}');
      _lastLocalStreamId = s.id;
      for (final t in tracks) {
        print('  track: kind=${t.kind}, enabled=${t.enabled}, muted=${t.muted}');
      }
      if (_localRenderer.textureId == null) {
        print('Controller: WARNING — renderer not initialized, deferring');
        Future.delayed(const Duration(milliseconds: 200), () => _wireLocalVideo(s));
        return;
      }
      _localRenderer.srcObject = s;
      // Confirms the controller's own capture is producing frames.
      _localRenderer.onFirstFrameRendered = () {
        print('Controller: FIRST FRAME RENDERED (local preview) — '
            'videoSize=${_localRenderer.videoWidth}x${_localRenderer.videoHeight}');
        if (mounted && !_leaving) {
          _localFirstFrame = true;
          // The raw renderer's first frame reports the TRUE capture size
          // (e.g. 2940x1912). On macOS getSettings() returns 0x0 and the
          // display DPR is unreliable, so this is the only trustworthy size.
          // Drive the 64-aligned encoder scale AND the stride-safe loopback
          // preview from it.
          final rw = _localRenderer.videoWidth;
          final rh = _localRenderer.videoHeight;
          if (rw > 0 && rh > 0) {
            _connectionManager.applyRealCaptureSize(rw, rh);
          }
          setState(() {}); // re-layout to the real aspect ratio
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
      if (_leaving) return;
      // Try to wire remote/local video if it arrived asynchronously
      _wireRemoteVideo();
      _wireLocalVideo();
      setState(() {
        _fps = 30;
        _latency = 50;
      });
    });
  }

  /// Disconnect and return to the connect screen (instead of popping into a
  /// black void — ControlScreen was pushReplaced, so there is no route below).
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

  /// Stop sharing (controller) and return to the connect screen.
  void _stopSharing() {
    _disconnect();
  }

  /// Toggle macOS window full screen via window_manager.
  Future<void> _toggleFullscreen() async {
    await WindowManager.instance.ensureInitialized();
    final fs = await WindowManager.instance.isFullScreen();
    await WindowManager.instance.setFullScreen(!fs);
    if (mounted) setState(() => _isFullscreen = !fs);
  }

  /// Normalize a local pointer position (relative to the video box) to [0..1]
  /// so it is resolution-independent for the controller's screen.
  Offset _normalize(Offset local) {
    final size = _remoteBoxSize;
    final dx = size.width > 0 ? (local.dx / size.width).clamp(0.0, 1.0) : 0.0;
    final dy = size.height > 0 ? (local.dy / size.height).clamp(0.0, 1.0) : 0.0;
    return Offset(dx, dy);
  }

  /// Map a Flutter pointer button bitmask to a compact index (0 left / 1 right / 2 middle).
  int _buttonIndex(int buttons) {
    if (buttons & 0x2 != 0) return 1; // secondary / right
    if (buttons & 0x4 != 0) return 2; // tertiary / middle
    return 0;                         // primary / left (default)
  }

  /// Capture keyboard events and forward the native key code (USB HID usage)
  /// to the controller, which replays it on its local machine.
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
    return Scaffold(
      backgroundColor: Colors.black,
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Container(width: 96, height: 96,
          decoration: BoxDecoration(color: Colors.deepPurple.withOpacity(0.2), shape: BoxShape.circle),
          child: Icon(Icons.screen_share_rounded, size: 48, color: Colors.deepPurple[200])),
        const SizedBox(height: 16),
        const Text('Screen Sharing Active',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.white)),
        const SizedBox(height: 8),
        Text('Others can view your screen via ${widget.roomId}',
          style: const TextStyle(fontSize: 13, color: Colors.white54)),
        const SizedBox(height: 16),
        // Local preview fills the *remaining* space via Expanded + inner
        // LayoutBuilder, so it can never overflow regardless of the fixed
        // chrome above/below. The earlier fixed 160px reserve was too small
        // and produced "BOTTOM OVERFLOWED BY 85 PIXELS".
        Expanded(child: LayoutBuilder(builder: (context, constraints) {
          return Center(child: _fitVideoBox(
            _localRenderer, constraints.maxWidth, constraints.maxHeight,
            firstFrame: _localPreviewReady));
        })),
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
        // Video fills the remaining space (Expanded + inner LayoutBuilder),
        // so the HUD text below can never push content off-screen.
        Expanded(child: LayoutBuilder(builder: (context, constraints) {
          return Center(child: _buildVideoWithInput(_fitVideoBox(
            _remoteRenderer, constraints.maxWidth, constraints.maxHeight,
            firstFrame: _remoteFirstFrame)));
        })),
        const SizedBox(height: 16),
        Text('Watching: ${widget.userId}  |  '
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

  /// Wrap the video surface so the viewer can drive the remote machine.
  /// Only the viewer role forwards input (the server also enforces this).
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
          _connectionManager.sendInputMouse('wheel', 0, 0,
              delta: e.scrollDelta.dy);
        }
      },
      child: video,
    );
  }

  /// Render a video surface sized to its real aspect ratio, fitting inside a
  /// max box. The inner RTCVideoView uses Cover because the surrounding box
  /// already matches the video's aspect ratio.
  ///
  /// [firstFrame] is true once the renderer has actually painted a frame;
  /// while waiting we show an explicit overlay so a *blank* surface is never
  /// mistaken for "working but blue". The overlay ignores pointer events so
  /// the viewer can still drive the remote machine while waiting.
  Widget _fitVideoBox(RTCVideoRenderer renderer, double maxW, double maxH,
      {bool firstFrame = false}) {
    final size = _videoBoxSize(renderer, maxW, maxH);
    if (identical(renderer, _remoteRenderer)) _remoteBoxSize = size;
    // IMPORTANT: gate on the *real* video dimensions, not the box size
    // (which is always > 0). The old code keyed `hasSize` off the box, so the
    // container was permanently blue and the "waiting" hint never appeared.
    final hasVideo = renderer.videoWidth > 0 && renderer.videoHeight > 0;
    final waiting = !hasVideo || !firstFrame;
    return ClipRRect(borderRadius: BorderRadius.circular(12), child: Container(
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
                style: const TextStyle(color: Colors.yellowAccent, fontSize: 14)),
            ),
          ),
      ]),
    ));
  }

  /// Compute the fit box size for [renderer] inside a [maxW]x[maxH] area,
  /// preserving the real aspect ratio (portrait-aware).
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
      color: Colors.black.withOpacity(0.6),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: Icon(_isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, size: 20),
          onPressed: _toggleFullscreen, tooltip: 'Fullscreen', color: Colors.white70),
        IconButton(icon: const Icon(Icons.tune_rounded, size: 20),
          onPressed: () {}, tooltip: 'Settings', color: Colors.white70),
        if (!isController)
          IconButton(icon: Icon(_controlEnabled ? Icons.keyboard_rounded : Icons.keyboard_alt_rounded, size: 20),
            onPressed: () => setState(() => _controlEnabled = !_controlEnabled),
            tooltip: _controlEnabled ? 'Remote control: ON' : 'Remote control: OFF',
            color: _controlEnabled ? Colors.greenAccent : Colors.white70),
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
