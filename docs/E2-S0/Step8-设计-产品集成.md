> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 8 设计:屏幕共享产品集成(原型 → AnyShare app)

> 2026-10-17。原型能力已验收(Windows 主控采集/编码/发送 → Ubuntu 接收/显示,跨机 0 丢包)。本步:把整条管线并入 AnyShare app 的架构设计,**含一个必须裁决的技术债**(解码器产品化路径)。

## 1. 原则

- 不动 `packages/core` 协议层(rebase 成本归零)
- 复用既有设施:归属者/信任模型、扩展服务器(53318,控制面)、设备面板、FRB 桥
- 数据面(屏幕流)= 新的独立 UDP 通道(现有 `transport.rs`);控制面 = 53318 增量端点(Dart 层)

## 2. 架构映射

```
Flutter(Dart)  设备面板[扩展屏幕按钮] / 共享会话页(状态·停止·统计) / 同意弹窗
      │ Refena actions
localsend_isolates(FRB)  screen.rs:start/stop/stats(StreamSink 事件)
      │
Rust(rust_lib_localsend_app)  ──依赖──▶ packages/screen-stream(现有:采集/编码/传输/播放器)
      │
控制面:53318 /screen/offer|accept|stop(JSON,复用配对/信任判定)
数据面:UDP 自定义协议 v1(现有 transport.rs)
```

- 流引擎跑 Rust 原生线程(非 Dart isolate;重网络在 Rust 侧,符合"isolate 只做编排"约束)
- Windows 主控=发送端;Linux/其他=接收端(E2.0 单向;双向互控后续)

## 3. 裁决点(提请评审)

> **裁决结果(2026-10-17,用户)**:见文末 §7。

| # | 问题 | 建议 |
|---|---|---|
| D1 | 播放器形态 | v1 **独立原生窗口**(minifb,已实现);后续再评估 Flutter 纹理嵌入 |
| D2 | 接收端同意流程 | 随信任模型:同归属者/full 免确认;temp/limited/未知弹同意(与 F-PAIR 语义一致) |
| D3 | 控制面协议 | 53318 新增 `/screen/offer /screen/accept /screen/stop`;数据面沿用现有 UDP v1 |
| D4 | 状态可见性 | 发送端:托盘提示"正在共享屏幕";接收端:播放窗口标题栏 + 结束后通知 |
| D5 | 参数 v1 | 固定 1080p60 / 8Mbps;设置项(码率/分辨率)排后 |
| D6 | **解码器产品化** | 见下——**E2.0 前必须裁决** |

### D6 解码器技术债(重点)

原型接收端借用外部 ffmpeg 子进程,**产品不能依赖用户装 ffmpeg**。选项:

| 方案 | 优点 | 缺点 |
|---|---|---|
| A. 随包分发 LGPL ffmpeg 子进程(内置二进制) | 最快落地(管线已通,仅打包);LGPL 进程调用干净 | +40MB 体积;跨平台需多份二进制 |
| B. 静态链接 libav(ffmpeg-next) | 无进程;许可可控(LGPL 动态链接合规) | 构建链复杂(每平台编 libav);Crash 面变大 |
| C. 平台解码器(Windows D3D11VA/MF、Linux VAAPI、macOS VT、Android MediaCodec) | 最产品化、硬解、体积小 | 每平台一套代码,工作量最大 |

**建议**:E2.0 走 **A**(先能用);E2.1 起按平台逐个换 C,最终形态 C。openh264 不进产品构建(状态机缺陷 + 性能一般)。

## 4. 分阶段

- **E2.0 集成 MVP**:Windows app → Ubuntu app,设备面板手动发起;信任门禁+同意 UI;原生播放窗口;现有 UDP 数据面;明文标注"实验性功能"
- E2.1:控制面端点完整化(拒绝/中断/超时)、统计页、随包解码器(A)
- E2.2:输入回注(接收端操作回传,复用模式 A 注入通道)
- E2.3:加密(与安全设计合并:DTLS over UDP 或迁移 WebRTC 评估)
- E2.4:其余平台采集端(macOS VideoToolbox / Linux PipeWire)

## 5. 风险

- 明文 UDP v1:仅局域网+实验标注;信任门禁是唯一防线(E2.3 前不放宽)
- FRB 事件流(StreamSink)背压:统计类事件低频,无风险;帧数据不过 FRB(原生侧直达)
- 子进程 ffmpeg 的跨平台打包细节(路径探测/权限)E2.1 处理
- Wayland 下 minifb 窗口走 XWayland(已验证可用);纯 Wayland 原生窗口后续再说

## 6. 验收(E2.0)

- 双机真机(Windows app ↔ Ubuntu app):面板发起 → 对端同意 → 出画 ≥15fps → 双方停止干净
- `packages/core` diff 为空;现有 110 单测全绿
- 无外部 ffmpeg 依赖的构建(解码器按 D6 裁决执行)

## 7. 裁决结果(2026-10-17,用户)

| # | 裁决 | 落地要点 |
|---|---|---|
| D1 | **A 独立原生窗口** | 沿用 minifb 窗口方案 |
| D2 | **按信任分档(修订)**:完全信任 → 不弹;临时传输 → **不允许屏幕共享**(直接拒绝);一般信任 → 弹确认;同归属者全部设备 → 不弹 | 判定链新增"屏幕共享权限"分支:temp 拒绝并提示;limited 走确认流;full/同归属者免确认 |
| D3 | **A** | 53318 新增 `/screen/offer /screen/accept /screen/stop` |
| D4 | **同意**:发送端托盘+通知;接收端窗口标题+开始/结束通知 | — |
| D5 | **设置页做好但 E2.0 只实现固定参数**:设置页可见、选项禁用,并**显示当前画质/码率**(1080p60 / 8Mbps) | UI 预留,后续启用 |
| D6 | **直接做 C(平台解码器)** | E2.0 范围:Ubuntu 接收端 = **原生 VAAPI 解码器(Rust 直连系统 libva)**;Windows 后续 = MF/DXVA;不再随包 ffmpeg。静态 ffmpeg 管道保留为开发/测试 fallback(rig 已知 libva 版本错配,仅测试台架) |

**D6 对 E2.0 工作量影响**:接收端解码从"打包 ffmpeg"(几天)变为"Rust VAAPI 解码器"(1-2 周);已验证的前置条件:系统 VAAPI 栈真硬解(iHD 驱动、`pix_fmt: vaapi`)、设备 ACL 权限正常、输出格式 NV12 可直接接现有转换链。

