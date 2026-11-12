> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 6 设计:接收端原生播放器(替换 ffplay)

> 2026-10-17。目标:接收端显示链路全部用 AnyShare 自己的代码(传输/重组/呈现),不再依赖外部播放器窗口。

## 1. 架构

```
UDP → [接收线程] Reassembler → sync_channel(128) → [媒体线程] → 解码器 → 共享帧(Arc) → [主线程] minifb 窗口呈现
```

- **解码器双路径**(`--decoder`,默认 ffmpeg):
  - `ffmpeg`(默认):子进程管道 `h264 stdin → mjpeg stdout`;JPEG 帧由 Rust `image` 库解码为 ARGB。ffmpeg 仅作为编解码库进程,窗口/时序/管线/重组全部自有。**Ubuntu 可直接加 `-hwaccel vaapi` 升级硬解(后续)**
  - `openh264`(实验):纯 Rust 逐 NAL 解码 + 错误后重建解码器并在同步点(含 IDR 帧)恢复。**已知缺陷**:某些帧触发 `dsInitialOptExpected(16384)` 后状态机永久失能(重喂参数集亦不可恢复),故不作默认;留作后续研究(疑为 openh264-rs 0.9 状态管理问题,可向上游报告)
- 背压:有界通道(128)+ 接收线程阻塞 = 天然限流;ffmpeg 早退检测(`try_wait`)
- 发布协议:先存帧再递增 generation(消除新旧错配)

## 2. 同时修复的发送端问题(全部实测踩坑)

1. **试编污染**(Step 4 遗留):试编帧滞留异步 MFT 管道 → 正式流以"无参考 P 帧"开头。曾尝试双实例与 COMMAND_FLUSH 均导致 AMD MFT 事件流死亡;最终**生产路径不做试编**(枚举顺序+激活成功即选,首个真实关键帧即验证)
2. **空闲后事件静默**:长时间无输入后 MFT 不再发 NeedInput → 编码器宽容泵:短等 50ms 后直接 ProcessInput(NOT_ACCEPTING 分支兜底)
3. **SPS/PPS 必须每关键帧内嵌**(MF 输出不含参数集)→ 发送端在每个关键帧前拼接序列头;首帧独立序列头 AU
4. socket2 收发缓冲 8MB(回环丢包 1%→0)

## 3. 验收结果(2026-10-17)

| 项 | 实测 |
|---|---|
| 单测 | ✅ 21 项(transport)+ 转换测试 |
| 本机回环 | ✅ 窗口出画 14-19fps,ffmpeg 全量解码校验 |
| **跨机实测** | ✅ Windows→Ubuntu:413 帧/22091 包/25MB,**0 丢包**,viewer 16-19fps、解码 22ms(用户目视实时时钟) |
| 代码审查 | ✅ 9 项发现全部修复(ffmpeg 孤儿进程防护、有界背压、缩放路径闪烁、发布顺序、首输出超时验证、缓冲上限等) |

## 4. 遗留(下一步)

- Ubuntu 硬解:`ffmpeg -hwaccel vaapi` 参数化(或 `--decoder vaapi` 直通)
- openh264 状态机缺陷(可向上游报告/换版本)
- ffmpeg 关闭时的 muxer 噪音(无害,已知)
- 丢包→参考链断→等下一个 IDR(≤2s)的体验优化:发送端接收 NACK/关键帧请求(未来)

## 5. Step 7 更新(2026-10-17):管道提速 + 硬解参数

| 项 | 结果 |
|---|---|
| 管道格式 | MJPEG → **BMP(image2pipe)**:Rust 侧从 JPEG 解码(22ms)变为近零成本解析——Windows **3.5ms**、Ubuntu **10-14ms**;`image` 依赖移除 |
| 硬解参数 | `--hwaccel <name> [--hwaccel-device <path>]` 透传 ffmpeg;**默认路径自动下载硬解帧,无需手动 hwdownload**(审查修复:多余的 -vf 会破坏默认下载图) |
| Windows 硬解 | ✅ **已实测真硬解**:`--hwaccel dxva2` 解码面 `dxva2_vld`(D3D9Ex),直播 15fps;d3d12va 对本流不稳(参考帧失败,弃用) |
| Ubuntu 硬解 | ✅ 系统栈真硬解确认(iHD 驱动,`pix_fmt: vaapi`,已装 libva 后实测);⛔ 经静态 ffmpeg 管道受 libva 版本错配限制(ffmpeg 需 `vaMapBuffer2` ≥2.21,系统 2.20,rig-only);**D6=C 后由 E2.0 原生 VAAPI 解码器直连系统 libva 消解**;Vulkan 已排除(h264 不支持,静默回退) |
| 解析器加固 | BMP 边界校验(pixel_offset/data_end 越界拒绝)、缓冲上限 256MB |
| 硬解真伪探测法 | `ffmpeg -loglevel verbose -hwaccel X -i sample.h264 -f null -` 查解码面 pix_fmt(如 `dxva2_vld` = 真硬解;`Reinit ... yuv420p` = 回退软解) |

