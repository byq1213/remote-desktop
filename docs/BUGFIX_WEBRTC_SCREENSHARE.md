# 远程桌面投屏链路修复日志（信令 + WebRTC + 屏幕采集）

> 本文沉淀本轮 diff 处理的问题：从「客户端连不上信令服务器」到「投屏画面能正常显示」的完整链路排障。
> 涉及模块：`client/lib/signal/`、`client/lib/models/`、`client/lib/webrtc/`、`client/lib/screens/`、`client/macos/`、`server/src/signal-server.js`。
> 现象总览：macOS 客户端信令握手 404 → 连上后拿不到画面 → 采集走了摄像头 → 画面比例被压扁。

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

---

## 9. 可观测性增强（便于后续排障）

- 服务端：关键路径日志由 `debug` 升级为 `info`（收到消息、relay、连接建立/关闭、房间成员列表、PEER_JOINED 广播）；`getOrCreateRouter` 包 try/catch，失败回 `AUTH_ERROR`；消息处理整体包 try/catch 防单条消息异常拖垮连接；`Target peer not found` 日志补充 `type`。
- 客户端：`peer_manager` / `connection_manager` / `control_screen` 补充 ICE 状态、track 收发、SDP 长度、首帧渲染等日志。
- 连接界面（`connect_screen.dart`）：Debug 模式下自动预填房间号（当天 YYYYMMDD）与随机用户名；支持 `--dart-define=MODE=viewer` 让专用 viewer 窗口默认切到观看角色。

---

## 修改文件清单

| 文件 | 主要修复项 |
| --- | --- |
| `client/lib/signal/signal_client.dart` | #1 RawSocket 手写握手/帧、定向 to、PEER_JOINED |
| `client/lib/models/connection_manager.dart` | #1 URL 清洗、#4 offer 时序、#5 房间协商、#6 SDP 解析 |
| `client/lib/webrtc/peer_manager.dart` | #7 VP8 优先、addTracks、#9 日志 |
| `client/lib/webrtc/screen_capture.dart` | #3 getDisplayMedia、#8 长边约束 |
| `client/lib/screens/connect_screen.dart` | #2 应用服务器地址、#9 调试预填/角色 |
| `client/lib/screens/control_screen.dart` | #8 渲染器时序与比例、#9 日志 |
| `client/macos/Runner/Info.plist` | #3 屏幕录制权限声明 |
| `server/src/signal-server.js` | #1 放开 path、#5 PEER_JOINED/peers、#9 日志与容错 |
