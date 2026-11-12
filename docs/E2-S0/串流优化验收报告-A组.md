> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# 串流优化验收报告 · A 组(延迟)

> 本文档自包含:读者无需任何其他上下文即可理解全部概念、改动与验证方法。
> 适用代码库:`E:\code\AnyShare`(AnyShare,LocalSend 的派生项目),分支 `anyshare`。
> 相关组件:`packages/screen-stream`(Rust 串流引擎)、`app`(Flutter 客户端)、
> `packages/localsend_isolates`(Dart↔Rust 桥)、`server`(WebRTC 信令,本组未涉及)。

---

## 0. 背景:这套串流是怎么工作的

1. **采集(Windows 发送端)**:使用 DXGI Desktop Duplication 抓取某一台显示器的画面。
   "输出(output)"指一台显示器,例如 `#0 DISPLAY1 2880x1800`、`#2 DISPLAY6 1920x1080`。
   鼠标指针不在 DXGI 画面里,单独由指针元数据合成到帧上。
2. **编码(发送端)**:把画面交给 H.264 硬件编码器(Media Foundation MFT,本项目实测为
   `AMDh264Encoder`)。编码器是**异步**的:`ProcessInput` 提交一帧后,输出(编码后的
   H.264 访问单元,AU)稍后通过事件通知取回。**在飞帧(in-flight)** = 已提交但还没取回
   输出的帧数。在飞帧越多,吞吐越高但延迟越大。
3. **传输**:编码后的 AU 被切成 ≤1200 字节的 UDP 包,附带序号、帧号、时间戳;每 8 个
   数据包追加 1 个 XOR 校验包(FEC,前向纠错)用于恢复单个丢包。接收端按帧重组。
4. **NACK(选择性重传)**:接收端发现某帧缺包时,回发一条 NACK(位图,指明缺哪几个包);
   发送端从最近 48 帧的历史缓存里重发这些包。**静默窗(NACK_GRACE)** = 一帧连续多久没有
   新包到达才判定"可能丢包";太短会误判(包还在路上),太长会拖慢恢复。
5. **解码(接收端)**:通过 ffmpeg 子进程解码(输出原始 NV12 像素),或在进程内用
   openh264/VAAPI 解码(NV12→ARGB 由 Rust 完成)。
6. **呈现**:把解码后的 ARGB 像素缩放(双线性)后写入窗口。窗口使用 winit(跨平台窗口库)
   + softbuffer(CPU 位图提交)。
7. **e2e(端到端时延)**:从发送端给帧打时间戳,到接收端拿到该帧的时间差。注意:**两台
   机器时钟不同步时,直接相减会把"钟差"算进时延**(本项目实测 Ubuntu 比 Windows 快
   1.24 秒,导致曾误读为 1.15 秒时延)。
8. **EventLoopProxy**:winit 提供的事件循环"代理",任意线程都可调用
   `send_event(...)` 唤醒窗口线程;窗口线程在 `user_event` 回调里处理。

模块/线程模型(接收端):
- UDP 接收线程:收包、重组;把整帧送入有界队列(容量 4)。
- 解码线程:从队列取帧 → 解码 → 写入共享帧槽(`Shared.frame`)并递增 `generation`。
- 窗口线程(winit 事件循环):把最新帧缩放到窗口并提交(只在 `generation` 变化时重绘)。

---

## A1. 呈现即时唤醒(本次改动)

### A1.1 问题
窗口线程原本靠一个**固定周期 tick(4 毫秒)**轮询是否有新帧。于是每一帧从"解码完成"
到"上屏"平均多等约 2 毫秒、最坏 4 毫秒。4 毫秒虽小,但属于纯等待,且在低帧率下会被
放大为可感知的"缓一拍"。

### A1.2 机制
新增用户事件 `ViewerCommand::Frame`。解码线程写完共享帧后,立即通过 `EventLoopProxy`
发送该事件;窗口线程收到后马上 `request_redraw()`,下一次 `RedrawRequested` 就呈现该帧。
原有的周期 tick 保留为**兜底**(统计上报、会话时长/停止检查),从 4ms 放宽到 16ms,
减少无意义的唤醒。

### A1.3 改动点(代码位置)
- `packages/screen-stream/src/receiver.rs`
  - `enum ViewerCommand` 增加 `Frame` 变体。
  - `struct Shared` 增加 `proxy: Mutex<Option<EventLoopProxy<ViewerCommand>>>`。
  - `fn publish(...)`:写入帧 → 递增 `generation` → 发送 `ViewerCommand::Frame`。
  - `fn window_loop(...)`:启动会话时把 proxy 存入 `shared.proxy`。
  - `impl ApplicationHandler for ViewerHost` 的 `user_event`:收到 `Frame` 即
    `window.request_redraw()`;`Start` 分支创建窗口后也主动 `request_redraw()`,
    使"窗口创建前已解码的首帧"不必等 tick。
  - `finish()` / `fail()`:清空 `shared.proxy`,避免会话结束后旧解码线程继续空唤醒。
  - 兜底 tick:4ms → 16ms。

### A1.4 自动测试项(无需人工判断)
| 编号 | 命令 | 预期 |
|---|---|---|
| A1-T1 | `cd packages/screen-stream && cargo check --features viewer` | 编译通过,无 warning |
| A1-T2 | `cargo test --features viewer` | 38 个单元测试全部通过(含传输/NACK/H.264 解析/缩放) |
| A1-T3 | `cd app && fvm dart analyze`(或 `flutter analyze`) | `No issues found` |
| A1-T4 | `cd app && flutter test` | 237 个 Dart 测试全部通过 |

### A1.5 待人工测试项(需要人眼/体感判断)
| 编号 | 步骤 | 通过标准 |
|---|---|---|
| A1-M1 | Windows 发起共享 → Ubuntu 端观察画面 | 画面连续,无新增撕裂/闪烁 |
| A1-M2 | Windows 端快速拖动窗口/鼠标画圈,Ubuntu 端对比 | "跟手"程度应优于改动前(主观;无量化阈值) |
| A1-M3 | 静止画面放置 30 秒后再次移动鼠标 | 第一帧变化应立即出现,不应有 ~1 秒迟滞 |
| A1-M4 | 关闭 Ubuntu 接收窗口(F11 退出或关窗) | 会话正常结束,无卡死;重复发起共享可再次打开 |

### A1.6 风险与回退
- 风险:每帧一次跨线程事件(30–60 次/秒),开销可忽略;最小化时 `request_redraw` 仍会
  触发一次重绘,但 `generation` 未变化时 `present()` 直接跳过,不做缩放。
- 回退:把 `publish()` 中的 `send_event` 注释掉、tick 改回 4ms,即恢复原行为。

### A1.7 独立代码审查结论
审查(独立 reviewer)结论:**无 blocker/major**。确认:
- 两把锁(帧槽、proxy)不嵌套,不会死锁;
- `generation` 先于事件发送,`Acquire/Release` 配对,不会丢帧;最多重复呈现同一帧(幂等);
- 事件不堆积(`request_redraw` 会被 winit 合并);
- 多会话复用同一静态 proxy 安全。
已按审查建议补做三项小修:会话结束清空 proxy、`Start` 时主动重绘首帧、tick 放宽为 16ms。

---

## A5. 快速重传(被更新帧超越时立即 NACK)

### A5.1 问题
旧规则只按时间判定:一帧连续 40 毫秒(`NACK_GRACE`)没有新包才算"可能丢包"。但网络
乱序/丢包时,发送端已经在发**更新的帧**了 —— 此时旧帧缺的包显然不在路上,再等 40 毫秒
纯属浪费。典型场景:一帧缺最后 1 个包,接收端白等 40ms 才请求重传,期间解码器缺参考帧。

### A5.2 机制(类似 TCP 的快速重传/重复确认)
接收端记录"见过的最大帧号"(`max_frame_seen`,高水位)。当某个待重组帧被高水位**超前
至少 2 帧**时,立即把它列入 NACK 候选(不再等静默窗)。
- 为什么是 2 帧而不是 1 帧:只超前 1 帧可能只是 UDP 乱序(下一帧的首包先到),此时原帧
  的尾包仍在路上;超前 2 帧才足以认为发送端确实已经走过该帧。
- 高水位只在**通过合法性校验之后**、且只对**数据包**(非 FEC 校验包)推进,避免一个被
  篡改或校验和被关闭的畸形包把高水位推到很远、引发全量误重传。
- **会话重启**时必须重置高水位:新会话帧号从 0 重新开始,若沿用旧高水位(例如 50),
  所有新帧都会被判"被超越",静默窗机制整体失效(该缺陷由独立审查发现并修复)。

### A5.3 改动点(代码位置)
- `packages/screen-stream/src/transport.rs`
  - `struct Reassembler` 新增 `max_frame_seen: u32`。
  - 新会话建立时:`max_frame_seen = packet.frame_id`。
  - `ingest()`:合法性校验通过后,若为数据包且帧号更新,则推进高水位。
  - `missing_candidates(now)`:候选条件 = `高水位超前该帧 ≥2` **或** 静默 ≥ `NACK_GRACE`
    (40ms);先过滤再取前 4 个待重组帧(避免 u32 回绕时数值序把新帧排前、旧帧饿死)。
  - 辅助:`frame_id_is_ahead(reference, candidate)`(u32 环绕安全)。

### A5.4 自动测试项
| 编号 | 命令 | 预期 |
|---|---|---|
| A5-T1 | `cd packages/screen-stream && cargo check --features viewer` | 编译通过,无 warning |
| A5-T2 | `cargo test --features viewer` | **40** 个单元测试全部通过 |
| A5-T3 | 其中 `fast_retransmit_needs_two_frames_ahead` | 超前 1 帧不请求;超前 2 帧立即请求缺包 |
| A5-T4 | 其中 `session_restart_resets_the_frame_high_water_mark` | 会话重启后新帧仍受静默窗保护 |
| A5-T5 | 其中 `missing_candidates_reports_gap` / `missing_candidates_ignores_stalled_frame_prefix` | 静默窗语义未被破坏 |
| A5-T6 | `cd app && flutter test` | 237 个 Dart 测试通过(本项未改 Dart) |

### A5.5 待人工测试项
| 编号 | 步骤 | 通过标准 |
|---|---|---|
| A5-M1 | 正常局域网点对点共享 5 分钟 | 画面稳定;接收端日志 `nacks=` 不应快速膨胀(误重传) |
| A5-M2 | 制造轻微丢包(路由器开启 1% 丢包,或接收端防火墙丢弃少量 UDP) | 卡顿恢复时间短于改动前;`lost=` 不累积 |
| A5-M3 | 重启发送端(结束共享后再发起) | 新会话正常出画,不出现持续重传/花屏(验证高水位重置) |
| A5-M4 | 连续运行 >1 小时 | 无内存增长、无 NACK 风暴(高水位与候选表有界) |

### A5.6 已知限制
- **整帧全丢**(首包都没收到)时该帧不会进入待重组表,快速重传不适用,仍由 300ms 帧超时
  兜底并触发关键帧请求。A5 只覆盖"帧已部分收到、被后续帧超越"的情形。
- 快速重传只解决"何时请求",重传的包数仍受发送端每帧预算(2 个包)限制。

### A5.7 独立代码审查结论
审查结论:方向正确,但发现 **1 个 blocker + 5 个 major**,均已处理:
1. (blocker)会话切换未清空 `max_frame_seen` → 新会话静默窗失效。**已修**。
2. 高水位在校验前推进 → 畸形包可触发误重传。**已修**(校验后、仅数据包)。
3. 单帧超前不足以证明在途 → 改为超前 ≥2 帧。**已修**。
4. `take(4)` 按数值序可能饿死回绕后的旧帧 → 改为先过滤再取。**已修**。
5. 单测覆盖不足 → 补齐"超前 1 帧不报/超前 2 帧报/会话重置"。**已修**。
6. 全丢帧不属本项覆盖范围 → 记入 A5.6 已知限制。**已记录**。

---

## A6. 发送端 pacing(按码率摊开发包)

### A6.1 问题
编码器每产出一帧,发送线程就把该帧的全部 UDP 包(数据包 + 每 8 个包 1 个 FEC 校验包)
在几百微秒内一次性塞进内核。Wi-Fi 会把这种突发聚合成大 A-MPDU 并排队重发,造成:
- 端到端延迟抖动(队列越深,抖动越大);
- 突发本身更容易触发瞬时丢包;
- 与自适应码率叠加时出现"越堵越抖"。

### A6.2 机制
按当前编码码率给发送节流:每累计 8 个包(约 8 × 1230 字节 ≈ 9.8 KB)统计一次应占用的
线路时间(`字节×8 / 码率`),如果落后就睡一次,最多 8ms;每帧总共最多睡 33ms(一帧预算),
超出则放弃等待直接发完,避免关键帧这种大帧把队列拖爆。
关键设计点(均为独立审查发现并修正):
- **不能用逐包 sleep**:Windows 上小于 1ms 的 sleep 不可靠(`Sleep(0)` 等于不睡,或按
  15.6ms 计时器节拍睡),所以改为"批量 + 单次 ≥1ms sleep"。
- **必须 catch-up**:落后时把调度基准重置为"现在",而不是累积欠账;否则"每包固定睡
  2ms"会变成约 4.8 Mbps 的隐形限速,队列填满后持续丢帧。
- **速率预算按线路字节算**(含 FEC 与包头),否则会永久欠账。
- **发包前先登记历史**:pacing 把一帧的发送窗口拉长到几十毫秒,若等整帧发完才登记,
  期间到达的 NACK(尤其是 A5 快速重传)会查不到历史而被静默丢弃。
- **包间处理 NACK**:每 8 个包插入一次有界 NACK 排空,保证重传不被 pacing 拖慢。
- **码率变化 >20% 时重置调度基准**:降码率时不能保留旧的超前调度。

### A6.3 改动点(代码位置)
- `packages/screen-stream/src/sender.rs`
  - 新增 `struct Pacer`:`begin_frame()`、`pace(bytes, rate, now)`、`pace_with_rate(...)`
    (码率变化重置)、`max_batch_sleep=8ms`、`frame_budget=33ms`。
  - `spawn_net_thread` 新增 `current_bitrate: Arc<AtomicU32>`;发送循环改为:
    先登记 history → 每 8 包做一次 pacing 与 NACK 排空 → 帧末补一次 pacing。
  - 抽出 `fn drain_nacks(...)`(原先内联在 job 之间,现在 job 之间与批次之间共用)。
  - 自适应码率生效成功后更新 `current_bitrate`。
  - 环境变量 `ANYSHARE_PACE=0` 可关闭 pacing(用于对照测试)。
  - 单测:`pacer_accumulates_wire_time_and_catches_up`(单包耗时、零码率不调度、迟到
    时 catch-up 不累积欠账)。

### A6.4 自动测试项
| 编号 | 命令 | 预期 |
|---|---|---|
| A6-T1 | `cd packages/screen-stream && cargo check --features viewer` | 编译通过,无 warning |
| A6-T2 | `cargo test --features viewer` | **41** 个单元测试全部通过 |
| A6-T3 | 其中 `pacer_accumulates_wire_time_and_catches_up` | 1200B@12Mbps ≈ 0.8ms;码率 0 不调度;迟到 500ms 时下一次调度 ≤2ms |
| A6-T4 | `cd app && flutter test` | 237 个 Dart 测试通过(本项未改 Dart) |
| A6-T5 | `ANYSHARE_PACE=0` 重新构建并跑同一场景 | 行为回到未 pacing(用于对照) |

### A6.5 实测(CLI 双机,主屏 + 鼠标运动,12 秒)
- 发送:299 帧(≈25fps),17,056 包,19.26 MiB。
- 发送端自身指标:`dropped=0`(网络线程队列未满),`enc_ms≈1.2`。
- 接收端:`delivered=301, lost=0, nacks=0, dropped=0`。
说明 pacing 没有引入丢帧或重传风暴。(注:日志里的 `e2e(pipe)` 被两机 1.24s 钟差放大,
不可直接当作时延读数。)

### A6.6 待人工测试项
| 编号 | 步骤 | 通过标准 |
|---|---|---|
| A6-M1 | 双机共享 5 分钟,观察画面抖动(尤其快速拖动窗口) | 抖动应小于改动前;不应出现周期性卡顿 |
| A6-M2 | 接收端观察 `nacks=` 与 `dropped=`(日志) | 持续为 0 或极小(不出现 pacing 引起的丢帧) |
| A6-M3 | 让自适应码率生效(制造丢包或用 4K 高码率) | 降码率后延迟不应反而变差(A6.2 的"码率变化重置"生效) |
| A6-M4 | 设置 `ANYSHARE_PACE=0` 对照 | 能明显感到突发导致的抖动差异(主观) |

### A6.7 风险与回退
- 风险:低码率(如 3 Mbps 以下)时单帧预算 33ms 可能不足以摊平整帧,多余的包会直接发出
  (退化为不 pacing),不会阻塞。
- 风险:极弱 CPU 上额外的 sleep/唤醒开销;实测 25fps 无 dropped。
- 回退:`ANYSHARE_PACE=0`,或删掉发送循环中的 `pacer.pace_with_rate(...)` 调用。

### A6.8 独立代码审查结论
审查结论:**方向正确,但初版有 3 个 blocker + 3 个 major**,均已按建议重构:
1. (blocker)逐包 `max_sleep=2ms` 截断 → 隐形 4.8 Mbps 限速 + 队列填满丢帧 → 改为
   catch-up(落后即重置基准)+ 批量 sleep。
2. (blocker)预算只按编码码率、却计入含 FEC/包头的线路字节 → 永久欠账 → 现在按线路
   字节计费,并有帧预算兜底。
3. (blocker)Windows 亚毫秒 sleep 不可靠 → 改为每 8 包一次(≥1ms)的批量 sleep。
4. (major)历史登记在整帧发完之后 → NACK 查不到 → 改为发包前登记。
5. (major)NACK 只在 job 之间排空 → pacing 期间快速重传被拖延 → 批次间插入有界排空。
6. (major)码率变化不重置调度 → 降码率时延迟变差 → `pace_with_rate` 检测 >20% 变化即重置。

---

## 验收结论(A 组)
- A1 呈现即时唤醒:已实现并审查通过,自动测试全绿;人工项目待测。
- A5 快速重传:已实现,审查发现的 1 blocker + 5 major 全部修复,40→41 个 Rust 测试覆盖。
- A6 发送端 pacing:已实现,3 blocker + 3 major 全部重构修复,CLI 实测 0 丢包 0 丢弃。

