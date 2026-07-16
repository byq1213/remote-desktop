# 远程桌面客户端技术沉淀（链路修复 + 远程控制）

> 本文沉淀客户端的核心排障与实现笔记：从「客户端连不上信令服务器」到「投屏画面能正常显示」，再到「Viewer 能远程控制 Controller 本机」的完整演进。
> 涉及模块：`client/lib/signal/`、`client/lib/models/`、`client/lib/webrtc/`、`client/lib/input/`、`client/lib/screens/`、`client/macos/`、`server/src/signal-server.js`。
> 现象总览（第一阶段）：macOS 客户端信令握手 404 → 连上后拿不到画面 → 采集走了摄像头 → 画面比例被压扁。
> 远程控制输入（Viewer→Controller 本机驱动）是 MVP 的核心能力之一；本文件亦涵盖提交 `47d3864` 交付时的相关客户端修复：全屏失效、退出黑屏、Flutter 3.18 API 适配。

---

## 1. macOS 上 WebSocket 握手一直 404

**现象：** Flutter macOS 端用 `WebSocket.connect` / `web_socket_channel` 连接 `ws://host:3000/signal` 时，
URL 被破坏（`ws://` 被改成 `http://`、结尾被追加 `#` 片段），服务器按 `path: '/signal'` 精确匹配，
直接返回 HTTP 404，握手失败。

**原因：** flutter 桌面端 WebSocket 客户端存在 URL 解析 bug；同时服务端对升级请求做了严格的路径精确匹配。

**修复（双侧）：**
- 客户端（`signal_client.dart`）：弃用 `web_socket_channel`，改用 `RawSocket` + **手写 WebSocket 握手与帧编解码**（掩码、payload 长度分档、FIN/opcode），直接发送精确字节，绕开所有 URL 解析 bug。连接前增加 `ws://`/`wss://` scheme 校验。
- 服务端（`signal-server.js`）：`WebSocketServer` **去掉 `path: '/signal'`**，接受该端口上任意路径的升级请求（这是专用信令服务器，无其他 WS 端点，安全）。
- 兜底（`connection_manager.dart`）：新增 `_buildWsUrl()`，统一清洗 URL——去掉 `#` 片段、`?` 查询串、结尾多余 `/`，`http(s)` → `ws(s)`，并补齐 `/signal`。

---

## 2. 用户填写的服务器地址被忽略

**现象：** 连接界面输入的 Server URL 不生效，始终连默认地址。

**原因：** `connect_screen.dart` 提交时没有把输入框内容写回 `AppConfig`。

**修复：** 提交前 `config.setServerUrl(serverInput)`，确保后续连接真正指向用户填写的地址。

---

## 3. 采集走了摄像头而非屏幕

**现象：** 控制端「投屏」实际调用的是 `getUserMedia`（摄像头 640x480 fallback），弹的是摄像头权限。

**原因：** `screen_capture.dart` 里遗留的是测试用摄像头 fallback。

**修复：**
- 改为 `navigator.mediaDevices.getDisplayMedia`，触发系统「屏幕录制」选择器与权限弹窗。
- `Info.plist`：移除 `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`，改为 `NSScreenCaptureUsageDescription`（屏幕录制权限说明）。
- 采集失败时通过 `onCaptureError` 回调提示用户授予「屏幕录制」权限。

---

## 4. Offer 时机错误导致 SDP 里没有媒体轨道

**现象：** 控制端连上后就发 Offer，但此时屏幕采集流还没加入 PeerConnection，SDP 里没有 video track，观看端永远收不到画面。

**原因：** 建流（采集 + addTrack）与建连（发 Offer）之间没有时序保证。

**修复（`connection_manager.dart`）：**
- 在连接 WebSocket **之前**先 `initialize()` PeerConnection，保证进来的 offer/answer/candidate 能被立即处理。
- 引入 `_screenCaptureReady` 标志，采集完成并 `addTracks` 之后才置 true。
- 新增 `_maybeCreateOffer()`：只有「采集就绪」且「已知对端 viewer id」两个前提同时满足才创建 Offer，避免发出空 SDP。

---

## 5. 观看端后加入时收不到 Offer（房间协商时序）

**现象：** 控制端先进房、观看端后进房时，控制端不知道有新 viewer，不会重新发起协商。

**原因：** 缺少「新成员加入」通知机制；且 offer/answer 未定向路由到具体对端。

**修复（双侧）：**
- 服务端：加入房间后向房间内其他成员 `broadcastToRoom` 一条 `PEER_JOINED`（携带 userId/role）；`ROOM_JOINED` 的 payload 携带已有 `peers` 列表（顺带修掉一处 `Array.from` 括号错位 bug）。
- 客户端：新增 `SignalType.peerJoined` 处理；`ROOM_JOINED` 时从 `peers` 里识别 viewer，`_onPeerJoined` 处理后来的 viewer，均触发 `_maybeCreateOffer()`。
- `sendOffer`/`sendAnswer` 增加可选 `to` 参数，定向发给具体对端；观看端回 ANSWER 也带上 `to`。

---

## 6. SDP payload 解析格式不一致

**现象：** 收到 offer/answer 后 `setRemoteDescription` 偶发失败。

**原因：** 发送端用 `sdp.toMap()`（含 `type`/`sdp` 字段），接收端却用 `jsonEncode(payload['sdp'])` 当作字符串塞入，格式对不上。

**修复：** 接收端统一按 `sdpMap['type']` + `sdpMap['sdp']` 取字段传给 `setRemoteDescriptionWithType`。

---

## 7. macOS H.264 硬编码路径不稳定，画面黑屏

**现象：** macOS WebRTC 默认走 H.264 VideoToolbox 的 screencast 路径时不稳定，观看端收不到可解码帧。

**修复（`peer_manager.dart`）：** 新增 `_preferCodec()`，在 `createOffer`/`createAnswer` 后重排 `m=video` 的 payload type，把 **VP8** 提到最前，规避 H.264 路径。同时 `addTrack` 改为 `addTracks`，遍历添加流里所有轨道。

---

## 8. 渲染器时序与画面比例问题

**现象：**
- 远端流到达时渲染器可能还没 `initialize`，`srcObject` 绑定无效；
- 竖屏/异形分辨率源被强行塞进 640x360 的 16:9 盒子，画面被压扁。

**修复：**
- `control_screen.dart`：连接前先 `await _initRenderers()`；`_wireRemoteVideo`/`_wireLocalVideo` 在渲染器未就绪时延迟重试，绑定后监听 `onFirstFrameRendered` 触发按真实比例重排；增加大量调试日志（track 数量、muted、videoSize、firstFrame）。
- 采集端（`screen_capture.dart`）：约束只限制「长边」（`max: cap`）而非宽高各自设死，保留源宽高比，横竖屏都不失真。
- 观看端 `_fitVideoBox`：外层容器按远端真实宽高比动态计算尺寸，内层 `RTCVideoView` 用 Fill，竖屏源正常显示为竖屏。

**症状配图：**
- 分辨率被压低（画面发虚、细节丢失）：
  ![分辨率太低问题](./screenshot/分辨率太低问题.png)
- Controller 端画面被拉伸/扭曲（比例失真）：
  ![controller 端扭曲的分辨率](./screenshot/controller端扭曲的分辨率.png)

---

## 9. 可观测性增强（便于后续排障）

- 服务端：关键路径日志由 `debug` 升级为 `info`（收到消息、relay、连接建立/关闭、房间成员列表、PEER_JOINED 广播）；`getOrCreateRouter` 包 try/catch，失败回 `AUTH_ERROR`；消息处理整体包 try/catch 防单条消息异常拖垮连接；`Target peer not found` 日志补充 `type`。
- 客户端：`peer_manager` / `connection_manager` / `control_screen` 补充 ICE 状态、track 收发、SDP 长度、首帧渲染等日志。
- 连接界面（`connect_screen.dart`）：Debug 模式下自动预填房间号（当天 YYYYMMDD）与随机用户名；支持 `--dart-define=MODE=viewer` 让专用 viewer 窗口默认切到观看角色。

---

## 10. 全屏按钮失效

**现象：** 控制页全屏按钮点击无任何反应。

**原因：** `control_screen.dart` 里全屏按钮的 `onPressed` 是空实现；视频框写死 `640×360`，即使能全屏也只是放大的黑边盒子。

**修复：**
- 改用已依赖的 `window_manager` 的 `setFullScreen` 真正切换 macOS 窗口全屏（`control_screen.dart:268`）。
- 视频框从固定尺寸改为 `LayoutBuilder` 填满可用区域，全屏时画面真正放大而非留黑边。

---

## 11. 退出 / 返回时黑屏

**现象：** 点击断开或返回后停留在一个黑屏页，无法回到连接页。

**原因：** `connect_screen` 用 `pushReplacement` 进入 `ControlScreen`，导航栈中**只剩 ControlScreen**；`_disconnect` 里的 `Navigator.pop` 无处可弹，而 `disconnect()` 已 dispose 渲染器，于是停在一个引用了已释放渲染器的黑屏页。

**修复（`control_screen.dart`）：**
- `_disconnect` 先置 `_leaving` 标志显示 "Disconnecting…" 占位页，再 `pushReplacement` 返回 `ConnectScreen`（`control_screen.dart:251`）。
- 给资源清理加幂等保护（`_leaving` 守卫），避免重复 dispose 导致的二次崩溃。
- `build()` 在 `_leaving` 时直接渲染占位页，杜绝在已释放渲染器上重建。

---

## 12. Flutter ≥ 3.18 编译 / API 适配

**现象：** 升级 Flutter 后编译失败或运行时 API 不存在。

**原因：** 多个 API 在大版本发生破坏性变更，且自建类与 SDK 同名类冲突。

**修复：**
- `event_handler.dart`：`MouseEvent`/`KeyEvent` 重命名为 `RemoteMouseEvent`/`RemoteKeyEvent`，避开与新版 Flutter `KeyEvent` 的命名冲突；同时把写死 `0,0` 的鼠标移动空壳改为基于 `Timer` 节流的真实坐标上报。
- `connection_manager.dart`：屏幕尺寸 API 由 `ScreenRetriever.instance.primaryDisplay`（getter，已删除）改为 `getPrimaryDisplay()`（方法）。
- `control_screen.dart`：键盘事件改用新版 `KeyEvent`/`KeyDownEvent`/`KeyUpEvent` 与 `Focus.onKeyEvent`；指针事件改用 `buttons` 位掩码与 `PointerScrollEvent`（来自 `flutter/gestures.dart`）。
- `flutter_webrtc` 0.12.12 的 `RTCVideoViewObjectFit` 仅有 `Contain`/`Cover`，原 `RTCVideoViewObjectFitFill` 不存在，改为 `RTCVideoViewObjectFitCover`。
- `connect_screen.dart`：补充 `foundation` 导入以使用 `kDebugMode`。

---

## 13. 远程控制输入（Viewer → Controller 全链路设计）

> 第二阶段核心能力：Viewer 在本地点击/移动/打字，Controller 本机被真正驱动。横跨四层：Flutter UI → 信令 → Flutter Controller → macOS 原生 `CGEvent`。

### 13.1 端到端数据流

**鼠标：**
1. Viewer：`Listener` 包裹视频，`onPointerDown/Move/Up/Signal` 捕获（`control_screen.dart:436`）。
2. 归一化：指针坐标除以视频盒尺寸 `_remoteBoxSize`，得到 `[0..1]` 相对坐标 `_normalize()`（`control_screen.dart:277`）。**分辨率无关**，是跨端控制的通用解法。
3. 发送：`ConnectionManager.sendInputMouse` → `SignalClient.sendMouseEvent`（`connection_manager.dart:473`）。
4. 信令：`signal-server.js` 收到 `MOUSE_EVENT` 后注入 `from` 并中继。
5. Controller 应用：`_onRemoteMouseEvent` 把 `[0..1]` 乘以本机主屏尺寸 `_localScreenSize` 还原像素（`connection_manager.dart:436`）。
6. 原生回放：`MethodChannel('remote_desktop/input')` 调 `mouse`，macOS 用 `CGEvent` 在 `cghidEventTap` 上 post（`MainFlutterWindow.swift:69`）。

**键盘：**
1. Viewer：`Focus(onKeyEvent: _handleKeyEvent)` 全局捕获（`control_screen.dart:318`）。
2. 取 `event.physicalKey.usbHidUsage & 0xFFFF` 得到 USB HID usage id（键盘页 0x07），而非逻辑字符（`control_screen.dart:295`）。**选 HID 的原因**：物理键稳定、跨布局、可直接映射 macOS 键码。
3. 发送/转发/应用同鼠标，最终 `MethodChannel` 调 `key`。
4. 原生：`postKey` 经 `macVK(fromUsbHid:)` 把 USB HID 映射成 macOS `kVK_*`，再 `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 回放（`MainFlutterWindow.swift:93`）。

### 13.2 各层实现要点

- **Viewer 捕获**：`Listener.behavior: HitTestBehavior.opaque`；按钮位掩码 `_buttonIndex` 压成 `0/1/2`（`control_screen.dart:285`）；滚轮走 `onPointerSignal` + `PointerScrollEvent.scrollDelta.dy`；仅 `_controlEnabled && role == 'viewer'` 时转发，工具栏键盘图标可暂停/恢复控制。
- **信令**：`SignalType.mouseEvent` / `keyEvent`；服务端通用中继自动注入 `from`。
- **Controller 映射**：`_fetchLocalScreenSize()` 读取主屏尺寸（默认 `1920×1080` 兜底，`connection_manager.dart:170`）；仅 `controller` 角色执行应用逻辑，服务端也按角色约束。
- **macOS 原生**：`awakeFromNib` 注册通道（`MainFlutterWindow.swift:17`）；每次调用先 `ensureTrusted()` 触发辅助功能授权；`macVK` 是 USB HID→kVK 查表（字母/数字/控制/功能/方向/小键盘/修饰键），未命中打印告警并跳过。

### 13.3 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 坐标表示 | 归一化 `[0..1]` 传输，两端各自映射 | 分辨率/窗口尺寸无关 |
| 键盘标识 | USB HID usage id | 物理键稳定、跨布局、可直映 macOS 键码 |
| 原生回放 | CoreGraphics `CGEvent` @ `cghidEventTap` | macOS 模拟输入的系统级标准方式 |
| 输入通道 | `MethodChannel` 单通道 + `mouse`/`key` | 与插件体系一致，原生集中处理 |
| 控制开关 | Viewer 端 `_controlEnabled` 闸门 | 可暂停/恢复；角色服务端也约束 |

### 13.4 已知局限与后续

1. **坐标按主显示器映射**：共享非主屏时位置会偏差，后续应按实际捕获屏校准 `_localScreenSize`。
2. **macOS 辅助功能权限为硬前提**：未授权时系统静默拒绝 `CGEvent`，需在「系统设置 → 隐私与安全性 → 辅助功能」开启。
3. **USB HID 映射表覆盖有限**：特殊键可能缺映射，需补表或改用 `CGEvent` 的 `unicode` 字段回放。
4. **视频纹理「串行」**：横向错位/扫描线疑似 `flutter_webrtc` macOS 纹理渲染问题，Dart 侧已做 Cover + 首帧重排防御，根因需截图定位（见 `CHANGELOG.md` Known Issues）。

### 13.5 技术债 / 值得注意的点

- **鼠标节流（已清理）**：早期 `InputEventHandler` 实现了 ~60Hz `Timer` 合并节流，但 UI 实际从未调用它（死代码）。在后续重构中已**删除 `lib/input/event_handler.dart`**，Viewer 捕获统一在 `control_screen.dart` 经 `Listener`/`Focus` 直接走 `ConnectionManager.sendInputMouse`/`sendInputKey`，`InputController` 只负责 Controller 端的回放（`applyRemoteMouse`/`applyRemoteKey`）。**副作用**：目前每次 `onPointerMove` 都立即发信令，没有节流；若需降带宽，应在 UI 层重新引入节流（例如对 pointer move 做 coalesce/节流），而不是恢复已删的单独类。
- **默认屏幕尺寸兜底**：`_localScreenSize` 默认 `1920×1080`，读取失败才用；若主屏非此尺寸且读取异常，坐标会系统性偏移。
- **键盘走 `usbHidUsage` 低 16 位**：`& 0xFFFF` 合理，但跨平台（Windows/Linux）需各自键码映射，当前仅 macOS 实现。

### 13.6 经验沉淀（Lessons Learned）

1. **「能看不能控」往往死在客户端链路最后一环**：服务端转发完好，但 Viewer 没捕获、Controller 没应用、事件类还是写死 `0,0` 空壳——排障要端到端逐环节验证。
2. **原生模拟输入必须先解决权限模型**：macOS 上 `CGEvent` 能否生效完全取决于辅助功能授权，应前置提示而非等用户报「点了没反应」。
3. **坐标归一化是跨端控制的通用解法**：传相对坐标、各端按自身尺寸映射，比绝对像素健壮。
4. **Flutter 大版本升级要审计 API 重名**：自建同名类会直接冲突，应尽早加 `Remote` 前缀区分。
5. **死代码比没有代码更危险**：实现节流却没接线，既占体积又误导后来者以为已有节流；交付前应确认关键路径「真的被调用」。

---

## 修改文件清单

| 文件 | 主要修复项 |
| --- | --- |
| `client/lib/signal/signal_client.dart` | #1 RawSocket 手写握手/帧、定向 to、PEER_JOINED |
| `client/lib/models/connection_manager.dart` | #1 URL 清洗、#4 offer 时序、#5 房间协商、#6 SDP 解析 |
| `client/lib/webrtc/peer_manager.dart` | #7 VP8 优先、addTracks、#9 日志 |
| `client/lib/webrtc/screen_capture.dart` | #3 getDisplayMedia、#8 长边约束 |
| `client/lib/screens/connect_screen.dart` | #2 应用服务器地址、#9 调试预填/角色 |
| `client/lib/screens/control_screen.dart` | #8 渲染器时序与比例、#9 日志、#10 全屏、#11 退出黑屏、#13 输入捕获 |
| `client/macos/Runner/Info.plist` | #3 屏幕录制权限声明 |
| `server/src/signal-server.js` | #1 放开 path、#5 PEER_JOINED/peers、#9 日志与容错 |
| `client/lib/input/input_controller.dart` | Controller 端输入回放（`applyRemoteMouse`/`applyRemoteKey`）；Viewer 捕获已移到 `control_screen.dart` |
| `client/lib/utils/resolution.dart` | 步长安全的分辨率/编码纯函数（`scaleFor`/`resolveCaptureSize`/`preferCodec`/`buildWsUrl`），含单测 |
| `client/lib/screens/connect_screen.dart` | #2 应用服务器地址、#9 调试预填/角色、#12 foundation 导入 |
| `client/macos/Runner/MainFlutterWindow.swift` | #13 远程输入 MethodChannel + CGEvent 回放 + HID 键码映射 |
