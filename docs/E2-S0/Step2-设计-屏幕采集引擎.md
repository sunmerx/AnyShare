> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 2 设计:屏幕采集引擎(推流优化方案 P1 第一块)

> 2026-10-17。目标:把"脏区采集 + 按需编码(VFR)"的基础设施立起来。本步只做 **Windows DXGI Desktop Duplication 采集层**(脏区/移动区元数据),不做编码、不做传输、不搬像素上屏,但按可扩展接口设计。

## 1. 目标 / 非目标

**目标**
- 新 Rust crate `packages/screen-stream`(workspace 成员;不触碰 `packages/core` 协议层,rebase 成本归零)
- 枚举显示输出(含 VDD 虚拟屏);对指定输出做桌面复制采集
- 产出每帧元数据:**脏矩形(DirtyRects)、移动矩形(MoveRects)、LastPresentTime、指针形状更新计数**
- 无变化时**不产生帧**(急性空闲检测)——"静止零成本"的验证器
- 探针二进制 `ss-probe`:打印输出清单 + 采集统计,作为验收工具(与 `tools/e2-latency-clock` 一样的定位)

**非目标(后续 Step)**
- 搬像素(hw 帧→系统内存→编码器)、光标形状合成
- 编码器探测链(独显>核显>CPU)、VFR 编码器对接
- 传输层(RTP/WebRTC)、Linux/macOS 采集端(接口先预留)

## 2. 接口设计(平台无关部分)

```rust
pub struct Rect { pub left: i32, pub top: i32, pub right: i32, pub bottom: i32 }
pub struct MoveRect { pub source_x: i32, pub source_y: i32, pub dest: Rect }

pub struct OutputInfo {
    pub index: usize,          // 全适配器扁平索引 = 采集选择用的 ID
    pub adapter_name: String,
    pub device_name: String,   // \\.\DISPLAYn
    pub desktop_rect: Rect,    // 桌面坐标系(已含旋转后布局)
    pub rotation: u32,         // DXGI_MODE_ROTATION
    pub attached: bool,
}

pub struct FrameMeta {
    pub frame_index: u64,
    pub last_present_time: i64, // 0 = 无新内容(DXGI 语义)
    pub dirty: Vec<Rect>,
    pub moved: Vec<MoveRect>,
    pub pointer_shape_updated: bool,
}

pub enum Acquire { Frame(FrameMeta), Idle }
// 平台门控:非 Windows 平台 `enumerate_outputs` 返回空、采集返回 Unsupported
```

## 3. Windows 实现要点(DXGI)

- 设备:D3D11 硬件设备(`D3D11_CREATE_DEVICE_BGRA_SUPPORT`),不建交换链
- 枚举:`IDXGIFactory1 → EnumAdapters1 → EnumOutputs`(扁平化编号,与探针选择一致)
- 复制:`IDXGIOutput1::DuplicateOutput`;`AcquireNextFrame(500ms)`
  - `DXGI_ERROR_WAIT_TIMEOUT` → `Idle`(计入空闲率,**这是 VFR 的依据**)
  - `ACCESS_LOST` → 返回错误,探针负责重建复制器(分辨率切换/锁屏/全屏独占会发生)
  - 成功 → 读 `DXGI_OUTDUPL_FRAME_INFO`;`TotalMetadataBufferSize > 0` 时用一块缓冲依次取 `GetFrameDirtyRects` / `GetFrameMoveRects`
- `LastPresentTime == 0` 的帧(仅指针移动)→ 依然算一次 Acquire,但标记为无内容更新(与脏区分开统计)
- 指针:本步只统计 `PointerShapeBufferSize`/`PointerPosition` 有无,不做形状解码(产品需要单独接 `GetFramePointerShape`,列入 Step3)

## 4. 已知 DXGI 坑(预记录)

1. **RDP/远程会话下 DuplicateOutput 直接失败**(远程桌面观看者存在时)——产品要检测并提示
2. HDR/10bit 输出需要 FP16 拷贝路径,本步固定假定 BGRA8
3. 旋转屏:注入坐标与桌面坐标转换,后续在映射层做
4. 多适配器:枚举顺序不保证稳定,用"扁平索引 + 设备名"双匹配
5. 复制器与 D3D 设备同域:重建设备时必须重建复制器

## 5. 验收(本步)

- `ss-probe` 在本机(3 输出:主屏/虚拟屏/…)正确列出并可选
- 对 VDD 输出运行:桌面静止 → `Idle` 占绝对多数(证明静止零帧);用 `tools/e2-latency-clock` 在虚拟屏上开时钟窗口 → `Frame` 增加且脏区面积≈窗口面积(≈100%检测率)
- `cargo clippy` 干净;非 Windows 目标 `cargo check` 通过(空实现门控)

### 验收结果(2026-10-17,全部通过)

| 项 | 实测 |
|---|---|
| 输出枚举 | ✅ 3 输出正确列出(含 VDD `\\.\DISPLAY7 1920x1080`) |
| 静止场景 | ✅ VDD 上无用户活动时 99.9% 帧为 0.1% 面积级系统小刷新(~1 次/秒);Idle 超时路径正常 |
| 已知活动精度 | ✅ 时钟窗口 640x200(占 1080p 的 6.2%)→ 实测 45 帧/秒 × 6.2%/帧 ≈ 270–295%/秒,**面积分毫不差** |
| clippy | ✅ 干净(--all-targets) |
| 独立代码审查 | ✅ 10 项发现全部修复(关键:多 GPU 下 D3D 设备须建在输出所属适配器上;ACCESS_LOST/INVALID_CALL/ACCESS_DENIED 三态重建;元数据缓冲对齐/越界/上限校验;枚举错误分类;严格参数解析) |
| 样例输出 | `step2-探针输出样例.txt` |

## 6. 验收记录要求

- 探针输出样例存 `docs/E2-S0/`(本地);提交信息 + MODIFICATIONS 登记 + 开发日志追加
