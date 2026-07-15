# Remote Desktop System

> A remote desktop control system built with Flutter Desktop + WebRTC (mediasoup SFU) + Node.js.
> A personal project exploring architecture design, tech selection, and rapid development.

## Architecture

```
Controller (Flutter) ──WebRTC──► mediasoup ──WebRTC──► Viewer (Flutter)
                                    ▲
                                    │
                              WebSocket (Signaling + Control)
```

- **Media**: WebRTC via mediasoup SFU (1:N broadcast)
- **Control**: WebSocket for signaling and mouse/keyboard events
- **Auth**: JWT with room-scoped tokens

## Quick Start

```bash
# Server
cd server
npm install
cp .env.example .env
npm run dev

# Client (Controller)
cd client
flutter pub get
flutter run -d macos

# Client (Viewer - second window)
flutter run -d macos --dart-define=MODE=viewer
```

See `docs/SETUP.md` for detailed environment setup instructions.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — System architecture, data flow, module design
- [`docs/TRADEOFFS.md`](docs/TRADEOFFS.md) — Tech selection tradeoffs and design rationale
- [`docs/SETUP.md`](docs/SETUP.md) — Environment setup guide

## Project Structure

```
remote-desktop/
├── client/               # Flutter Desktop
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/
│   │   │   ├── connect_screen.dart    # Login/join page
│   │   │   └── control_screen.dart    # Main view
│   │   ├── webrtc/
│   │   │   ├── peer_manager.dart      # WebRTC connection
│   │   │   └── screen_capture.dart    # Screen sharing
│   │   ├── signal/
│   │   │   └── signal_client.dart     # WebSocket client
│   │   ├── input/
│   │   │   └── event_handler.dart     # Mouse/keyboard input
│   │   └── models/
│   │       ├── config.dart            # App config (Provider)
│   │       ├── room.dart              # Room model
│   │       ├── peer.dart              # Peer model
│   │       └── connection_manager.dart # Core orchestrator
│   ├── pubspec.yaml
│   └── analysis_options.yaml
│
├── server/               # Node.js + mediasoup
│   ├── src/
│   │   ├── index.js               # Entry point
│   │   ├── signal-server.js       # WebSocket gateway
│   │   ├── mediasoup-handler.js   # Media routing
│   │   ├── auth.js                # JWT auth
│   │   └── utils/
│   │       ├── config.js          # Env config loader
│   │       └── logger.js          # Pino logger
│   ├── package.json
│   └── .env.example
│
└── docs/
    ├── ARCHITECTURE.md
    └── SETUP.md
```

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Client | Flutter Desktop | Cross-platform, fast iteration with hot reload |
| Server | Node.js | Leverages existing frontend skills, mediasoup native |
| Media | mediasoup SFU | 1:N broadcast, simulcast, production-proven |
| Codec | VP8 | Patent-free, hardware encoding on modern CPUs |
| Signaling | WebSocket | Simple, debuggable, low overhead for control |
| Auth | JWT | Stateless, room-scoped, easy to distribute |

## Performance Targets

| Metric | Target |
|--------|--------|
| LAN latency | < 200ms |
| WAN latency | < 500ms |
| Frame rate | 30fps @ 1080p |
| Control latency | < 10ms |
| Controller CPU | < 15% |

## License

MIT
