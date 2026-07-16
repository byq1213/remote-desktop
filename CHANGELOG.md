# Changelog

All notable changes to the Remote Desktop project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

#### Flutter 客户端体验问题修复

- **全屏按钮失效** (`client/lib/screens/control_screen.dart`)
  - 全屏按钮原本 `onPressed` 为空实现，点击无任何反应。
  - 现改用已依赖的 `window_manager` 实现真正的 macOS 窗口全屏切换（`setFullScreen`）。
  - 视频框从固定 `640×360` 改为 `LayoutBuilder` 填满可用区域，全屏时画面会真正放大而非留黑边。

- **退出 / 返回时黑屏** (`client/lib/screens/control_screen.dart`, `connect_screen.dart`)
  - 根因：`connect_screen` 用 `pushReplacement` 进入 `ControlScreen`，导航栈中**只剩 ControlScreen**；`_disconnect` 内 `Navigator.pop` 无处可弹，而 `disconnect()` 已 dispose 渲染器，于是停留在一个引用了已释放渲染器的黑屏页。
  - 现 `_disconnect` 先置 `_leaving` 标志显示 "Disconnecting…" 占位页，再 `pushReplacement` 返回 `ConnectScreen`；并给资源清理加幂等保护，避免重复 dispose。

- **Viewer 无法远程控制（鼠标 / 键盘输入）** (`control_screen.dart`, `connection_manager.dart`, `input/event_handler.dart`, `signal/signal_client.dart`, `macos/Runner/MainFlutterWindow.swift`)
  - 链路原本断在客户端：服务端转发逻辑完好，但 viewer 未捕获输入、controller 未应用输入，且 `InputEventHandler` 的鼠标移动上报是写死 `0,0` 的空壳。
  - **Viewer 端**：`Listener` 捕获指针按下/抬起/移动/滚轮，`Focus` 捕获键盘（全局），坐标归一化 `[0..1]` 后发给 controller；工具栏键盘图标可暂停/恢复控制。
  - **Controller 端**：`ConnectionManager` 新增 `MOUSE_EVENT`/`KEY_EVENT` 处理，将归一化坐标按本机主屏尺寸映射成像素，经 `MethodChannel('remote_desktop/input')` 调原生。
  - **macOS 原生**：`MainFlutterWindow.swift` 注册通道，用 CoreGraphics `CGEvent` 回放鼠标/键盘，含 USB HID → macOS keyCode 映射表。
  - ⚠️ **硬前提**：controller 端 app 须被授予 **系统设置 → 隐私与安全性 → 辅助功能** 权限（首次操作时自动弹授权提示），否则系统拒绝模拟输入。
  - 已知局限：坐标按**主显示器**尺寸映射；若共享非主屏，位置会有偏差（后续可按实际捕获屏校准）。

#### 编译/API 适配（Flutter ≥ 3.18）

- `event_handler.dart`：`MouseEvent`/`KeyEvent` 重命名为 `RemoteMouseEvent`/`RemoteKeyEvent`，避开与新版 Flutter `KeyEvent` 的命名冲突；修复鼠标移动空壳为基于节流的真实坐标上报。
- `connection_manager.dart`：屏幕尺寸 API 由 `ScreenRetriever.instance.primaryDisplay`（getter，已不存在）改为 `getPrimaryDisplay()`（方法）。
- `control_screen.dart`：键盘事件改用新版 `KeyEvent`/`KeyDownEvent`/`KeyUpEvent` 与 `Focus.onKeyEvent`；指针事件改用 `buttons` 位掩码与 `PointerScrollEvent`（来自 `flutter/gestures.dart`）。
- `flutter_webrtc` 0.12.12 的 `RTCVideoViewObjectFit` 仅有 `Contain`/`Cover`，原 `RTCVideoViewObjectFitFill` 不存在，改为 `RTCVideoViewObjectFitCover`。
- `connect_screen.dart`：补充 `foundation` 导入以使用 `kDebugMode`。

### Known Issues

- **Controller 端视频显示 "串行"（横向错位 / 扫描线 / 撕裂）**：疑似 flutter_webrtc 在 macOS 上的纹理渲染问题，已从 Dart 侧做防御性修正（Cover 适配 + 首帧后按真实比例重排），但纹理层问题无法在 Dart 层根治。需提供截图以精准定位（已列出三种可能表现）。

## [1.0.0] - 2026-07-15

### Added

- 基于 WebRTC P2P 的远程桌面投屏 MVP：controller 端屏幕采集（getDisplayMedia）→ viewer 端观看。
- 信令服务（RawSocket 手写 WebSocket 握手/帧编解码，绕开 macOS URL 解析 bug）。
- VP8 优先以规避 macOS H.264 VideoToolbox 不稳定路径。
- 屏幕录制权限声明与可观测性增强。
