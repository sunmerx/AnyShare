> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 4 设计:MF 编码器实编 + 试编仲裁 + 采集像素通路

> 2026-10-17。目标:打通 `抓帧(含像素)→ VFR 门控 → H.264 编码 → 码流产出`,并以"试编一帧"完成硬件择优(独显/核显/CPU)。

## 1. 新增模块

| 模块 | 内容 |
|---|---|
| `capture` 扩展 | 像素通路:`IDXGIResource → ID3D11Texture2D → Staging 纹理 CopyResource → Map`,逐行按 `RowPitch` 拷贝为紧凑 BGRA;暂存纹理/缓冲按需重建 |
| `convert.rs` | `bgra_to_i420`(标量实现,单测锁定数学正确性;SIMD/VideoProcessor MFT 优化列为后续) |
| `windows_encoder.rs` | MF H.264 编码器封装 + 试编仲裁 |
| `ss-probe --encode [--dump <file.h264>]` | 全链路模式:采集→门控→编码→统计/落盘 |

## 2. MF 编码器封装

- 输入 I420(系统内存),输出 H.264(Annex-B)
- **同步/异步双路径**:硬件 MFT(AMD 等)是异步 MFT —— `ProcessInput` 遇 `MF_E_NOTACCEPTING` 先抽输出;异步事件 `METransformNeedInput/HaveOutput` 经 `IMFMediaEventGenerator` 驱动(带超时防御);软件 MFT(微软)走同步直调
- **VFR 时间戳**:每个 sample 的 `SetSampleTime` 用真实采集时刻(100ns 单位),帧间隔不齐时打 `MFSampleExtension_Discontinuity`;`SetSampleDuration` 用名义帧时长
- **关键帧强制**:VFR 门控判 keyframe 时经 `ICodecAPI::SetValue(CODECAPI_AVEncVideoForceKeyFrame, 1)`;API 不可用时降级为位流标记统计(记录在案)
- 尺寸/码率/帧率经媒体类型协商;`MF_MT_FRAME_SIZE/RATE/AVG_BITRATE/INTERLACE_MODE`

## 3. 试编仲裁(硬件择优)

`create_best_encoder(config)`:
1. 候选 = MF 枚举(硬件先行,软件兜底,沿用 Step 3 顺序)
2. 逐个:激活 → 配置 640x360@30 → 试编 3 帧合成画面(I420)→ 有码流输出即通过
3. 第一个通过者获胜;记录试编日志(哪个候选、失败原因)
4. 产出 `H264Encoder` 实例 + 选中名称(供展示:用户能看到"正在用 AMD 硬件编码器")

dGPU vs 核显无法从 MF 枚举名区分(都叫厂商名),**先到先得 + 实测通过**即当前可行仲裁;后续需要压榨时可引入性能基准(编码耗时对比)。

## 4. 验收

- `cargo test`:转换数学单测(2x2/奇数尺寸边界)
- `ss-probe --output 2 --seconds N --encode --dump dump.h264`:静止 → 输出极少帧(仅系统小刷新);活动(时钟窗口)→ 稳定编码
- 产物 `dump.h264` 用 `ffprobe` 验证(编码/分辨率/帧数)+ `ffplay` 目视
- 统计输出:编码帧数、平均编码耗时(ms)、码率(kbit/s)、关键帧数、选用编码器名
- clippy 干净;独立代码审查通过

## 5. 非目标(后续)

- 传输层(RTP+FEC / WebRTC)——Step 5
- 接收端硬解、NV12/GPU-only 零拷贝路径、VideoProcessor MFT 转色、SIMD 转换
- Linux/macOS 编码链(平台落地时按同构补)

## 6. 验收结果(2026-10-17,全部通过)

| 项 | 实测 |
|---|---|
| 试编仲裁 | ✅ 硬件候选(AMD)试编通过并选中;软编作为兜底路径同构实现 |
| 全链路 | ✅ 采集→VFR 门控→BGRA-NV12 转换→H.264 编码→Annex-B 落盘;`ffmpeg -f null` 全量解码通过 |
| 性能(release) | ✅ **6.40ms/帧**(含转换+编码,1080p);debug 94ms(未优化转换的对照) |
| VFR | ✅ 速率合并 154 次/8s;关键帧 2s 节奏;duration=实际帧间隔;空闲后首帧 discontinuity |
| 序列头 | ✅ MF_MT_MPEG_SEQUENCE_HEADER 提取注入;STREAM_CHANGE 后自动刷新并由探针续写 |
| 代码审查 | ✅ 14 项发现全部修复(高危:错误路径 4MB 样本泄漏;GetBlob 逻辑;VT_UI4;旋转屏拒绝;MF 初始化失败缓存等) |
| 单元测试 | ✅ 11 项(含 NV12/奇偶尺寸/参考值) |

**MF 实战坑位清单(供后续平台与回归参考)**:异步 MFT 解锁(MF_TRANSFORM_ASYNC_UNLOCK)是前置;解锁后仍走事件泵;调用方提供输出样本;SPS/PPS 在属性不在码流;`MFT_OUTPUT_DATA_BUFFER.pSample/pEvents` 是 ManuallyDrop,所有路径必须 take;先设输出类型才有输入类型可枚举。
