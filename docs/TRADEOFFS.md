# Remote Desktop System — Tech Selection Tradeoffs

> 本文档记录这个项目的每个关键技术决策点，包括"选了哪个方案"和"为什么放弃其他方案"。

---

## 1. 客户端平台: Flutter Desktop

### Decision: ✅ Flutter Desktop (Windows/macOS/Linux)

### Alternatives Considered:

| 方案 | 放弃理由 |
|------|---------|
| React Native | 桌面端支持不完整,屏幕采集 native bridge 复杂,社区生态弱于移动端 |
| Swift/Objective-C (macOS 原生) | 只能做 macOS,跨平台价值低,而且花了太多时间在平台 API 上 |
| C++/Qt | 开发周期太长,偏离了快速交付(lean prototyping)的核心目标 |
| Electron + Chromium CAPICapture | 安装包大 (>100MB),且 Chromium 内置的屏幕捕获 API 只在 Linux 上可用 |

### Why Flutter:
- **一套代码覆盖多个平台**: 同一份代码跑 macOS + Windows,体现工程效率
- **Flutter-webrtc** 是活跃的开源项目,文档和社区足够支撑 MVP 开发
- **屏幕采集插件生态成熟**: macOS 有 `screen_capture`, Windows 有 `windows_desktop_capture`
- **Hot Reload** 在调试 UI 布局和视频渲染时大幅缩短迭代周期
- **发挥前端背景**: 我主要是前端背景,但 Flutter 的学习曲线友好,能快速上手并交付

### Risks & Mitigations:
| Risk | Impact | Mitigation |
|------|--------|-----------|
| flutter-webrtc 在特定平台有编译问题 | 开发阻塞 | 提前在 CI 跑 `flutter build` 验证,有问题及时切回 web viewer |
| 屏幕采集权限申请失败 (macOS) | 功能不可用 | 在 info.plist 中添加 `com.apple.security.screen-recording` 权限描述 |
| 视频渲染卡顿 | 影响体验 | 用 GPU 加速的 `Image.memory()` + `ShaderMask` 替代 Canvas |

---

## 2. 服务端语言: Node.js

### Decision: ✅ Node.js (signaling / control relay)

### Alternatives Considered:

| 方案 | 放弃理由 |
|------|---------|
| Go + Pion | 性能好,但 Pion 的 WebRTC 绑定文档不够完整,调试困难 |
| Python + aiortc | 单线程瓶颈明显,不适合并发连接;asyncio + mediasoup 无绑定 |
| Rust + pion-rs | 学习成本太高,违背"快速交付"原则 |
| 纯 Web (Turn+Stun + coturn) | 只能做基础设施层,信令和媒体路由还是要自己实现 |

### Why Node.js:
- **发挥既有优势**: 前端背景,对 JavaScript/TypeScript 最熟悉,能把精力集中在架构而非语言学习
- **WebSocket (`ws`) 与 JWT (`jsonwebtoken`) 在 Node 生态里是一等公民**,信令/鉴权几行代码搞定
- **生态成熟**: 日志 (`pino`)、配置校验 (`zod`) 都是经过验证的选择
- **快速迭代**: Node.js 的热重载工具 (nodemon),开发体验接近 Flutter hot reload

### Risks & Mitigations:
| Risk | Impact | Mitigation |
|------|--------|-----------|
| Node.js 单线程瓶颈 | 高并发时 CPU 阻塞 | 信令/控制消息量极小,单进程足够;必要时 cluster 或多进程 |
| WS 长连接需保活 | 僵死连接占用资源 | 服务端 30s 心跳 ping/pong,无响应即 terminate |

---

## 3. 媒体传输: WebRTC P2P（1:1，已放弃 mediasoup SFU）

### Decision: ✅ 直接 P2P（Controller ↔ Viewer 一对一）

> 历史决策：早期选了 mediasoup SFU，理由是 1:N 广播、simulcast、生产验证。
> 但在本项目的实际场景（远程**控制**）里，一个房间固定是「1 个控制端 + 1 个观看端」，
> 并不存在一对多广播需求；而 mediasoup 带来 C++ 原生编译、worker 进程管理、Router CPU 上限等
> 运维负担，与「快速交付 + 轻量」的初衷相悖。因此已**移除 mediasoup**，媒体改为端到端 P2P，
> 服务端仅做信令/控制中继（见 `signal-server.js`）。

### Alternatives Considered:

| 方案 | 结论 |
|------|---------|
| mediasoup / Janus / Jitsi (SFU) | 过重；本场景无 1:N 广播，SFU 的 fan-out/simulcast 用不上，反而引入 C++ 编译与运维成本 |
| Mesh (P2P 多对多) | 仅 1:1 时退化为单连接，无 N² 复杂度；本场景足够 |
| TURN only | 仅做 NAT 穿透基础设施；媒体仍由 P2P 直连（必要时经 TURN 中继） |
| 自建 WebRTC (Pion/aiortc) | 要自己实现 NACK/RTX，偏离核心目标 |

### Why P2P (1:1):
- **场景匹配**: 远程控制是一对一，SFU 的 fan-out 能力完全闲置
- **零媒体服务器**: 无 C++ 编译、无 worker 管理、无水平扩展压力，部署只需一个轻量 WS 服务
- **延迟更低**: 媒体不经中转，端到端直连（LAN 下尤佳）
- **libwebrtc 已内置**: flutter-webrtc 封装好 `RTCPeerConnection`，P2P 是开箱即用的主路径

### Risks & Mitigations:
| Risk | Impact | Mitigation |
|------|--------|-----------|
| 对称型 NAT 无法直连 | 连接失败 | 配置 TURN (`server/.env`) 兜底中继 |
| 单房间扩展至多 Viewer | 需回到 SFU | 当前产品定位即 1:1；如需多人围观再评估引入 SFU |

---

## 4. 控制指令通道: WebSocket vs WebRTC DataChannel

### Decision: ✅ WebSocket (独立通道)

### Alternatives Considered:

| 方案 | 放弃理由 |
|------|---------|
| WebRTC DataChannel | 可以实现,但需要额外配置 `ordered: true` + reliability 参数,调试不如 WS 直观 |
| HTTP POST /PUT | 延迟高(每次 TCP 握手),不支持推送,不适合高频事件 |

### Why WebSocket:
- **延迟更低**: 建立连接后是长连接,鼠标事件可以直接推送,无需每次握手
- **调试方便**: Chrome DevTools 可以直接抓包看 JSON payload,比 DataChannel binary frames 直观得多
- **实现简单**: `ws` 库几行代码搞定,信令通道和控制指令共用同一个 WS 连接,代码复用

### Tradeoff Acknowledgment:
> "如果用 DataChannel 也可以,并且能享受 WebRTC 自带的加密和 NAT 穿透。但在本场景中,控制指令的数据量极小(每次 < 100 bytes),WebSocket 的性能完全够用。选择 WS 的主要理由是降低调试复杂度,把精力集中在核心的 WebRTC 媒体流和架构设计上。如果项目扩展到百万级并发,我会重新评估切换到 DataChannel。"

---

## 5. 视频编码: VP8 vs H.264

### Decision: ✅ VP8 (via flutter-webrtc default codec)

### Alternatives Considered:

| 方案 | 放弃理由 |
|------|---------|
| H.264 (AVC) | 专利问题,某些平台解码可能有 license 费用;但 iOS/macOS 原生支持好 |
| VP9 | 压缩率更好但 CPU 编码耗时更长,桌面端 CPU 负载可能超标 |
| AV1 | 太新,flutter-webrtc 的硬件加速支持不完善,可能导致卡顿 |

### Why VP8:
- **免专利费**: 对项目的展示目的来说,不需要考虑商业授权
- **flutter-webrtc 默认支持**: 开箱即用,不需要额外指定 codec param
- **CPU 开销适中**: 在 Intel/Apple Silicon 上有硬件编码支持 (VTec/VAAPI)
- **带宽需求合理**: VP8 在 2.5Mbps 下 1080p @ 30fps 的视觉质量足够

### Tradeoff Note:
> "如果部署场景主要是 iOS/macOS,我会考虑 H.264,因为 Apple 平台对 H.264 的硬件编解码支持更成熟。但在跨平台通用场景下,VP8 是更安全的选择。这一点也值得单独展开,体现对多平台场景的深入理解。"

---

## 6. 认证方案: JWT vs Session Cookie

### Decision: ✅ JWT (JSON Web Token)

### Alternatives Considered:

| 方案 | 放弃理由 |
|------|---------|
| Session Cookie | 需要服务端维护 session state,不适合分布式部署;且 WebSocket 握手阶段 cookie 携带需要额外配置 `withCredentials` |
| API Key | 不够灵活,无法嵌入角色、过期时间等元数据 |
| OAuth 2.0 | 过度工程,对个人项目来说不需要引入第三方身份提供商 |

### Why JWT:
- **无状态**: 服务端不存 session,mediasoup room 的认证可以水平扩展
- **自包含**: Token 里可以带 `roomId`, `role`, `userId`, 一次性验证完所有信息
- **WebSocket 握手简单**: 直接在 URL query 或 header 里传 token,一行代码搞定

---

## 7. 屏幕采集 API 选择: Native Plugin vs FFmpeg CLI

### Decision: ✅ Native Plugin (AVFoundation / DXGI)

### Alternatives Considered:

| 方案 | 放弃理由 |
|------|---------|
| FFmpeg CLI (`ffmpeg -f avfoundation`) | 需要 fork 进程、处理 IPC、解析 stderr,架构笨重;对个人项目而言,重点不在此类运维能力展示 |
| GStreamer Pipeline | 配置复杂,调试困难,适合嵌入式场景而非桌面应用 |

### Why Native Plugin:
- **Flutter 插件是 Dart API 的直接封装**,调用方式和语言一致,心智负担小
- **GPU 加速**: AVFoundation 和 DXGI 都走 GPU compositor pipeline,不会阻塞主线程
- **权限管理**: 插件会处理 `info.plist` / manifest 中的权限声明,比 CLI 手动申请更可控

---

## 8. 工程组织: Monorepo vs Polyrepo

### Decision: ✅ Monorepo (root → `client/` + `server/`)

### Why:
- **项目倾向于在一个 repo 里交付**,monorepo 结构清晰,`git clone` 一次搞定
- **统一 version bump**: 客户端和服务端的接口契约 (如 SignalMessage TypeScript interface) 可以在同一个 repo 里同步更新
- **CI/CD 简化**: 一条 pipeline 同时 build client 和 deploy server

---

## 9. 实施优先级 (为了快速交付)

| 优先级 | 功能 | 工时 | 说明 |
|--------|------|------|------|
| P0 | Controller 屏幕采集 → Server → Viewer 显示 | 4-6h | 必须有,否则不算远程桌面 |
| P0 | Viewer 鼠标事件 → Server → Controller 执行 | 2-3h | 核心交互,没控制就不是"远程控制" |
| P1 | JWT 认证 + WSS | 1h | 安全基本项 |
| P1 | 连接状态 UI (FPS/延迟/断线提示) | 1h | 提升用户体验 |
| P2 | Simulcast 自适应质量 | 2h | 加分项,展示性能意识 |
| P2 | Docker Compose 一键启动 | 1h | 展示工程规范 |
| P3 | Grafana 监控面板 | 2h | 锦上添花,如果时间不够可以跳过 |

> **核心原则**: 先跑通 P0 的 MVP,保证能看到"屏幕画面 + 鼠标点击生效"。然后再迭代 P1/P2。不要在一个边缘功能上花超过 1 小时。
