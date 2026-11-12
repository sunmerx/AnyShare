> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 3 设计:VFR 编码门控 + 编码器探测链(第一层)

> 2026-10-17。承接 Step 2(脏区采集)。本步:①"何时编码"的纯逻辑(可单测);②Windows Media Foundation 编码器枚举(硬件/软件分层)。

## 1. VfrGate(平台无关,纯逻辑)

输入:`FrameMeta`(脏区/移动区/LastPresentTime)+ 当前时刻;输出:`Encode{keyframe} | Skip`。

策略(默认值,均可配置):
- **指针-only 帧**(last_present=0 且无脏区) → Skip(指针由独立通道处理,后续步)
- **内容变化帧**(有脏区/移动区) → 受 `min_interval`(默认 1/60s,60fps 上限)节流,窗口内合并 → Skip
- **关键帧节奏**:距上次关键帧 ≥ `force_keyframe_interval`(默认 2s)→ 强制 keyframe(连续变化时保证新接收方可入会)
- **静态心跳**:默认关(纯"静止零编码");可配 `static_heartbeat` 供特殊场景

统计:encoded/skipped/keyframe 计数,供探针与验收输出。

单测覆盖:静止全 Skip、变化即编、节流合并(10 个 2ms 间隔变化 @60fps 只编 1 次)、关键帧 2s 节奏、心跳、指针策略。

## 2. 编码器探测链(Windows / Media Foundation)

- 枚举 `MFT_CATEGORY_VIDEO_ENCODER` 输出 H.264 的 MFT:先 `MFT_ENUM_FLAG_HARDWARE`(独显/核显厂商编码器),再 `MFT_ENUM_FLAG_SOFTWARE`(微软软编)
- 打印友好名 + 分类(hw/sw)
- **本步只做枚举(能力清单)**;真正的"试编一帧选出最优"(独显 vs 核显的最终仲裁)在 Step 4 与编码器实现一起做——MF 的 AMD/Intel/NVIDIA 硬件 MFT 都以硬件标志出现,只有实测出帧才能按优先级择一
- 选型理由:MF 是 Windows 原生栈,所有厂商编码器都注册于此,不引入 ffmpeg 运行时依赖;对应 Linux(VAAPI)/macOS(VideoToolbox)/Android(MediaCodec)的枚举层在平台落地时按同构模式补

## 3. 集成验收

- `ss-probe --vfr`:接入 VfrGate,实时输出 编码/跳过/关键帧 统计
  - 静止场景:encoded≈0(仅心跳不触发即 0),skipped 占绝对多数
  - 时钟窗口场景:encoded ≈ 60fps 上限、每 ~2s 一个 keyframe、面积统计与 Step 2 一致
- `ss-encoders`:列出硬件/软件 H.264 编码器
- `cargo test -p screen-stream` 单测全绿;clippy 干净;非 Windows 编译通过

## 4. 非目标(留下一步)

- MF 编码器实编(Step 4):MFT 实例化、媒体类型协商、bitstream 输出、实测出帧择优选链
- 指针形状解码与独立指针通道
- Linux/macOS 枚举层
