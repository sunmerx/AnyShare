> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# 自适应 FEC 与"虚拟屏"测试方法

> 自包含文档。仓库 `E:\code\AnyShare`,分支 `anyshare`;组件 `packages/screen-stream`。
> 适用于:屏幕共享的发送端(FEC 策略)与性能测试方法(如何制造有代表性的运动)。

---

## 1. 背景概念

- **AU / 帧**:编码器输出的一段 H.264 码流(一个显示帧)。传输前被切成多个 UDP 包。
- **FEC(前向纠错)**:发送端每 8 个数据包追加 1 个 XOR 校验包。接收端若只丢 1 个包,
  可用校验包零延迟重建;丢得更多则无效。
- **NACK(选择性重传)**:接收端发现缺包就回发位图,发送端按帧/序号重发。
  代价是一个往返(本项目局域网 RTT ≈ 4–8ms)。
- **FEC 的代价**:每 8 个数据包多 1 个 1230 字节的包 → 约 **+12.5% 的上行流量**
  (在 20 Mbps 码率下多约 2.5 Mbps)。

## 2. 为什么要"自适应"

- 干净链路上,NACK 已经能在 10ms 内补齐丢失,FEC 的校验包是纯冗余;
- 有丢包时,FEC 能免掉一次往返,对**大关键帧**和**单包小帧**尤其有价值;
- 但"关闭 FEC"会带来一个真实风险:**整帧全丢**(一个包都没收到)的帧不会进入接收端的
  待重组表,既不会触发 NACK,也只能等 300ms 帧超时——期间后续帧被按序阻塞。
  对 `count <= 8` 的小帧(光标微动、小差分)恰好等于 1 个 FEC 块,FEC 可零延迟重建,
  因此这类帧不能关。

## 3. 策略(实现)

发送端维护两个状态:

| 状态 | 含义 |
|---|---|
| `fec_enabled` | 是否发送校验包 |
| `last_nack_ms` | 本会话最近一次收到 NACK 的时刻(**单调时钟**,会话起点为 0) |

状态机(每个采集循环执行一次):

```
wanted = (会话开始 < 10s)                       // 起步保护
      || (最近一次 NACK 在 30s 内)               // 丢包后保持保护
fec_enabled = wanted
```

即:**默认开启 10 秒 → 干净链路自动关闭 → 一旦出现 NACK 立刻恢复 30 秒**。
状态切换会打印日志:`sender: adaptive FEC OFF (clean link)` / `ON (recent loss)`。

**无论 FEC 是否开启,以下两类帧始终携带校验包**(没有它们就没有恢复路径):

1. 关键帧(`FLAG_KEYFRAME`):大帧,丢失代价最高(intra-refresh 支持时周期关键帧可放宽到
   10 秒,更不能裸奔);
2. 数据包数 `<= 8` 的小帧:整帧全丢时不会触发 NACK,只能靠 FEC 或 300ms 超时。

单调时钟的选择:如果使用墙钟(epoch),NTP 校时或虚拟机休眠恢复会让时间跳变,
可能把 FEC 永久钉在"开"(白耗 12.5% 带宽)或刚丢包就关掉保护。

## 4. 代码位置
- `packages/screen-stream/src/sender.rs`
  - `encode_packets(packets, cipher, fec_enabled)`:按上述规则过滤校验包(数据包原样保留、
    顺序不变;加密路径同样只丢校验包)。
  - `spawn_net_thread(..., last_nack_ms, session_start)`:收到**本会话**的 NACK 时记录
    单调毫秒时间戳。
  - `run_loop`:每轮计算 `wanted`,`fec_enabled` 变化时打日志;
    并对**稀疏提交**做了冲刷(见 §6)。
  - 单测 `adaptive_fec_drops_parity_but_keeps_data_bytes`:
    - 大帧关闭 FEC 只丢校验包,数据包与开启时**逐字节相同且顺序不变**;
    - 小帧(≤8 包)与关键帧**保留**校验包;
    - 加密路径同样只丢校验包。

## 5. 自动测试项
| 编号 | 命令 | 预期 |
|---|---|---|
| D1-T1 | `cd packages/screen-stream && cargo check --features viewer` | 编译通过,无 warning |
| D1-T2 | `cargo test --features viewer` | **48** 个单元测试全部通过 |
| D1-T3 | 其中 `adaptive_fec_drops_parity_but_keeps_data_bytes` | 见 §4 三条断言 |
| D1-T4 | `cd app && flutter test` | 240 个 Dart 测试通过(本项未改 Dart) |

## 6. 稀疏提交的冲刷(同批修复)
静止画面下发送端只在周期关键帧(2 秒)时才提交一帧,而编码器是异步的:上一次提交的帧可能
还在 MFT 里等待输出,下一次提交会先送出**上一帧**。表现为"恢复运动时先看到一秒前的画面"。

修复:在提交新帧之前,若还有未取回的帧,先泵出它(最多等 20 ms),把旧帧放进本批一并发出。
注意:如果画面完全静止,编码器没有新输入就不会产生输出,此时"滞留帧"仍然存在——
但因为没有内容变化,它不影响观感;`e2e` 日志在静止段会显示 ~1 秒,这是"最后一帧的年龄",
不是交互延迟。

## 7. 正确测试方法:运动必须发生在**被采集的屏幕**上
本项目默认采集**虚拟屏**(输出 `#2`,1920×1080,桌面坐标 x∈[2880,4800))。之前用主屏
(x≈900,y≈500)画圈的测试方法无效:虚拟屏上没有内容变化,发送端只会周期性发关键帧,
测出的帧率/延迟不代表真实场景(会看到 fps 只有 1–2、`e2e` 出现 1 秒)。

正确的脚本(`D:\usertmp\opencode\move_mouse_vdd.ps1`):把光标中心放在虚拟屏中央
`(3840, 540)`,半径 260×180 画圈,间隔 25ms。
```powershell
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);' -Name M -Namespace T
$centerX = 3840; $centerY = 540
for ($i = 0; $i -lt 400; $i++) {
  $angle = $i * 0.21
  [T.M]::SetCursorPos([int]($centerX + 260 * [Math]::Cos($angle)), [int]($centerY + 180 * [Math]::Sin($angle))) | Out-Null
  Start-Sleep -Milliseconds 25
}
```
(坐标来自 `ss-send` 启动时打印的输出列表;若输出顺序变化,请以实际 `x` 起点为准。)

## 8. 实测(虚拟屏内画圈,18 秒)
```
sender: t=6s  fps=32 kf=2 mbps=13.4   sender: adaptive FEC OFF (clean link)
sender: t=12s fps=32 kf=1 mbps=14.1
receiver: decode queue avg=0.1–2.6ms max<21ms e2e avg=51–66ms (offset=-1902ms rtt=8ms)
receiver: delivered=361 lost=0 nacks=0 dropped=0 auth_fail=0
```
结论:运动期间真实端到端约 **50–65ms**、接收排队 <3ms、零丢包;干净链路 FEC 自动关闭,
上行负载相应减少约 12.5%(关键帧与小帧仍受保护)。

## 9. 待人工测试项
| 编号 | 步骤 | 通过标准 |
|---|---|---|
| D1-M1 | 共享虚拟屏 5 分钟,观察日志 | 10 秒后出现 `FEC OFF`;一直无丢包时不反复切换 |
| D1-M2 | 制造 1% 丢包(路由器限流/防火墙丢弃 UDP) | 再次出现 `FEC ON (recent loss)`;卡顿明显少于关闭 FEC 时 |
| D1-M3 | 停止丢包 30 秒 | FEC 自动回到 OFF |
| D1-M4 | 静止画面 30 秒后恢复运动 | 首帧内容为"当前画面",不应先闪一帧旧画面 |

## 10. 已知限制
- 静止段的 `e2e` 读数是"最后一帧年龄",不能当作交互延迟;只有运动期间读数是真实时延。
- 关闭 FEC 期间若发生"整帧全丢"且帧大于 8 个包,仍只能等 300ms 超时 + 关键帧请求
  (→ 本项只保护关键帧与小帧)。进一步方案是让 NACK 支持"整帧缺失"(`max_frame_seen` 空洞请求),
  已列入待办。
- 自适应以"是否收到 NACK"为信号,NACK 只在有帧进入待重组表时才可能产生;因此它是
  "事后保护",首个丢包事件在 FEC 关闭期间仍可能可见(局域网 RTT 下为几十毫秒)。
