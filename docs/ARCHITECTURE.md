# Remote Desktop System — Architecture Design

## 1. System Overview

A remote desktop control system built with:

- **Client (Controller)**: Flutter Desktop — captures local screen, sends mouse/keyboard events
- **Viewer**: Flutter Desktop or Browser — receives and displays remote screen, sends control commands
- **Server**: Node.js + mediasoup — handles WebRTC signaling, media routing, and control relay

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
                                                  │ WebRTC Media
                                                  │ WebSocket Signal
                                                  ▼
┌──────────────────────────────────────────────────────────────┐
│              Server (Node.js + mediasoup)                     │
│  ┌──────────────────────┐  ┌─────────────────────────────┐   │
│  │  Signal Router       │  │  Media Router (mediasoup)   │   │
│  │  - WS Endpoint       │  │  - Producer (Controller)    │   │
│  │  - Auth/JWT          │  │  - Consumers (Viewers)      │   │
│  │  - Control Relay     │  │  - Scalable Forwarding     │   │
│  │  - Room Management   │  │  - RTX/NACK Handling        │   │
│  └──────────────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
                                                  │
                                                  │ WebRTC Media
                                                  │ WebSocket Signal
                                                  ▼
┌──────────────────────────────────────────────────────────────┐
│                   Viewer Client                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  WebRTC PeerConnection ──► Decoder ──► Canvas/Image  │     │
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
    ├─ [Step 3] RtpSender → mediasoup Producer
    │
    ├─ [Step 4] mediasoup forwards RTP packets to all Consumers
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

#### `signal-server.js` — WebSocket Signaling Gateway
- **Responsibility**: Authenticate peers, route signaling messages, manage session lifecycle
- **Protocols**:
  - `JOIN_ROOM` — peer joins a room, gets room info
  - `OFFER` — controller offers SDP, forwarded to viewers
  - `ANSWER` — viewer answers SDP, forwarded to controller
  - `ICE_CANDIDATE` — ICE candidate relay
  - `CONTROL_CMD` — mouse/keyboard events relay
  - `LEAVE_ROOM` — cleanup resources
- **Security**: JWT verification middleware, rate limiting, per-room auth token

#### `mediasoup-handler.js` — Media Routing
- **Responsibility**: Manage mediasoup rooms, producers, consumers
- **Flow**:
  ```
  Controller JOIN → Create Producer → Router.produce()
  Viewer JOIN → Create Consumer → Router.consume()
  ```
- **Optimization**:
  - Simulcast for adaptive quality (low bandwidth → low bitrate layer)
  - RTX retransmission for lost keyframes
  - NACK for lost packets

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
- Reconnection logic: if connection drops for >5s, attempt reconnect up to 3 times

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

#### `lib/input/event_handler.dart` — Control Event Handler
- Captures mouse movement, clicks, keyboard input
- Debounces mouse movement at 60Hz (16ms interval)
- Serializes to compact JSON to minimize bandwidth

```dart
class EventHandler {
  static const _mouseIntervalMs = 16; // 60Hz
  
  void init() {
    _mouseStream = PlatformMouseStream().subscribe(debounce: _mouseIntervalMs);
    _keyStream = PlatformKeyStream().subscribe();
    
    _mouseStream.listen((event) {
      _signalServer.send('MOUSE_EVENT', {
        'type': event.type, // 'move' | 'down' | 'up'
        'x': event.x,
        'y': event.y,
        'button': event.button,
      });
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
Controller ────JOIN ROOM────► Server ◄────JOIN ROOM──── Viewer
      │                          │                        │
      │──── CREATE PRODUCER ──► │                        │
      │                          │                        │
      │  ────OFFER (SDP)────► Consumer ──ANSWER────► Server
      │                          │                        │
      │◄───ICE CANDIDATES────────│◄───ICE CANDIDATES─────│
      │                          │                        │
      │◄══════ MEDIA FLOW ══════│                        │
      │                          │                        │
      │─── MOUSE EVENT ──────────┼──────── CONTROL CMD ──►
```

### 4.2 WebSocket Message Schema

```typescript
interface SignalMessage {
  type: 'JOIN_ROOM' | 'LEAVE_ROOM' | 'OFFER' | 'ANSWER' | 
        'ICE_CANDIDATE' | 'MOUSE_EVENT' | 'KEY_EVENT' |
        'AUTH_ERROR' | 'ROOM_FULL';
  payload: Record<string, any>;
  timestamp?: number;
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
| Network drop | ICE connection state changed to `disconnected` | Auto-reconnect after 3s, max 3 attempts |
| Screen capture crash | Native plugin throws | Restart capture with 1s backoff |
| mediasoup room gone | Server sends `ROOM_FULL` or 404 | Show rejoin dialog |
| High packet loss (>5%) | RTCP receiver report | Drop to lower quality simulcast layer |
| JWT expired | Server sends 401 | Request refresh token from login screen |

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
| Bandwidth (controller → server) | 2-4 Mbps | mediasoup transport stats |
| Control command latency | < 10ms | WebSocket round-trip time |

## 8. Tech Stack Summary

| Layer | Technology | Why |
|-------|-----------|-----|
| Client UI | Flutter 3.x (Desktop) | Cross-platform, hot reload, native plugin ecosystem |
| WebRTC Client | flutter-webrtc | Actively maintained, wraps libwebrtc |
| Screen Capture (macOS) | screen_capture plugin + AVFoundation | Built-in on macOS 10.15+ |
| Screen Capture (Windows) | windows_desktop_capture + DXGI | DirectX GPU-accelerated capture |
| Server Runtime | Node.js 20 LTS | Fits frontend background, quick iteration |
| Media Server | mediasoup 3.x | SFU, simulcast, production-proven |
| Signaling | ws (WebSocket) | Simple, reliable, built-in to Node ecosystem |
| Auth | jsonwebtoken (JWT) | Stateless, scalable, easy to debug |
| Config | dotenv + Zod schema | Type-safe config validation |
