> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 9 / W1 设计:Rust 原生 VAAPI 解码器

> 2026-10-17。D6=C 裁决的 Linux 落地:接收端解码不再依赖 ffmpeg(进程或库),直接经 libva 驱动核显解码。

## 1. 架构

```
AU(Annex-B) → [h264.rs 解析器] → SPS/PPS 状态 + 每 slice 参数
                                   ↓
[vaapi/mod.rs]  libva FFI(libloading dlopen libva.so.2 + libva-drm.so.2)
  vaGetDisplayDRM(renderD128) → vaInitialize → vaCreateConfig(H264 VLD)
  → vaCreateContext(16 surfaces) → 每帧: vaCreateBuffer(slice params/bitstream)
  → vaBeginPicture(VA_PICTURE_PARAMETERS) → vaRenderPicture(bitstream) → vaEndPicture
  → vaSyncSurface → vaDeriveImage → vaMapBuffer → NV12 平面 → ARGB
                                   ↓
[ss-view --decoder vaapi]  发布帧(minifb 呈现,复用现有管线)
```

## 2. 为什么需要自带 H.264 解析器

VAAPI 是"半托管"API:解码器不做比特流解析,**调用方必须解析 SPS/PPS/slice header 并填 VASliceParameterBufferH264**(含 POC、参考帧列表、切片数据偏移)。这是原始 VAAPI 的固有成本;macOS VideoToolbox / Windows MF / Android MediaCodec 无需此步(后续平台照旧)。

**解析器范围(精确匹配本项目流特征)**:Main profile、单 slice/帧、无 B 帧(仅 I/P)、progressive、frame_mbs_only 可带裁剪(1080p=1088 裁剪 8 行)。覆盖字段:SPS(width/height/裁剪/poc_type=0/log2 值/ref frames)、PPS(entropy mode 记录、deblock 控制标志、chroma qp 偏移)、slice header(全部 VAAPI 所需字段 + slice_data_bit_offset)。多 slice 按循环支持。

## 3. 参考帧管理(DPB)

- 按 frame_num 索引,16 面滑窗;IDR 清空
- POC 计算:poc_type=0(lsb + 溢出检测),Top/BottomFieldOrderCnt=2*poc(帧模式)
- CurrPic 与 ReferenceFrames[16] 填 VAPictureH264(flags: 短参考/帧标志)

## 4. 依赖与平台门控

- 新依赖:`libloading`(dlopen 系统 libva;避免构建期链接依赖,Linux 运行时自动探测)
- 全部 `#[cfg(target_os = "linux")]`;非 Linux 无编译影响
- 设备默认 `/dev/dri/renderD128`,`--vaapi-device` 可改

## 5. 验收

- Ubuntu(Intel UHD/iHD):`ss-view --decoder vaapi` 跨机出画 ≥15fps;**真硬解确认**(复用探测法/或对比 CPU 占用)
- 与 ffmpeg 路径画质一致性抽查(截图对比)
- 单测:比特读取(ue/se)、SPS/PPS 解析(用录制流样本)、NV12→ARGB 转换
- clippy 干净;Windows/macOS 构建不受影响(cfg 门控)
