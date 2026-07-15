# Remote Desktop System — Setup Guide

> 本地开发环境快速搭建指南。目标是 `git clone` + `npm install` 之后一条命令跑起来。

---

## Prerequisites

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Flutter | 3.16+ | Client framework |
| Dart SDK | 3.2+ | Flutter depends on |
| Node.js | 20 LTS | Server runtime |
| npm | 10+ | Package manager |
| C++ Build Tools | Xcode CLT / Visual Studio Build Tools | mediasoup native bindings |
| Git | Latest | Version control |

### macOS Specific
```bash
# Install Xcode Command Line Tools
xcode-select --install

# Install Flutter (via brew or manual download)
brew install --cask flutter

# Enable desktop platforms
flutter config --enable-macos-desktop
flutter config --enable-windows-desktop  # if targeting Windows too

# Verify
flutter doctor
```

### Ubuntu/Linux Specific
```bash
# Install dependencies
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev \
  liblzma-dev libstdc++-12-dev

# Install Flutter
wget -qO- https://get.flutter.dev/install/linux | bash
export PATH="$PATH:$HOME/flutter/bin"
```

### Windows Specific
```powershell
# Install via winget
winget install --id Flutter.Flutter
winget install OpenJS.NodeJS.LTS

# Enable desktop
flutter config --enable-windows-desktop

# Verify
flutter doctor
```

---

## Project Structure

```
remote-desktop/
├── client/               # Flutter Desktop application
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/
│   │   ├── webrtc/
│   │   ├── input/
│   │   ├── signal/
│   │   └── models/
│   ├── pubspec.yaml
│   └── analysis_options.yaml
│
├── server/               # Node.js mediasoup server
│   ├── src/
│   │   ├── index.js
│   │   ├── signal-server.js
│   │   ├── mediasoup-handler.js
│   │   ├── auth.js
│   │   └── utils/
│   ├── package.json
│   └── .env.example
│
├── docker-compose.yml    # Optional: mediasoup + TURN in Docker
└── README.md
```

---

## Quick Start

### 1. Clone & Setup

```bash
git clone <your-repo-url>
cd remote-desktop

# Server
cd server && npm install && cp .env.example .env

# Client
cd ../client && flutter pub get
```

### 2. Environment Configuration

Create `server/.env`:
```env
PORT=3000
JWT_SECRET=your-secret-key-here
MEDiasoup_LOG_LEVEL=warning
MEDiasoup_LOG_ICONS=false
TURN_SERVER=turn:your-server.com:3478
TURN_USERNAME=remote-user
TURN_PASSWORD=secure-password
```

### 3. Start Server

```bash
cd server
npm run dev
# Starts on http://localhost:3000
```

Verify:
```bash
curl http://localhost:3000/health
# Expected: {"status":"ok","uptime":123}
```

### 4. Start Client (Controller Mode)

```bash
cd client
flutter run -d macos
# Or: flutter run -d windows / flutter run -d linux
```

First launch: Grant screen capture permission when macOS prompts.

### 5. Start Second Client (Viewer Mode)

Open a second terminal:
```bash
cd client
flutter run -d macos --dart-define=MODE=viewer
```

Enter the room code shown on Controller screen to join.

---

## Running in Production-like Mode

### Build for Release

```bash
# Server
cd server && npm run build && NODE_ENV=production npm start

# Client (macOS)
cd client && flutter build macos --release

# Client (Windows)
cd client && flutter build windows --release
```

### Docker (Optional)

```bash
# Starts mediasoup + coturn in Docker
docker compose up -d

# Points server to Docker media server
MEDIASOUP_LISTEN_IP=127.0.0.1 \
MEDIASOUP_announcedIp=your-external-ip \
npm run dev
```

---

## Troubleshooting

> macOS 客户端从装依赖到编译运行的完整排错（镜像、代码签名、Dart API 兼容等）见
> [MACOS_CLIENT_TROUBLESHOOTING.md](./MACOS_CLIENT_TROUBLESHOOTING.md)。

### Issue: `flutter pub get` socket error / 无法访问 pub.dev

国内网络直连 `https://pub.dev` 会失败，需配置镜像（详见上述排错文档第 0 节）：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

### Issue: `flutter-webrtc` compilation fails

```bash
# Clean and rebuild
cd ios && rm -rf Pods Podfile.lock && pod install && cd ..
flutter clean
flutter pub get
flutter build macos
```

### Issue: Screen capture permission denied (macOS)

1. Go to **System Settings → Privacy & Security → Screen Recording**
2. Add your IDE (JetBrains/VS Code) or the built app
3. Restart the app

### Issue: WebRTC ICE candidates not exchanging

```bash
# Check TURN server is reachable
nc -zv turn.your-server.com 3478

# Enable verbose logging on server
DEBUG=mediasoup:* npm run dev
```

### Issue: Viewer shows black screen

- Verify Controller has screen capture enabled (check tray icon or status bar)
- Check mediasoup producer state: `GET /api/rooms/:roomId/stats`
- Try lowering resolution: set `_targetBitrate` to 1Mbps in `screen_capture.dart`

### Issue: Mouse events not reaching Controller

- Check WebSocket connection: open DevTools in Viewer → Network tab → WS tab
- Verify `CONTROL_CMD` message is received by server
- Check Controller's input permissions (Accessibility on macOS)

---

## Testing

### Unit Tests (Client)

```bash
cd client
flutter test
flutter test test/webrtc/        # WebRTC specific tests
flutter test test/input/         # Input handler tests
```

### API Tests (Server)

```bash
cd server
npm test                          # Jest unit tests
npm run test:integration          # WebSocket + mediasoup integration
```

### Manual Smoke Test Checklist

- [ ] Controller captures screen and shows green bar in video
- [ ] Viewer joins room and sees Controller's screen
- [ ] Moving Controller's mouse doesn't affect Viewer (correct)
- [ ] Moving Viewer's mouse moves Controller's mouse (correct)
- [ ] Click on Viewer sends click to Controller (correct)
- [ ] Disconnect Controller → Viewer shows "Reconnecting..." → auto-reconnect works
- [ ] JWT expired → Viewer forced to re-login
