# Remote Desktop System — Architecture Design

## 1. System Overview

A remote desktop control system built with:

- **Client (Controller)**: Flutter Desktop — captures local screen, sends mouse/keyboard events
- **Viewer**: Flutter Desktop or Browser — receives and displays remote screen, sends control commands
- **Server**: Node.js — relays WebRTC signaling and control commands; it does **not** route media (no SFU)

```
┌──────────────────────────────────────────────────────────────┐
│                   Controller Client                          │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐  │
│  │  Screen     │  │  Mouse/      │  │  WebRTC             │  │
│  │  Capture    │  │  Keyboard    │  │  PeerConnection     │  │
│  │  Plugin     │◄─┤  Event       │◄─┤  (Media Out)        │  │
│  └─────────────┘  └──────────────┘  └──────────┬──────────┘  │
│                                                 │ RtpSender   │
└─────────────────────────────────────────────────┼─────────────┘
                                                  │ WebRTC Media (P2P)
                                                  │
                                  ┌───────────────┴───────────────┐
                                  ▼                               │
┌─────────────────────────────────────────────────┐             │
│  Server (Node.js — signaling relay only)         │             │
│  - WS Endpoint (no path pin)                     │             │
│  - Auth/JWT (verifyToken)                        │             │
│  - Signaling relay (OFFER/ANSWER/ICE)            │             │
│  - Control relay (MOUSE_EVENT/KEY_EVENT)         │             │
│  - Room = 1 controller + 1 viewer                │             │
└─────────────────────────────────────────────────┘             │
                                  ▲                               │
                                  │ WebSocket Signal / Control   │
                                  └───────────────┬───────────────┘
                                                  │
┌──────────────────────────────────────────────────────────────┐
│                   Viewer Client                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  WebRTC PeerConnection ──► Decoder ──► RTCVideoView  │     │
│  │  Mouse/Keyboard Events ──► Signal WS ──► Server      │     │
│  └─────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

## 2. Data Flow

### 2.1 Screen Capture → Display (Forward Path)

```
Controller Screen
    │
    ├─ [Step 1] Native Plugin Captures Frame (AVFoundation / DXGI / X11)
    │
    ├─ [Step 2] Encode to VP8/VP9 (GStreamer + ffmpeg)
    │
    ├─ [Step 3] RtpSender carries the encoded frame over the P2P PeerConnection
    │
    ├─ [Step 4] (No media server) — RTP flows directly controller → viewer
    │
    ├─ [Step 5] Viewer PeerConnection receives RTP
    │
    └─ [Step 6] Decoder → Flutter Image → Canvas Render
```

### 2.2 Control Command → Execution (Reverse Path)

```
Viewer Mouse Click
    │
    ├─ [Step 1] Collect (x, y, button, key) at ~60Hz
    │
    ├─ [Step 2] Serialize to JSON, send via WebSocket
    │
    ├─ [Step 3] Server validates JWT, resolves target room
    │
    ├─ [Step 4] Relay to Controller's WebSocket handler
    │
    └─ [Step 5] Controller dispatches to native input injection (CGEvent / Windows.Input)
```

## 3. Module Design

### 3.1 Server Modules

#### `signal-server.js` — WebSocket Signaling / Control Relay
- **Responsibility**: Authenticate peers (JWT), relay signaling messages, relay control commands, manage room lifecycle. **No media handling.**
- **Protocols** (see `client/lib/signal/protocol.dart` for the canonical constants):
  - `JOIN_ROOM` — peer joins a room, gets `ROOM_JOINED` (with existing peers)
  - `OFFER` — controller offers SDP, relayed to the viewer (`to`)
  - `ANSWER` — viewer answers SDP, relayed to the controller (`to`)
  - `ICE_CANDIDATE` — ICE candidate relay
  - `MOUSE_EVENT` / `KEY_EVENT` — control commands, relayed to the controller
  - `PEER_JOINED` / `PEER_LEFT` — room membership notifications
  - `AUTH_ERROR` — auth/room-mismatch errors
  - `LEAVE_ROOM` — cleanup
- **Security**: JWT `verifyToken` on join, per-room token scope, role-checked control relay (only viewers may send control)

#### `auth.js` — Authentication
- **Strategy**: JWT with room-specific audience
- **Token Format**:
  ```json
  {
    "userId": "uuid-v4",
    "roomId": "room-12345",
    "role": "controller" | "viewer",
    "exp": 1720000000
  }
  ```

### 3.2 Client Modules

#### `lib/webrtc/peer_manager.dart` — WebRTC Lifecycle
- Manages `RTCPeerConnection` creation, track management, ICE handling
- Real stats via `getStats()` (FPS, RTT, packets lost) for the HUD
- Reconnection: driven by `SignalClient` exponential backoff (max 6 attempts)

```dart
class PeerManager {
  RTCPeerConnection _pc;
  StreamSubscription<RTCPacket> _mediaStream;
  
  Future<void> initialize() async {
    _pc = await createPeerConnection(config);
    _pc.onIceConnectionStateChanged = _onIceStateChange;
    _pc.onTrack = _onRemoteTrack;
  }
  
  Future<void> sendOffer(Descriptor sdp) async {
    await _pc.setLocalDescription(sdp);
    await signalServer.send('OFFER', sdp);
  }
}
```

#### `lib/webrtc/screen_capture.dart` — Screen Capture
- **macOS**: Uses `screen_capture` plugin with AVFoundation
- **Windows**: Uses `windows_desktop_capture` with DXGI desktop duplication
- Captures at 1080p, 30fps, VP8 encoded

```dart
class ScreenCapture {
  static const _targetFps = 30;
  static const _targetBitrate = 2_500_000; // 2.5 Mbps for 1080p
  
  Future<void> start(PeerManager peer) async {
    final frames = await ScreenCapturePlugin.start();
    frames.where((f) => f.format == VideoFrameFormat.vp8).forEach((frame) {
      peer.addTrack(frame);
    });
  }
}
```

#### `lib/input/input_controller.dart` — Remote Input Replay (controller side)
- Replays incoming `MOUSE_EVENT` / `KEY_EVENT` onto the local machine via `MethodChannel('remote_desktop/input')` → macOS `CGEvent`.
- Coordinate mapping: `[0..1]` payload × `localScreenSize` → pixel coords.
- Viewer-side capture is done directly in `control_screen.dart` (`Listener` for pointer, `Focus.onKeyEvent` for keyboard) and forwarded through `ConnectionManager.sendInputMouse` / `sendInputKey`.

```dart
class InputController {
  final bool isController;
  Size localScreenSize;

  void applyRemoteMouse(String action, double nx, double ny, int button, double delta) {
    if (!isController) return;
    final px = nx * localScreenSize.width;
    final py = ny * localScreenSize.height;
    _inputChannel.invokeMethod('mouse', {
      'action': action, 'x': px, 'y': py, 'button': button, 'delta': delta,
    });
  }
}
```

#### `lib/screens/control_screen.dart` — Main UI
- Displays remote screen via Flutter WebView or Image widget
- Overlay: connection status, FPS counter, latency ms
- Toolbar: disconnect, full-screen toggle, quality settings

## 4. Protocol Detail

### 4.1 WebRTC Negotiation Sequence

```
Controller ────JOIN_ROOM────► Server ◄────JOIN_ROOM──── Viewer
      │                          │                        │
      │  (controller starts screen capture)              │
      │                          │                        │
      │  ────OFFER (SDP)────────────────────────────────►│  (relayed by Server, to=viewer)
      │  ◄──ANSWER (SDP)─────────────────────────────────│
      │                          │                        │
      │◄─ICE CANDIDATES──────────┼────────ICE CANDIDATES─►│
      │                          │                        │
      │════ MEDIA FLOW (WebRTC P2P, direct) ══════════════│
      │                          │                        │
      │◄─MOUSE/KEY EVENT (relayed by Server)──────────────│  Viewer → Controller
```

### 4.2 WebSocket Message Schema

```typescript
interface SignalMessage {
  type: 'JOIN_ROOM' | 'LEAVE_ROOM' | 'OFFER' | 'ANSWER' |
        'ICE_CANDIDATE' | 'MOUSE_EVENT' | 'KEY_EVENT' |
        'ROOM_JOINED' | 'PEER_JOINED' | 'PEER_LEFT' | 'AUTH_ERROR';
  payload: Record<string, any>;
  roomId?: string;
  from?: string;
  to?: string;
}

// Example: Mouse Move Event
{
  "type": "MOUSE_EVENT",
  "payload": {
    "action": "move",
    "x": 1200,
    "y": 800,
    "screenRes": [1920, 1080]
  },
  "timestamp": 1720000000000
}
```

## 5. Error Handling & Recovery

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Network drop | ICE connection state changed to `disconnected` | SignalClient auto-reconnects with exponential backoff (max 6 attempts) |
| Screen capture crash | Native plugin throws | Restart capture with 1s backoff |
| Peer left / socket closed | Server relays `PEER_LEFT` or closes socket | UI shows disconnected; controller re-offers when viewer rejoins |
| High packet loss (>5%) | RTCP receiver report (`getStats`) | Lower encoder scale via `resolution.dart` |
| JWT expired / invalid | Server sends `AUTH_ERROR` | Show rejoin dialog / re-issue token |

## 6. Security Design

### 6.1 Transport Security
- All WebSocket connections use WSS (TLS 1.2+)
- WebRTC DTLS-SRTP encrypts all media by default

### 6.2 Authentication
- Controller and Viewer each get a JWT scoped to their room and role
- Token expiry: 1 hour for controllers, 15 minutes for viewers (shorter window)

### 6.3 Authorization
- Server validates role before relaying control commands
- Viewers cannot become controllers without re-authentication
- Optional: IP whitelist per room

### 6.4 Audit
- All join/leave events logged with timestamp, userId, IP
- Retention: 30 days

## 7. Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| End-to-end latency (LAN) | < 200ms | Time from controller screen refresh to viewer render |
| End-to-end latency (WAN) | < 500ms |同上, via TURN relay |
| Frame rate | 30 fps @ 1080p | Controller-side FPS counter |
| CPU usage (controller) | < 15% | macOS Activity Monitor |
| Bandwidth (controller → viewer) | 2-4 Mbps | WebRTC transport stats (getStats) |
| Control command latency | < 10ms | WebSocket round-trip time |

## 8. Tech Stack Summary

| Layer | Technology | Why |
|-------|-----------|-----|
| Client UI | Flutter 3.x (Desktop) | Cross-platform, hot reload, native plugin ecosystem |
| WebRTC Client | flutter-webrtc | Actively maintained, wraps libwebrtc |
| Screen Capture (macOS) | screen_capture plugin + AVFoundation | Built-in on macOS 10.15+ |
| Screen Capture (Windows) | windows_desktop_capture + DXGI | DirectX GPU-accelerated capture |
| Server Runtime | Node.js 20 LTS | Fits frontend background, quick iteration |
| Media | WebRTC P2P (libwebrtc) | Direct 1:1 peer connection — no media server to deploy |
| Signaling | ws (WebSocket) | Simple, reliable, built-in to Node ecosystem |
| Auth | jsonwebtoken (JWT) | Stateless, scalable, easy to debug |
| Config | dotenv + Zod schema | Type-safe config validation |
