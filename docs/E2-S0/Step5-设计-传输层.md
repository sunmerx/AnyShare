> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 5 设计:传输层(UDP 分片 + 重组 + XOR FEC)

> 2026-10-17。目标:把 Step 4 产出的 H.264 码流实时送达接收端,闭环 `采集→VFR→编码→传输→显示`。本步:自定义轻量 UDP 协议(局域网直连)+ 两个工具(ss-send / ss-recv);加密与拥塞控制留 Step 6(产品期按优化方案接 TLS/DTLS 与自适应码率)。

## 1. 协议 v1(明文,局域网)

单包格式(全部小端):
```
偏移 0    magic u32 = 0x31533245 ("E2S1")
     4    version u16 = 1
     6    flags u8: bit0 keyframe | bit1 discontinuity | bit2 header(AU) | bit3 fec-parity
     7    reserved u8
     8    session u32(随机,防串流)
    12    frame_id u32(1 起递增;0 = 序列头 AU)
    16    seq u16(数据包:帧内序号;校验包:块号)
    18    count u16(帧内数据包总数)
    20    timestamp_100ns u64(采集时刻)
    28    payload_len u16
    30    payload(数据包 ≤1200B;校验包 ≤1200B)
```

- **分片**:每个编码输出(AU)按 ≤1200B 切成数据包
- **FEC**:每 8 个数据包为一组,发 1 个 XOR 校验包(payload=组内按字节异或,短包零填充);接收端每组丢 1 包可恢复,丢 ≥2 包计损
- **序列头**:编码器 SPS/PPS 作为 frame_id=0 的 header AU 首发;STREAM_CHANGE 后重发;接收端有序交付保证首帧前先写出
- **重组**:按 frame_id 聚合;完整(或恢复完整)后按序交付;缺席帧 300ms 超时跳过记损(不阻塞后续)

## 2. 组件

| 组件 | 平台 | 说明 |
|---|---|---|
| `transport.rs` | 全平台 | 协议编解码、FecEncoder、Reassembler(纯逻辑,单测锁定:roundtrip/单丢恢复/双丢计损/乱序有序交付/超时跳过) |
| `ss-send` | Windows | 采集→VFR→编码→分片+FEC→UDP;统计(帧/包/Mbps/关键帧) |
| `ss-recv` | 全平台 | UDP→重组→stdout 写 Annex-B;stderr 统计;`ss-recv | ffplay -f h264 -` 即活画面 |

## 3. 验收

- 单测:transport 全部通过
- 本机回环:ss-send → 127.0.0.1,ss-recv 落盘 → ffmpeg 全量解码通过
- 跨机实测:Windows ss-send → Ubuntu `ss-recv | ffplay -f h264 -` 实时画面(用户目视);统计对比发送/接收包数,丢包率可读

## 4. 非目标(Step 6+)

- 加密(产品期 TLS/DTLS 包装)、拥塞控制/自适应码率、乱序/重传策略调优
- 接收端原生播放(硬解+渲染,替换 ffplay)、序列头按 keyframe 重复发送(丢头恢复)

## 5. 验收结果(2026-10-17,全部通过)

| 项 | 实测 |
|---|---|
| 单元测试 | ✅ 21 项(协议 roundtrip/分片/单丢恢复/双丢拒绝/乱序缺口填充/超时跳过/会话空闲接管/短块精确恢复/僵尸校验包清除) |
| 本机回环 | ✅ 6016 包、FEC 实测恢复 3 包、`ffmpeg -f null` 解码通过 |
| 跨机实时 | ✅ Windows→Ubuntu **28843 包 0 丢包**,828 帧 30 秒实时画面(用户目视) |
| 代码审查 | ✅ 10 项发现修复(高危:完成后到达的校验包造成每帧僵尸条目→改为过期帧号直接丢弃;未信任 count/parity seq 边界;recovered 统计;短块零填充→校验包携带总长度前缀;args_os 等) |

**已知留待产品期**:回环边界丢 1 帧(shutdown 尾帧与 300ms 重组窗口竞态);无拥塞控制;明文 UDP(局域网演示级)。

