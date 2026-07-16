# Changelog

All notable changes to the Remote Desktop project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Viewer 远程控制（鼠标 / 键盘）**：打通输入全链路 — Viewer 端 `Listener`/`Focus` 捕获指针与键盘并归一化坐标 `[0..1]`，Controller 端 `ConnectionManager` 新增 `MOUSE_EVENT`/`KEY_EVENT` 处理并经 `MethodChannel('remote_desktop/input')` 调原生，macOS 端用 CoreGraphics `CGEvent` 回放（含 USB HID → keyCode 映射）；工具栏键盘图标可暂停/恢复控制。⚠️ 需授予「系统设置 → 隐私与安全性 → 辅助功能」权限，坐标按主显示器尺寸映射（共享非主屏会有偏差）。
- **本地预览 stride-safe 回环** (`peer_manager.dart`)：新增 `startLocalPreviewLoopback`，用一对额外 `RTCPeerConnection` 把原始采集帧重新编码/解码到 64 对齐尺寸，使 Controller 本地预览不再出现行步长错位；`ConnectionManager.applyRealCaptureSize` 在首帧拿到真实尺寸后启动回环，`localStream` 优先返回对齐后的预览流。

### Fixed

- **全屏按钮失效** (`control_screen.dart`)：原 `onPressed` 为空实现，现改用 `window_manager` 的 `setFullScreen` 真正切换 macOS 窗口全屏，视频框改 `LayoutBuilder` 填满可用区域以消除黑边。
- **退出 / 返回时黑屏** (`control_screen.dart`, `connect_screen.dart`)：根因为 `pushReplacement` 使导航栈仅剩 ControlScreen 导致 `pop` 失效且渲染器已 dispose；现先显示 "Disconnecting…" 占位页再返回 `ConnectScreen`，并为资源清理加幂等保护。
- **macOS 屏幕画面被横向拉歪 / 撕裂（stride 未对齐）** (`screen_capture.dart`, `peer_manager.dart`, `connection_manager.dart`, `control_screen.dart`)：根因为 macOS `getDisplayMedia` 返回的帧 `width×4` 不是 256 的整数倍（如 Retina 内屏 3024 → 12096，÷256=47.25），捕获与渲染器对行步长（row stride）理解不一致，导致本地预览与传输画面同时变形。现改用 `ScreenRetriever` 按显示器物理分辨率 ÷ DPR 计算**宽度为 64 对齐、高度为偶数**的采集尺寸（使 `width×4` 整除 256），并重写 `_scaleFor` 仅对宽度做 64 对齐、高度只要求偶数，配合 DPR 自适应预算把 Retina 缩到逻辑分辨率而非盲压到 1920；`control_screen` 首帧回调改走 `applyRealCaptureSize` 以真实尺寸重设编码缩放并启动 stride-safe 预览回环。
- **分辨率被错误压低（1080p 屏被降到 1024×576）** (`peer_manager.dart`)：旧逻辑强制高度 64 对齐并保留 2.0 兜底减半，使普通 1080/1200/1440 屏被无谓缩小。改为宽度仅按 64 block、高度只求偶数（VP8 色度采样所需），未知尺寸直接以原始 1.0 发送而非减半。

### Changed

- **适配 Flutter ≥ 3.18 API** (`event_handler.dart`, `connection_manager.dart`, `control_screen.dart`, `connect_screen.dart`, `flutter_webrtc`)：`MouseEvent`/`KeyEvent` 重命名为 `RemoteMouseEvent`/`RemoteKeyEvent` 避开冲突；屏幕尺寸 API 改为 `getPrimaryDisplay()`；键盘改用新版 `KeyEvent`/`KeyDownEvent`/`KeyUpEvent` + `Focus.onKeyEvent`，指针改用 `buttons` 位掩码与 `PointerScrollEvent`；`RTCVideoViewObjectFitFill` 改为 `RTCVideoViewObjectFitCover`；补充 `foundation` 导入以使用 `kDebugMode`。
- **自适应编码参数（码率 / 帧率）** (`peer_manager.dart`)：`_rescaleSenders` 现按输出像素 ~2.5 bits/px·s 估算码率并钳制在 `[2,16]` Mbps，显式设置 `maxBitrate` 与 `maxFramerate=30`，避免屏幕内容比摄像头更糊。
- **出图长边上限构建期可配** (`peer_manager.dart`, `connection_manager.dart`)：新增 `kDefaultTargetLongSide`（默认 2560），可通过 `--dart-define=TARGET_LONG_SIDE=<px>`（如 3840 投 4K）在编译期调整。

### Removed

- **技术文档沉淀与替换** (`docs/TECHNICAL_NOTES.md`)：删除早期 `docs/BUGFIX_WEBRTC_SCREENSHARE.md`，新增 `docs/TECHNICAL_NOTES.md` 系统记录 stride / DPR / 分辨率诊断过程与结论，并附 `截图/` 下对照图（扭曲、分辨率过低）。

### Known Issues

- **macOS 指定 sourceId 共享显示器时偶发仍忽略 64 对齐宽度**：当通过 `sourceId` 共享某块显示器时，原生层偶有忽略请求宽度、回退到原生分辨率，此时错位已烘焙进采集缓冲、无法在 Dart 层根治；其余场景已通过回环与 `_scaleFor` 规避。

## [1.0.0] - 2026-07-15

### Added

- 基于 WebRTC P2P 的远程桌面投屏 MVP：controller 端屏幕采集（getDisplayMedia）→ viewer 端观看。
- 信令服务（RawSocket 手写 WebSocket 握手/帧编解码，绕开 macOS URL 解析 bug）。
- VP8 优先以规避 macOS H.264 VideoToolbox 不稳定路径。
- 屏幕录制权限声明与可观测性增强。
