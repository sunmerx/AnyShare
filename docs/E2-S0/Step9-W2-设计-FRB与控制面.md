> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# Step 9 / W2 设计:FRB 桥与控制面

> 2026-10-17。W1(原生 VAAPI 解码器)已落地。本步:把推流引擎接入 app 架构——Rust 侧库化 + FRB 暴露 + 53318 控制面端点。**不含 UI**(W3)。

## 1. 范围与架构

```
Flutter app(main isolate)
  screen_provider(会话状态机,无 UI)      extension_server(53318 控制面增量)
      │                                      │
localsend_isolates(Dart 包装)  ScreenSender/ReceiverSession
      │ FRB(RustLib.instance;main isolate 在 preInit 已 init)
rust_lib_localsend_app::api::screen  RsScreenSender/RsScreenReceiver(StreamSink 事件)
      │
screen-stream(library)  sender.rs / receiver.rs(原 ss-send/ss-view 逻辑库化)
```

- 会话状态与 FRB 调用放**主 isolate**:事件 ~1/s、无 Dart 侧重网络(与扩展服务器同层);重活全部在 Rust 原生线程
- 平台门控:`desktop` cfg(win/linux/macos)= 才依赖 screen-stream;移动端无依赖,API 存在但运行时返回不支持(FRB 面全平台一致,避免 codegen 平台漂移)

## 2. screen-stream 库化

- `src/sender.rs`:`SenderConfig { target, output, bitrate_bps, fps, timeout_ms }`;`start_sender(config, event_tx) -> SenderHandle`;`handle.stop() / stats()`;内部线程跑原 ss-send 主循环;停止 = AtomicBool,退出前 flush 编码器尾帧
- `src/receiver.rs`:`ReceiverConfig { port, decoder, vaapi_device, window_title, scale }`;`start_receiver(config, event_tx) -> ReceiverHandle`;内部三条线程(receive/decode/window);**用户关窗 = 会话结束**(Ended{window_closed})
- 事件(两方向共用 `StreamEvent`):`Status { state }`、`Stats { fps, mbps, packets_lost, decode_errors, frames }`、`Ended { reason }`、`Error { message }`;统计 1s 一次
- ss-send / ss-view 二进制改为薄壳(测试台架保留原 CLI);ffmpeg 解码路径仅保留在 ss-view 二进制
- 平台:receiver 需要 viewer feature;vaapi 仅 linux

## 3. FRB 面(`api/screen.rs`)

- 函数签名全平台一致;函数体 `#[cfg(desktop)]` 真实现 / 否则 `Err("… not supported on this platform (E2.0)")`
- `start_screen_sender(host, port) -> RsScreenSender`(opaque);`start_screen_receiver(port) -> RsScreenReceiver`
- 方法:`listen(StreamSink<RsScreenEvent>)`(内部 spawn 转发线程,std mpsc → sink)、`stop()`、`stats() -> RsScreenStats`
- `RsScreenEvent` / `RsScreenStats` 定义在 FRB 层(不引用 screen-stream 类型)→ 全平台可生成、生成物无 cfg
- 新增 `build.rs` 定义 `cfg(desktop)`;`Cargo.toml` 目标依赖:`[target.'cfg(desktop 同义列表)'.dependencies] screen-stream = { path, features = ["viewer"] }`
- codegen:严格 `flutter_rust_bridge_codegen 2.12.0`(与 Rust crate `=2.12.0`、Dart `2.12.0` 三方对齐)

## 4. Dart 包装(localsend_isolates)

- `lib/src/screen/screen_session.dart`:`ScreenSenderSession` / `ScreenReceiverSession`(start / stop / stats / 事件流转 Dart 模型)
- 事件模型(sealed):`ScreenSessionEvent` = Status / Stats / Ended / Error;`ScreenSessionStats`

## 5. 控制面协议(53318 增量)

全部 POST + JSON,复用现有 `_rateLimited`:

| 端点 | 方向 | 请求体 | 响应 |
|---|---|---|---|
| `/api/anyshare/v1/screen/offer` | 发送端→接收端 | `{fingerprint, ownerId, ownerName, alias}` | `200 {ok:true, port}` / `409 {pending:true, session}` / `403 {error}` / `409 {error:"busy"}` |
| `/api/anyshare/v1/screen/accept` | 接收端→发送端 | `{session, port}` | `200 {ok:true}` |
| `/api/anyshare/v1/screen/stop` | 双向 | `{session?, reason}` | `200 {ok:true}` |

信任映射(D2 裁决):

- blocked → 403 `blocked`
- temp → 403 `temp_not_allowed`(临时传输不允许屏幕共享)
- full / 同归属者(ownerId 一致)→ 接收端立即启动监听,200 `{ok:true, port:53319}` → 发送端即刻开流
- limited / 未知设备 → 409 `{pending:true, session}` + 本机确认弹窗(W3);接收端用户接受 → 启动监听 + POST accept 给发送端;拒绝 → POST stop `{reason:"denied"}`;60s 超时 → POST stop `{reason:"timeout"}`(发送端本地同 60s 超时兜底)
- 已有活动会话(任一角色)→ 409 `busy`

数据面:接收端固定 UDP 53319(D5);发送端收到 accept/200 后启动,首帧强制关键帧(现有行为)。

安全说明:53318 明文、offer 指纹为自述——与 Step8 §5 风险条款一致(E2.0 局域网实验标注;信任门禁 + 实验标注为当前唯一防线,E2.3 加密前不放宽)。

## 6. app 侧状态(W2 无 UI)

- `app/lib/provider/screen/screen_provider.dart`:`ScreenState { active, pendingOffer, waitingAccept }`;actions:`StartScreenShareAction`(发送流程)、`AcceptPendingScreenOfferAction` / `AbortPendingScreenOfferAction`(接收弹窗,W3 UI 触发)、`StopScreenShareAction`;60s 等待超时
- `extension_server_provider.dart`:三端点 handler 接入 screen_provider;同一时刻仅一个会话

## 7. 验收

- Rust:screen-stream 单测 + ss-view / ss-send 跨机回归(重构不回归)
- 插件 crate:Windows / Linux / Android 三目标 `cargo check` 通过(平台门控验证)
- codegen 产物入库;`flutter analyze` 干净;app 现有测试全绿
- 控制面:扩展服务器单测(offer 信任分支 / accept / stop / 超时 / 忙)通过
- FRB 端到端真机联调归 W3/W4(需 UI 触发);W2 以 Dart 测试 + 手工脚本验证

## 8. 风险

- minifb 窗口从非主线程创建:Linux X11 独立连接可行;macOS 受限(接收端 E2.0 不支持 macOS,已规避)
- FRB codegen 版本漂移:严格 2.12.0;`app/test/mocks.mocks.dart` 若被重写需还原(AGENTS.md)
- 明文控制面指纹自述:E2.0 已知风险,登记 MODIFICATIONS 并在 W3 界面上标注"实验性"
