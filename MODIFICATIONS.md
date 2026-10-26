# MODIFICATIONS

本文件登记 AnyShare 相对上游 [localsend/localsend](https://github.com/localsend/localsend)(fork 基点 commit `14f3a874`,2026-10-11)的全部修改,满足 Apache License 2.0 第 4(b) 条"显著标注被修改文件"的要求。

约定:对上游文件的实质性修改,在该文件修改处添加注释 `// AnyShare modification (YYYY-MM-DD): <说明>`(机械性品牌替换以本索引统一登记,不逐处加注释)。

## 修改索引

| 日期 | 文件/目录 | 类型 | 说明 |
|---|---|---|---|
| 2026-10-11 | `README.md` | 重写 | 替换为 AnyShare 项目说明 + fork 归属声明 |
| 2026-10-11 | `MODIFICATIONS.md` | 新增 | 本文件 |
| 2026-10-11 | 品牌替换批次(见下) | 修改 | LocalSend → AnyShare(用户可见名称、包标识、数据目录、app group) |

### 品牌替换批次(2026-10-11)

**应用名称与文案(用户可见)**
- `app/assets/i18n/*.json`(57 语言)+ `app/lib/gen/strings_*.g.dart`(生成代码):品牌字符串 → AnyShare
- `app/lib/widget/local_send_logo.dart`、`app/lib/pages/home_page.dart`、`app/lib/config/init_error.dart`:硬编码 'LocalSend' → 'AnyShare'
- `app/lib/pages/about/about_page.dart`:版权行改为 "AnyShare · Based on LocalSend by Tien Do Nam (Apache-2.0)",上游链接标注 "(upstream)"
- `app/linux/my_application.cc`、`app/windows/runner/main.cpp`:窗口标题 → AnyShare
- `app/web/manifest.json`、`app/web/index.html`:浏览器接收页名称 → anyshare_app
- `fastlane/`:商店文案品牌替换(商店分发暂缓,文案仅作占位)

**包标识与产物名**
- `app/android/app/build.gradle`:`namespace`/`applicationId` → `io.anyshare.app`(debug 后缀保持)
- `app/android/app/src/main/kotlin/org/localsend/localsend_app/` → `io/anyshare/app/`(MainActivity 包路径随 namespace 迁移)
- `app/ios/Runner.xcodeproj/project.pbxproj`、`app/macos/Runner.xcodeproj/project.pbxproj`:`org.localsend.localsendApp` → `io.anyshare.app`
- `app/ios/Runner/Info.plist`、`app/macos/Runner/Info.plist`、`app/macos/ShareExtension/Info.plist`:显示名 → AnyShare
- `app/macos/Runner/Configs/AppInfo.xcconfig`:PRODUCT_NAME → AnyShare;BUNDLE_ID → io.anyshare.app;版权行保留上游署名
- `app/windows/CMakeLists.txt`、`app/linux/CMakeLists.txt`:`BINARY_NAME` → `anyshare_app`(exe/二进制名)
- `app/windows/runner/Runner.rc`:FileDescription/ProductName → AnyShare;InternalName/OriginalFilename → anyshare_app
- `app/linux/packaging/{deb,rpm}/make_config.yaml`:display_name → AnyShare;package_name → anyshare
- `app/macos/Runner.xcodeproj/project.pbxproj`:产品引用 `AnyShare.app`

**数据与运行时标识(功能性)**
- `app/lib/provider/persistence_provider.dart`:Windows 配置路径 `%APPDATA%\LocalSend\` → `%APPDATA%\AnyShare\`(`_windowsLegacyFile` 旧版迁移路径保持原样)
- `app/lib/util/native/autostart_helper.dart`:Windows 自启注册表键 → AnyShare
- `app/lib/util/native/context_menu_helper.dart`:Windows 右键菜单项名 → AnyShare
- `app/lib/pages/troubleshoot_page.dart`:防火墙规则名 → AnyShare
- `app/macos/Runner/Shared.swift` + `app/macos/Runner/*.entitlements` + `app/macos/ShareExtension/ShareExtension.entitlements`:macOS app group `localsend.shared_group` → `anyshare.shared_group`
- `app/ios/Runner/Runner.entitlements`、`app/ios/ShareExtension/ShareExtension.entitlements`:iOS app group `group.org.localsend.localsendApp` → `group.io.anyshare.app`
- `support/scripts/*`(Inno/DMG/AppImage/APK 打包脚本):产物名与品牌字段同步(产物名 `AnyShare-*`;上游脚本的仓库目录名假设等将在 Stage 5 重做)

### 构建修复与工具链批次(2026-10-12,代码审查后补登)

- `app/windows/localsend_app.exe.manifest` → `anyshare_app.exe.manifest`(随 BINARY_NAME;品牌批次补全)
- `app/windows/CMakeLists.txt`:`localsend_msix_helper.msix` 改为存在才安装(MSIX 分发暂缓,该文件不随源码仓库;含代码内注释)
- `app/android/.../kotlin/io/anyshare/app/`:全部 4 个 .kt(QuickTileService/FastDocumentFile/FileOpener 等)package 统一 `io.anyshare.app`(品牌批次只迁了 MainActivity,此为补全修复)
- `app/android/gradle.properties`:Flutter migrator 自动追加 `android.builtInKotlin=false`、`android.newDsl=false`(3.41.9 与 AGP 8.12 兼容开关)
- `app/analysis_options.yaml`、`packages/localsend_isolates/analysis_options.yaml`:pub get 自动追加平台目录排除(android/ios/web/windows/macos/linux/build)
- `.gitignore`:追加 `app/android/build/`(上游遗漏;构建产物曾被误提交)
- `pubspec.lock`:8 个 build 工具链传递依赖小版本再解析(archive/build_config/build_daemon 等,仅 codegen 使用;官方源解析,运行时依赖零漂移)
- `app/pubspec.yaml`:description 重写、homepage → github.com/sunmerx/AnyShare

### A1 呈现即时唤醒批次(2026-10-27)

- packages/screen-stream/src/receiver.rs:ViewerCommand::Frame;publish 经 EventLoopProxy 立即唤醒重绘;兜底 tick 4→16ms;会话结束清空 proxy;Start 主动重绘首帧
- 审查无 blocker/major;38 Rust 测试全绿
- 验收文档:docs/E2-S0/串流优化验收报告-A组.md §A1

### 编码器积压与采集目标批次(2026-10-27)

- `packages/screen-stream/src/windows_encoder.rs`:`pump()` 空闲泵输出(静态画面不再等下一次 encode)
- `packages/screen-stream/src/sender.rs`:在飞帧上限 2(先泵出再提交,硬等待 ≤500ms);采集超时 500→16ms;启动打印全部输出;采集目标可选(`config.output` / `ANYSHARE_OUTPUT` / `%APPDATA%/AnyShare/stream_output.txt` 持久化)
- 诊断:1.15s 的 e2e 读数为两机 1.24s 钟差;校正后发送 50ms、接收排队 1ms
- 虚拟屏验证:#2 `\\.\DISPLAY6` 1920x1080,capture=encode=1920x1080
- 38 Rust 测试

### 配对设备换 IP 修复批次(2026-10-25)

- `app/lib/util/device_groups.dart`:新增纯函数 `favoriteWithRefreshedAddress`(地址变化时刷新收藏的 ip/port,保留 customAlias)
- `app/lib/provider/network/nearby_devices_provider.dart`:发现设备时指纹匹配即刷新收藏地址并记日志
- `app/test/unit/util/device_groups_test.dart`:+3 用例;237 Dart 测试全绿
- 背景:Ubuntu 由有线切无线,IP 192.168.1.225→192.168.1.5,列表显示旧地址导致共享失败

### 投屏端到端计时批次(2026-10-21)

- `packages/screen-stream/src/transport.rs`:Delivered 增加 received_at
- `packages/screen-stream/src/receiver.rs`:队列 8→4;ffmpeg 媒体循环打印 decode queue 与 e2e(pipe);`ANYSHARE_FRAME_DUMP_AT` 定时落帧+墙钟
- `packages/screen-stream/src/sender.rs`:epoch 100ns 时间戳;`pipeline_age_ms`/`present_age_ms` 日志
- `packages/screen-stream/Cargo.toml`:Win32_System_Performance
- 诊断结论:干净链路 lost=0/nacks=0;此前 3 秒受并发测试流(WiFi 拥塞)污染
- 38 Rust 测试;双端 release 重建重启

### 投屏延迟修复批次(2026-10-21)

- `packages/screen-stream/src/receiver.rs`:Delivered 队列 128→8;`deliver_frame` 用 try_send 永不阻塞,满则丢帧并置关键帧请求;recv 日志新增 dropped
- 背景:用户实测 5-6 秒延迟;根因为解码/呈现跟不上时队列积压约 4 秒,并阻塞 UDP 接收
- 验证:38 Rust 测试;Ubuntu release 重建重启

### 投屏分辨率自适应修复批次(2026-10-21)

- FRB 侧夹紧对端上报(宽 ≤2560、高 ≤1600);sender 新增 `max_width`(默认 3840)双上限;ss-send `--max-width`
- `receiver.rs`:当前显示器窗口上报(`current_monitor`,随移动/全屏刷新),关闭时清零 monitor 原子
- `screen_provider.dart`:发送端使用对端 width+height;`_engineEnded` 竞态保护(轮询期间引擎结束→500);accept 动作携带宽高
- 测试 +2;234 Dart + 38 Rust、analyze 0

### 投屏分辨率自适应批次(2026-10-21)

- `packages/screen-stream/src/receiver.rs`:Shared 记录主显示器物理尺寸;`ReceiverHandle::monitor_size()`
- `packages/localsend_isolates/rust/src/api/screen.rs` + FRB codegen:`RsScreenSize`、`RsScreenReceiver::monitor_size()`、`start_screen_sender(max_height)`
- `packages/localsend_isolates/lib/src/screen/screen_session.dart`:ScreenSize;发送端 maxHeight、接收端 monitorSize
- `app/lib/provider/screen/screen_provider.dart`:接收端接受前轮询视口并在 offer/accept 中上报;发送端按对端高度启动编码;`receiverMonitorSize()` 轮询
- `app/lib/provider/network/extension_server_provider.dart`:`/screen/accept` 解析 height
- 测试 +3;232 Dart + 38 Rust 全绿,analyze 0

### 投屏清晰度批次二(2026-10-21)

- `packages/screen-stream/src/receiver.rs`:ffmpeg 输出 BMP→raw NV12(管道流量降 2.7x);SPS 解析尺寸 + `raw_nv12_reader`/`nv12_to_argb`;删除 bmp_reader/find_bmp;呈现 tick 8→4ms
- `packages/screen-stream/src/h264.rs`(由 vaapi/ 移到 crate 根)、`lib.rs`、`vaapi/mod.rs`:跨平台复用解析器
- `packages/screen-stream/src/sender.rs`:`max_height`(默认 1280)、默认码率 14Mbps;`bin/ss-send.rs --max-height`
- `app/lib/provider/screen/screen_provider.dart`:AIMD 14M/20M/3M;测试期望 11.2M
- 实测 2048x1280:发送 34-35fps/18Mbps,接收无丢帧;38 Rust + 229 Dart 测试
- 已知:HiDPI 下 winit 物理尺寸与 xrandr 不一致,可能仍有轻微缩放

### 投屏清晰度批次一(2026-10-21)

- `packages/screen-stream/src/receiver.rs`:呈现缩放由最近邻改为 `scale_bilinear`(2x2 双线性上采样、2x2 box 下采样、同尺寸 memcpy 快路径、letterbox 保持);4 个单测
- `packages/screen-stream/src/sender.rs`:默认码率 8M→12Mbps
- `app/lib/provider/screen/screen_provider.dart`:AIMD 初始 12M/上限 16Mbps(下限 2M 不变);测试期望同步
- 实测 1920x1080 窗口 27-29fps 跟满;33 Rust + 229 Dart 测试
- 审查:外部审查端点不可用,已自审(补快路径/退化输入测试);已知限制:窗口缩到 <0.5x 时 2x2 box 会跳像素

### 投屏网络线程批次(2026-10-21)

- `packages/screen-stream/src/sender.rs`:NetJob/NetCounters/spawn_net_thread(有界队列、包级 stop、致命错误传播、丢帧策略与关键帧补发、payload 口径统计);header 入队保证单写者 FIFO;apply_nack 纯函数 + 2 单测
- `packages/screen-stream/src/transport.rs`:NACK_GRACE 40ms;stale 注释(FEC 校验包属正常)
- `packages/screen-stream/src/receiver.rs`:nacks 计数日志;ANYSHARE_NACK=0 诊断开关
- 审查 1 blocker + 6 major 全修;29 Rust 测试;CLI 双机冒烟 0 lost/0 dropped

### 投屏 intra-refresh 批次(2026-10-21)

- `packages/screen-stream/src/windows_encoder.rs`:`configure_intra_refresh()`(SetValue + GetValue 回读校验;不设 MaxKeyframeDistance)、`gradual_intra_refresh()` getter
- `packages/screen-stream/src/sender.rs`:支持时 gate 用 4s 周期;关键帧标记改纯码流判定(编码器自发 IDR 也置 FLAG_KEYFRAME/SPS-PPS)
- `packages/screen-stream/src/vfr.rs`:`VfrConfig::with_intra_refresh()`(2s→4s)+ 真实节奏单测
- 实测本机 AMD MFT 拒绝该属性(false);Intel/NVIDIA 可能支持
- 审查 4 major 修复;27 Rust 测试全绿;Windows release 重建

### 投屏自适应码率批次(2026-10-21)

- `packages/screen-stream/src/windows_encoder.rs`:`set_bitrate()`(CODECAPI_AVEncCommonMeanBitRate,成功才提交,无流中重协商回退)
- `packages/screen-stream/src/sender.rs`:`SenderHandle::set_bitrate()` + run_loop 应用与 5s 退避重试
- `packages/screen-stream/src/receiver.rs`:共享计数改为每秒发布(反馈 delta 语义)
- `packages/localsend_isolates/rust/src/api/screen.rs` + FRB codegen:`RsScreenSender::set_bitrate`
- `app/lib/provider/screen/screen_provider.dart`:AIMD(2–8Mbps,>2% 降 20%,<0.5% 升 5%,500ms 采样间隔,会话重置);接收端每秒上报
- `app/lib/provider/network/extension_server_provider.dart`:POST `/api/anyshare/v1/screen/bitrate`(同 keyframe 校验)
- 测试 +3;229 Dart + 26 Rust 全绿;审查 1 blocker + 4 major 修复

### 投屏选择性重传批次(2026-10-21)

- `packages/screen-stream/src/transport.rs`:FLAG_NACK + Nack 位图编解码;NACK_GRACE=15ms 静默窗口;PacketHistory 48 帧历史;Reassembler::missing_candidates/session
- `packages/screen-stream/src/sender.rs`:非阻塞双工 socket;有界 NACK 排空(32/轮、帧级预算 2、检查 stop);重传计入统计;WouldBlock 丢弃不阻塞
- `packages/screen-stream/src/receiver.rs`:对端地址会话校验;2ms 扫描门控;每帧 2 次 NACK(8ms 间隔)
- 审查 1 blocker + 6 major 修复;26 Rust 测试全绿;双端 release 重建
- 已知限制:connected UDP 在多网卡/VPN 回程地址不一致时可能丢弃 NACK(单网卡 Lan 场景正常)

### 投屏强制 IDR 回归批次(2026-10-21)

- `packages/screen-stream/src/windows_encoder.rs`:`force_keyframe()` VT_UI4 失败回退 VT_BOOL(部分 MFT 类型要求);新增 Windows 编码器级测试(基线仅启动 IDR,force 后 5 个 AU 内必须出 IDR,排除周期 GOP 假通过)
- 验证:22 Rust 测试全绿;Windows release 重建

### 投屏关键帧控制面批次(2026-10-20)

- `packages/localsend_isolates/rust/src/api/screen.rs` + FRB codegen:RsScreenEvent 新增 `RequestKeyframe`;`RsScreenSender::request_keyframe()`(Windows)
- `packages/localsend_isolates/lib/src/screen/screen_session.dart`:事件类 + `ScreenSenderSession.requestKeyframe()`
- `app/lib/provider/screen/screen_provider.dart`:会话接口 `requestKeyframe()`(默认 no-op);receiver 事件自动中继 POST;`requestKeyframeFor()`(role/session 校验 + 500ms 节流)
- `app/lib/provider/network/extension_server_provider.dart`:POST `/api/anyshare/v1/screen/keyframe`(参数/会话/来源 IP 校验,豁免限速)
- `app/test/unit/provider/screen_offer_test.dart`:3 个用例(sender 收请求不外发、stale 忽略、receiver 中继携带 session)
- 验证:226 Dart 测试 + analyze 0;双端 release 重建;Ubuntu→Windows 端点 409 实测可达

### 投屏关键帧请求批次(2026-10-20)

- `packages/screen-stream/src/events.rs`:StreamEvent 新增 `RequestKeyframe`(接收端丢帧上报)
- `packages/screen-stream/src/receiver.rs`:receive_loop 检测未恢复丢帧增量 → pending + 500ms 去抖发送(窗口内新增丢包延后不吞)
- `packages/screen-stream/src/sender.rs`:`SenderHandle::request_keyframe()`;run_loop 接受请求时绕过 VFR 强制编码并置 keyframe;关键帧标记以码流 NAL type 5 为准(`au_has_idr`),MFT 忽略属性时重试
- `packages/screen-stream/src/windows_encoder.rs`:`force_keyframe()` 公开(CODECAPI_AVEncVideoForceKeyFrame)
- `packages/localsend_isolates/rust/src/api/screen.rs`:`map_event` 返回 Option,`RequestKeyframe` 暂不进入 FRB 事件模型(控制面接线后启用)
- `packages/screen-stream/src/bin/ss-{send,view}.rs`:事件 match 补臂
- 验证:Windows/Linux cargo check + 21 Rust 测试全绿;Ubuntu release 重建运行正常;Dart 控制面中继为下一步

### 投屏解码默认切换与 vaapi 排查批次(2026-10-20)

- `packages/screen-stream/src/receiver.rs`:Auto 解码器默认改为 ffmpeg 子进程(`ANYSHARE_FFMPEG_PATH` 覆盖二进制);原生 VAAPI 改为 `ANYSHARE_DECODER=vaapi` 显式启用(仅 Linux);`start_receiver` 启动前预检 ffmpeg 可执行文件,缺失同步报错(新增 `ffmpeg_available` 辅助)
- `packages/screen-stream/src/vaapi/mod.rs`:POC 补全 pic_order_cnt_type=2(8.2.1.3:FrameNumOffset 回绕累加 MaxFrameNum、非参考帧 POC=-1、IDR 重置);新增 `ANYSHARE_VAAPI_TRACE` 亮度采样诊断(行号 clamp)
- `packages/screen-stream/src/bin/ss-vaapidebug.rs`(新增)、`Cargo.toml`:离线 vaapi 解码复现工具(Annex-B 访问单元切分、PPM/亮度统计)
- 背景:原生 vaapi 解码在当前 iHD 栈静默输出纯灰(Y=128),离线可复现,根因未明;默认切 ffmpeg 保证出画
- 验证:Ubuntu cargo check/test(21 项)通过;Ubuntu release 应用重启仅设 `ANYSHARE_FFMPEG_PATH` 即正常服务

### 投屏 GPU 转换批次(2026-10-20)

- `packages/screen-stream/src/gpu_convert.rs`(新增):D3D11 VideoProcessor 硬件缩放+色彩转换(BGRA→NV12,BT.601 limited);每帧输入视图显式回收;NV12 回读 1.5MB
- `packages/screen-stream/src/sender.rs`:GPU/CPU 双路径(`ANYSHARE_CPU_CONVERT=1` 强制 CPU);运行时 GPU 错误自动降级;复制会话重建时重建 converter
- `packages/screen-stream/src/windows_capture.rs`:acquire_texture/frame_texture/release_frame/device/context、read_frame_meta 提取、composite_pointer_nv12(YUV 混合+位图随帧缩放)、D3D11 设备加 VIDEO_SUPPORT
- `packages/screen-stream/src/convert.rs`:nv12_looks_blank(limited-range 黑=Y16,阈值 20)
- `packages/screen-stream/src/lib.rs`:模块注册
- 验证:conv_ms 20→0;码流 ffmpeg 解码真实画面;223 Dart + 21 Rust 测试;审查 1 blocker+3 major+4 minor 全修

### 投屏链路大修(2026-10-20,双机验收驱动)

- `packages/screen-stream/src/sender.rs`:编码流水线化(不等本帧输出,输出按请求队列配对关键帧/SPS/时间戳;2880x1800 avg 59-63ms→11.7ms)、发送端 box 降采样 1080p(D5;1728x1080)、码率配置、仅丢弃确认空白的会话首帧(修静态桌面永久黑屏)、逐秒诊断日志
- `packages/screen-stream/src/windows_encoder.rs`:CodecAPI 低延迟档(LowDelayVBR→CBR、LowLatency、B帧=0、参考=1,置于开流前)、encode 流水线、dimensions()、shutdown 持续排空在途 AU
- `packages/screen-stream/src/windows_capture.rs`:光标合成(COLOR 预乘 alpha/MONOCHROME AND-XOR/MASKED_COLOR)、PointerPosition 仅在 LastMouseUpdateTime 非零时更新、输出相对坐标并按纹理缩放、capture_size()(复制纹理实际尺寸)
- `packages/screen-stream/src/{convert.rs,types.rs,vfr.rs}`:bgra_box_scale/scale_to_fit/bgra_looks_blank;FrameMeta.pointer_moved;VFR 将指针移动/形状更新计为内容变化(修"仅移动鼠标"被判静态)
- `packages/screen-stream/src/receiver.rs`:窗口 minifb→winit 0.30+softbuffer(进程级常驻事件循环、默认全屏、F11/Esc、静态跳过重绘、整数定点缩放、present 成功后才记账、surface 失败上报)、ANYSHARE_DECODER=ffmpeg 覆盖(vaapi 灰帧临时绕行)、ANYSHARE_FRAME_DUMP
- `packages/screen-stream/Cargo.toml`、`Cargo.lock`:winit 0.30 + softbuffer 0.4 替换 minifb
- `packages/screen-stream/src/bin/ss-probe.rs`:`--dump-frame`(取最后的非空白帧为 PPM)
- `app/lib/util/screen_capabilities.dart`:screenShareHostOfWithFallback(仅 IPv6 时回退收藏 IPv4)
- `app/lib/pages/{tabs/my_devices_tab,tabs/device_list_tab,device_details_page}.dart`:「共享屏幕」入口使用回退逻辑
- `app/lib/config/init.dart`:kDebugMode 限定的 ANYSHARE_AUTOSHARE_IP 诊断自启钩子
- 验证(两机 release):发送 32-35fps/1080p/~11Mbps、接收 34-35fps(parse 7ms);根因教训:debug 构建 Rust 慢 8.6 倍(转换 178ms vs 20ms/帧)
- 已知遗留(记账):vaapi 解码器非 1080p 灰帧、发送端消失后接收会话不释放端口、呈现为 CPU 缩放(零拷贝待后续)

### 投屏 IPv4 拨号修复(2026-10-19,双机验收实测)

- `app/lib/util/screen_capabilities.dart`:新增 `screenShareHostOf`(优先 IPv4 HTTP 通道,回退 IPv4 ip,全 IPv6 返回 null)
- `app/lib/provider/screen/screen_provider.dart`:IPv6 守卫报错改 i18n(ui2.screen.errIpv6,原硬编码中文)
- `app/lib/pages/tabs/{my_devices_tab,device_list_tab}.dart`、`app/lib/pages/device_details_page.dart`:「共享屏幕」入口改用 screenShareHostOf(门控与拨号地址一致;仅 IPv6 设备禁用并提示)
- i18n:ui2.screen 新增 errIpv6(en/zh-CN/zh-TW/zh-HK)
- `app/test/unit/util/screen_capabilities_test.dart`(新增,3 项)
- 验证:analyze 0、222 测试全绿、Windows debug 构建

### E-3 共享目录 UI 批次四b:多设备树与冲突询问(2026-10-18,E3-4b)

- `app/lib/pages/dir_browse_page.dart`:多设备树(收藏设备+在线状态+懒探测 roots;树内根节点点击自动切 active;离线提示)、active 设备切换(host 优先会话快照)、进程级全局请求序号、dispose 关闭全部本页会话、粘贴冲突询问(F-DIR-14:保留两者/覆盖/取消;目录恒保留两者)、同目录粘贴拒绝、预检并入 busy
- `app/lib/provider/network/dir_client.dart`:downloadToFile/uploadFile 增加字节进度回调
- `app/lib/util/dir_transfer.dart`:relayDirEntries 增加 onConflict 透传与 onFileProgress(下载 0-0.5+上传 0.5-1 合成);同目录粘贴守卫
- `app/lib/provider/dir_browse_provider.dart`:会话代际计数(Close 后在途 action 不得复活会话)
- i18n:ui2.dirBrowse 新增 5 键(现 69 键,en/zh-CN/zh-TW/zh-HK)
- 独立审查 9 项修复(blocker:同目录剪切+覆盖静默丢文件;major:树内根节点串设备、目录"覆盖"被忽略、幽灵会话吞导航)
- 已知遗留(记账):上传/拖放冲突询问仍为服务端默认 rename;多设备树 widget 测试暂缺
- 验证:analyze 0、219 测试全绿、Windows debug 构建

### E-3 共享目录 UI 批次四a:跨设备中转与剪贴板(2026-10-18,E3-4a)

- `app/lib/util/dir_transfer.dart`(新增):relayDirEntries 跨设备中转(临时文件中转、move 上传后删源、目录递归、mkdir 冲突改名、逐项错误收集、自嵌套守卫、目录列举截断守卫、maxEntries=2000/maxDepth=32、删源失败单独计数、陈旧 staging 清扫)
- `app/lib/provider/dir_clipboard_provider.dart`(新增):全局剪贴板(E3-4b 多设备页面复用)
- `app/lib/pages/dir_browse_page.dart`:复制/剪切菜单、粘贴按钮、中转进度横幅、结果提示;**指纹方向修复**(客户端自述本机 securityProvider.certificateHash,此前误传被浏览设备指纹——真实双机必 403);网格溢出修复(mainAxisExtent 随字号缩放)
- `app/lib/provider/dir_browse_provider.dart`:两处 DirClient 指纹同修(自述本机身份)
- i18n:ui2.dirBrowse 新增 8 键(现 64 键,en/zh-CN/zh-TW/zh-HK)
- 独立审查 10 项修复(blocker:剪贴板页面私有致跨设备 UI 不可达——已上提 provider;major:指纹方向、自嵌套粘贴、删源失败语义)
- 已知遗留(记账):字节级进度合成(E3-1 §5)与粘贴冲突询问(F-DIR-14)随 E3-4b;真实双机跨设备验收待 E3-4b 多设备树页面
- 验证:analyze 0、215 测试全绿(中转双设备端到端 10 项)、Windows debug 构建

### E-3 共享目录 UI 批次三:浏览页交互增强(2026-10-18,E3-3d)

- `app/lib/util/dir_browse.dart`:sortDirEntriesBy(名称/大小/修改时间,升降序,目录恒在前)、filterDirEntries(名称搜索+标签筛选)、dirPreviewKindOf/dirPreviewCapOf(预览分类与上限:图片 10MB/MD 2MB/文本 1MB)
- `app/lib/widget/dir_preview_panel.dart`(新增):宽屏预览面板(图片 cacheWidth 限解码/Markdown 禁远端外联/文本 UTF-8 容错);条目切换代际防护;size 为 null 也受 maxBytes 流式上限保护
- `app/lib/provider/network/dir_client.dart`:downloadBytes 增加 maxBytes(超限中止抛 too_large)
- `app/lib/widget/dialogs/dir_annotation_dialog.dart`(新增):标签/备注编辑弹窗
- `app/lib/pages/dir_browse_page.dart`:搜索/排序菜单/视图切换、标签筛选 chips(已选恒可见防死角)、双视图(网格长按弹菜单)、右键菜单(showMenu)、拖放上传(DropTarget+提示)、宽屏(≥1000px)三栏、busy 提示、标签限宽
- i18n:ui2.dirBrowse 新增 19 键(现 56 键,en/zh-CN/zh-TW/zh-HK)
- 独立审查 14 项修复(major:预览竞态代际、未知大小无上限下载、Markdown 远端图片外联、Image.memory 解码尺寸、busy 静默丢弃、标签筛选死角、网格触屏无菜单)
- 已知遗留(记账):网格 childAspectRatio 超大字号可能溢出(待确认);双机真实浏览验收随 E3-4
- 验证:analyze 0、206 测试全绿、Windows debug 构建

### E-3 共享目录 UI 批次二:浏览页(2026-10-18,E3-3c)

- `app/lib/util/dir_browse.dart`(新增):排序(目录优先/忽略大小写)、父路径/拼接、字节格式化纯函数
- `app/lib/provider/dir_browse_provider.dart`(新增):按设备指纹的浏览会话(roots/根/路径/条目/可写/截断/requestId);`dirBrowsePortProvider`(测试可注入);Open/Load/Close 三个 action;会话单调 requestId 防旧响应覆盖新导航
- `app/lib/pages/dir_browse_page.dart`(新增):根列表(窄屏横向固定宽)/面包屑/上一级/只读徽标/截断提示;上传(逐文件容错+跳过计数)/新建/重命名/删除(回收站)/下载(桌面另存、移动端文档目录;远端名剥路径分量防穿越);条目行显示标签/备注;全错误码 i18n 映射;退出关闭会话
- `app/lib/pages/tabs/{my_devices_tab,device_list_tab}.dart`、`app/lib/pages/device_details_page.dart`:「浏览目录」入口激活(占位→真入口);详情页操作区 Row→Wrap 防窄屏溢出
- `app/lib/provider/network/dir_endpoints.dart`:`kDirMaxListEntries` 公开(截断提示与服务端同源)
- i18n:ui2.dirBrowse 块(~37 键,en/zh-CN/zh-TW/zh-HK)
- 独立审查 14 项修复(blocker:窄屏根列表 ListTile 无界约束断言;major:session.loading 死状态改页面本地、旧响应覆盖新导航、下载路径穿越、详情页溢出)
- `style` 独立提交 eba0a992:dart format 全量对齐 CI 格式检查(历史批次 28 文件漂移)
- 已知遗留(记账):窄屏 widget 冒烟测试暂缺(无 RefenaScope widget 测试先例);双机真实浏览验收随 E3-3d 收尾
- 验证:analyze 0、202 测试全绿(浏览 9 项,含延迟桩防串扰)、Windows debug 构建 + 启动冒烟

### E-3 共享目录 UI 批次一:客户端与本地标注(2026-10-18,E3-3a)

- `app/lib/provider/network/dir_client.dart`(新增):`/dir/*` 端点 Dart 客户端(roots/list/downloadToFile/downloadBytes/uploadFile/mkdir/rename/delete);服务端错误码透传;超时/畸形 JSON/源文件缺失分别映射 unreachable/protocol/source_error;下载经 `.part` 原子落盘(失败清理);上传 30 分钟窗口(服务端接收完成才响应)
- `app/lib/model/persistence/dir_annotation.dart`(新增):本地标签/备注模型(条目级容错 JSON 编解码,键=`指纹:根:路径`)
- `app/lib/provider/dir_annotations_provider.dart`(新增)+ `persistence_provider.dart`(`ls_dir_annotations`):标注存取(空标注即删除)
- `app/lib/pages/tabs/settings_tab.dart`:共享目录配置区块替换占位(添加/逐目录可写开关/删除确认/行级 busy 防重入)
- `app/lib/util/native/pick_directory_path.dart`:新增 `canPickRawDirectoryPath()` 能力判定(Android API 27+ SAF `content://` 根无法被 `/dir/*` 服务,入口门控)
- i18n:ui2.settings 新增 addDir/writable/removeDir/noDirs/removeDirTitle/removeDirBody(en/zh-CN/zh-HK/zh-TW)
- `pubspec.lock`:补 `mobile_scanner` 条目(PAIR-1 批次遗漏,HEAD 锁文件与 app/pubspec.yaml 不一致)
- 独立审查 10 项修复(高危:上传/下载漏传指纹查询参数、下载 IOSink 泄漏与半成品残留;中危:TypeError 误映射 unreachable、上传超时窗口、Android SAF 门控;低危:decodeMap 条目级容错、Switch/删除竞态、错误路径测试补齐)
- 已知遗留(记账):macOS 沙箱 security-scoped bookmark 未持久化(共享目录重启后不可达,macOS 非当前构建目标);Refena AsyncReduxAction 无串行队列(深层并发写保护待后续批次)
- 验证:analyze 0、193 测试全绿

### E-3 共享目录后端批次(2026-10-18,E3-2)

- `app/lib/provider/network/dir_endpoints.dart`(新增):53318 `/dir/*` 端点(roots/list/meta/download/upload/mkdir/rename/delete);访问门(指纹自述 + 存储 IP 严格匹配、重复收藏取最严格条目);写门(可写目录 × 同归属者或 full+设备授权);路径穿越/符号链接/`.anyshare_*` 防护;上传 `.tmp`+原子改名+长度校验+全路径清理+背压;删除默认应用级回收站(`.anyshare_trash` + 原子 meta);根目录身份保护(`.`/`sub/..` 均拒)
- `app/lib/util/dir_access.dart`(新增):权限判定纯函数(拒绝原因码:unknown/ip_mismatch/blocked/temp_not_allowed;limited 只读;同归属者免授权;full 需设备授权)+ 单测
- `app/lib/util/dir_paths.dart`(新增):路径解析与防护(规范化/包含性/最深存在祖先 realpath 校验/内部目录拒绝/Windows 保留名与非法字符)+ 单测
- `app/lib/provider/shared_dirs_provider.dart` + `app/lib/model/persistence/shared_dir_config.dart`(新增):共享目录配置(多目录/只读可写)与设备写授权持久化(`ls_shared_dirs` / `ls_dir_write_grants`)
- `app/lib/provider/persistence_provider.dart`:新增共享目录/写授权存取;`app/lib/provider/network/extension_server_provider.dart`:JSON 辅助函数公开化(`readJsonBody`/`writeJson`,行为不变)+ dir 端点接入
- `app/test/unit/provider/dir_endpoints_test.dart`(新增):13 项端点测试(权限拒绝/穿越/回收站/长度校验/tmp 清理/只读);util 单测 22 项
- 独立审查 21 项修复(高危:`.`/`sub/..` 绕过根删除/重命名保护——改 realpath 身份比对;中危:上传 rename 竞态与 overwrite 误删、tmp 全路径清理、长度校验、背压、`.anyshare_trash` 协议不可达、空 IP 收紧、重复收藏取最严格、限速配额 600/分)
- **双机验收通过**:Ubuntu curl → Windows 应用:roots/list/download/upload/mkdir/rename/delete-to-trash 全链路(上传落盘内容一致、穿越拒绝、无授权只读);analyze 0、182 测试全绿

### 扫码配对与归属者加入批次(2026-10-18,PAIR-1/F-PAIR-08/13)

- `app/lib/util/qr_pairing.dart`(新增):二维码载荷编解码(版本化 JSON,严格类型校验,恶意载荷不抛异常)+ 单测
- `app/lib/provider/qr_pairing_provider.dart`(新增):展示侧状态(一次性令牌 60s TTL、地址/指纹/归属者载荷;无网络地址或扩展服务未启动时明确报错)
- `app/lib/widget/dialogs/qr_pairing_dialog.dart`(新增):展示二维码(pretty_qr_code)、倒计时自动刷新、关闭即失效
- `app/lib/pages/qr_scan_page.dart`(新增):扫码页(mobile_scanner + 权限申请/设置跳转、仅 QR 码制式、生命周期暂停恢复、失败可重扫);扫码者=主动加入方(确认后加入归属者,**配对成功才提交身份**)
- `app/lib/provider/network/extension_server_provider.dart`:pair/register 校验二维码一次性令牌(TTL + 用后立即轮换;注明为防重放而非鉴权门,手动配对不受影响)
- `app/lib/provider/pairing_provider.dart`、`app/lib/widget/dialogs/pairing_dialog.dart`:注册携带 qrToken;**校验扫码指纹与注册响应指纹一致**(防中继冒充);对话框返回配对结果(失败可重扫)
- `app/lib/provider/owner_provider.dart`:SetOwnerIdentityAction(加入归属者)
- `app/lib/pages/tabs/{device_list_tab,my_devices_tab}.dart`:入口(移动端→扫码页,桌面→展示二维码;我的设备空状态→展示二维码)
- `app/pubspec.yaml`:新增 `mobile_scanner 5.2.3`;AndroidManifest CAMERA 权限 + iOS Info.plist 相机用途说明
- i18n:ui2.qrPairing 块(en/zh-CN/zh-HK/zh-TW)
- 独立审查 16 项修复(中危:解码类型安全、令牌用后轮换、指纹校验、身份提交时机改为配对成功后、确认反馈改走全局 messenger)
- 验证:analyze 0、154 测试全绿、Windows 构建 + Android debug APK 构建通过(含相机权限与插件集成)

### UI 重设计批次三:传输面板与发送到…(2026-10-18,UI-3/F-XFER-16)

- `app/lib/util/transfer_overview.dart`(新增):传输聚合纯函数(活动传输:发送会话+接收会话,进度含校验和阶段;历史合并排序)+ 4 项单测
- `app/lib/widget/transfer_panel.dart`(新增):侧栏常驻「传输」区(活动进度/取消/查看全部)、移动端浮标、传输记录弹窗(活动+合并历史+历史页入口);空闲时不订阅进度源(避免逐块重绘)
- `app/lib/widget/dialogs/send_target_dialog.dart`(新增):"发送到…"设备选择(在线设备可选,离线置灰提示;空 IP 设备排除)
- `app/lib/widget/selection_banner.dart`:新增「发送到…」按钮
- `app/lib/pages/home_page.dart`:侧栏固定宽度(256/72)+ 可滚动;移动端传输浮标
- i18n:ui2.transfers 块(en/zh-CN/zh-HK/zh-TW)
- 独立审查 15 项修复(高危:接收方向进度恒 0——接收文件以 desiredName 而非 token 判定已接受;接收取消改走 serverProvider.cancelSession 完整路径——原 isolate 直调不清会话状态/不通知发送方/不停通知;中危:接收状态 watch、IntrinsicWidth 换固定宽度、recipientBusy 终态排除、空闲免订阅)
- 验证:analyze 0、148 测试全绿、Windows 构建 + 启动截图

### UI 重设计批次二:投屏 UI 接线(2026-10-18,UI-2/W3)

- `app/lib/widget/dialogs/screen_offer_dialog.dart`(新增):接收端投屏请求弹窗(接受/拒绝;跟随 provider 状态,报价过期/被远端取消时自动关闭;防重复点击;会话 ID 绑定)
- `app/lib/widget/screen_session_banner.dart`(新增):全局屏共状态横幅(待确认/等待/进行中/错误可叠加;仅发送端显示 Mbps;接收端显示 fps)
- `app/lib/util/screen_capabilities.dart`(新增):平台能力(Windows 可发起、Linux 可接收)
- `app/lib/provider/screen/screen_provider.dart`:attach 先停旧引擎(防会话泄漏);acceptingOffer/startingOffer 防重入守卫;Accept/Abort 增加会话 ID 绑定(陈旧对话框无效);接收能力 Provider 化(可注入/可测试);忙碌判定纳入 waiting;错误文案全部 i18n;ClearScreenErrorAction
- `app/lib/provider/network/extension_server_provider.dart`:pending 报价推送投屏请求弹窗(推送与响应写入解耦,失败由状态横幅兜底)
- `app/lib/pages/tabs/{my_devices_tab,device_list_tab}.dart`:共享屏幕按钮激活(门控:平台/离线/IP 空/临时设备);同归属者设备豁免临时限制(与 D2 判定链一致,含注释)
- `app/lib/pages/device_details_page.dart`:操作区(发送文件/共享屏幕,禁用时说明原因)
- `app/lib/main.dart`:状态横幅挂载于 Navigator 之上(所有页面可见);`home_page.dart` 同步调整
- i18n:ui2.screen 块(含 13 条错误文案,en/zh-CN/zh-HK/zh-TW)
- `app/test/unit/provider/screen_offer_test.dart`:+3 测试(发送端会话建立/接收能力拒绝/错误清除),共 15 项
- 独立审查 17 项修复(高危:对话框跟随状态防"假接受"、接受防重入防双引擎;中危:引擎会话泄漏、推送与响应解耦、详情页门控对齐、横幅错误可见性)
- 验证:analyze 0、144 测试全绿、Windows 构建 + 启动截图

### UI 重设计批次一:四区导航(2026-10-18,UI-1)

- `app/lib/pages/home_page.dart`(重写):四区导航(我的设备/设备列表/黑名单/设置);落地页=我的设备;拖拽落文件→设备列表选择发送
- `app/lib/pages/tabs/{my_devices_tab,device_list_tab,blocklist_tab}.dart`(新增):我的设备(归属者分组+本机置顶+免确认提示)、设备列表(附近+已配对分组、信任徽章、临时设备投屏禁用、扫码配对占位)、黑名单(解除拉黑/删除记录)
- `app/lib/pages/tabs/{send_tab,send_tab_vm,receive_tab}.dart`(删除):发现列表逻辑迁入 device_list_tab 与 `util/send_flow.dart`;接收入口(网页分享/接收历史/发送历史/问题排查)迁入设置页
- `app/lib/widget/{device_card,circular_popup_button,multi_send_info,selection_banner}.dart`(新增):统一设备卡片(徽章/状态/操作/多发送进度)、圆形弹出按钮、多发送会话信息构建器、文件选择横幅(编辑/清除)
- `app/lib/util/{device_groups,send_flow}.dart`(新增):分组纯函数(我的/已配对/附近/黑名单)+ 共享发送流程(单发/多发送/手动地址/网页分享)
- `app/lib/pages/tabs/settings_tab.dart`:新增 本机(归属者名称编辑)、共享目录占位、屏幕共享占位(显示 1080p·60fps·8Mbps,D5)分组;接收组补 网页分享/接收历史/发送历史/问题排查入口
- `app/lib/config/init.dart`、`app/lib/main.dart`、`app/lib/provider/network/send_provider.dart`、`app/lib/provider/network/server/controller/receive_controller.dart`、`app/lib/widget/watcher/shortcut_watcher.dart`:标签跳转目标更新(send→deviceList、receive→myDevices)
- i18n:`app/assets/i18n/{en,zh-CN,zh-HK,zh-TW}.json` 新增 `ui2` 块(导航/设备卡片/黑名单/设置),slang 重新生成 `app/lib/gen/strings_*.g.dart`
- `app/test/unit/util/device_groups_test.dart`(新增):6 项分组与设备匹配单测
- 独立审查 14 项修复(高危:多发送模式恢复会话感知重入与进度显示;中危:在线/离线文案 i18n、多网卡子网扫描回退、选择横幅、发送历史入口恢复)
- 验证:analyze 0 issues、141 测试全绿、Windows debug 构建 + 启动截图确认

### E-2 FRB 桥与控制面批次(2026-10-17,Step 9 W2)

- `packages/screen-stream/src/{events,sender,receiver}.rs`(新增):推流引擎库化(sender/receiver 句柄、事件流、统计;原 ss-send/ss-view 主循环搬入;Drop 不阻塞 finalizer、SO_REUSEADDR、错误路径事件化)
- `packages/screen-stream/src/bin/{ss-send,ss-view}.rs`:改薄壳(CLI 兼容)
- `packages/localsend_isolates/rust/`:新增 `build.rs`(cfg(desktop))与 `src/api/screen.rs`(FRB 面:start_screen_sender/receiver、listen 事件流、stop/stats;平台运行时门控);Cargo.toml 目标依赖 screen-stream(viewer);codegen 2.12.0 产物更新
- `packages/localsend_isolates/lib/src/screen/screen_session.dart`(新增):Dart 包装(ScreenSender/ReceiverSession + 事件模型)
- `app/lib/provider/screen/screen_provider.dart`(新增):屏共会话状态机(offer/accept/stop 流、信任分档、60s 超时、15s 接收看门狗、会话 ID 关联校验、流关闭兜底)
- `app/lib/util/screen_trust.dart`(新增):屏共信任判定(D2;自动接受要求源地址与配对记录一致,防明文指纹重放)
- `app/lib/provider/network/extension_server_provider.dart`:53318 新增 `/screen/offer|accept|stop`(回调端点豁免限速;异常回 500)
- `app/test/unit/{util/screen_trust_test,provider/screen_offer_test}.dart`(新增):18 项测试(信任分档/源地址降级/端点/会话关联/陈旧 stop 拒绝)
- 独立审查 21 项发现修复;验证:app 135 测试全绿、analyze 干净;Rust 三平台编译;跨机实弹 0 丢包 0 解码错误

### E-2 原生 VAAPI 解码器批次(2026-10-17,Step 9 W1)

- `packages/screen-stream/src/vaapi/`(新增):原生 VAAPI H.264 解码器(libloading 直连 libva,无子进程/无 libavcodec)。`ffi.rs` 结构转录自 libva 2.20 va.h 并经头文件逐字段核对;`h264.rs` 极简解析器(EPB 去除、SPS/PPS/slice header;修复 ref_pic_list_modification_flag_l0 漏读导致的位错位,以真实抓包帧做回归测试);`mod.rs` VaapiDecoder(DPB/POC 管理、参考列表按 POC 排序、IQ 矩阵缓冲、错误路径资源回收)
- `packages/screen-stream/src/bin/ss-view.rs`:新增 `--decoder vaapi` 与 `--vaapi-device`(默认 /dev/dri/renderD128)
- `packages/screen-stream/src/bin/ss-h264dbg.rs`(新增):Annex-B 解析调试工具(与 ffmpeg trace_headers 真值对账用)
- `packages/screen-stream/Cargo.toml`:`libloading` 可选依赖并入 viewer feature;ss-h264dbg 声明 required-features
- 实测:Windows→Ubuntu 0 丢包、0 解码错误、17-21fps 满速显示;独立审查 12 项修复;26 项单测全绿

### E-2 播放器管道提速与硬解参数批次(2026-10-17,Step 7)

- `packages/screen-stream/src/bin/ss-view.rs`:管道格式 MJPEG→BMP(自有 BMP 解析,含边界校验),Rust 侧处理 22ms→3.5ms(Windows)/10-14ms(Ubuntu);新增 `--hwaccel/--hwaccel-device` 透传(VAAPI 等;审查修复:hwdownload 多余导致硬解路径必然失败)
- `packages/screen-stream/Cargo.toml`:移除 `image` 依赖(JPEG 解码不再需要)
- 独立审查 3 项修复;跨机与回环回归通过

### E-2 接收端原生播放器批次(2026-10-17)

- `packages/screen-stream/src/bin/ss-view.rs`(新增):原生播放器(接收→重组→解码→minifb 窗口);解码默认 ffmpeg 子进程管道(H.264→MJPEG→Rust JPEG 解码),openh264 纯 Rust 路径为实验选项;有界背压、发布顺序、窗口呈现全部自有
- `packages/screen-stream/src/bin/ss-send.rs`:序列头拼接至每个关键帧(解决接收端无参数集);socket2 8MB 发送缓冲;首输出 5s 超时验证(静默 MFT 检测);统计修正
- `packages/screen-stream/src/windows_encoder.rs`:移除生产路径试编(试编帧滞留异步管道污染正式流;双实例/FLUSH 均破坏 AMD MFT 事件流——详见 Step6 设计文档);事件泵宽容化(空闲恢复)
- `packages/screen-stream/Cargo.toml`:`viewer` feature(minifb/openh264/image 可选依赖)+ socket2
- 实测:跨机 413 帧/22091 包 0 丢包,Ubuntu 原生窗口 16-19fps;独立审查 9 项修复

### E-2 传输层批次(2026-10-17)

- `packages/screen-stream/src/transport.rs`(新增):UDP 传输协议 v1(magic/会话/帧号/时间戳/标志)+ XOR FEC(8+1,校验包携带总长前缀,短块精确恢复)+ 重组器(乱序有序交付、缺口 300ms 超时、会话空闲 2s 接管、未信任输入边界校验);21 项单测
- `packages/screen-stream/src/bin/ss-recv.rs`(新增):跨平台接收端(重组→stdout Annex-B,`ss-recv | ffplay -f h264 -` 即直播)
- `packages/screen-stream/src/bin/ss-send.rs`(新增):Windows 发送端(采集→VFR→编码→分片+FEC→UDP)
- 实测:本机回环 FEC 恢复 3 包解码通过;跨机 Windows→Ubuntu 28843 包 0 丢包、30 秒实时画面;独立审查 10 项修复(含僵尸条目高危)

### E-2 编码器实编与试编仲裁批次(2026-10-17)

- `packages/screen-stream/src/windows_encoder.rs`(新增):MF H.264 编码器封装。同步(软编)/事件泵(硬编,MF_TRANSFORM_ASYNC_UNLOCK)双路径;输入类型协商(NV12 优先,直试回退);试编仲裁(硬件先行、失败降级软编);SPS/PPS 序列头提取;ICodecAPI 关键帧强制(VT_UI4);输出样本复用与缓冲区溢出扩容
- `packages/screen-stream/src/convert.rs`(新增):BGRA→I420/NV12 标量转换 + YV12 平面交换;11 项单测
- `packages/screen-stream/src/windows_capture.rs`:像素通路(Staging 纹理拷贝/按 RowPitch 紧凑化,缓冲复用 `recycle_pixels`)
- `packages/screen-stream/src/windows_encoders.rs`:候选枚举返回 IMFActivate;MF 初始化结果缓存(OnceLock)
- `packages/screen-stream/src/bin/ss-probe.rs`:`--encode/--bitrate/--dump` 全链路模式;旋转屏拒绝(防静默错帧);实际帧间隔时间戳与 discontinuity;关闭时 drain 尾帧
- 实测:AMD 硬件编码 1080p **6.40ms/帧**(release),码流 ffmpeg 全量解码通过;独立审查 14 项修复

### E-2 VFR 门控与编码器探测批次(2026-10-17)

- `packages/screen-stream/src/vfr.rs`(新增):VFR 编码门控(按需编码:指针帧跳过、变化帧 60fps 上限合并、2s 关键帧节奏、可选静止心跳)+ 6 项单元测试
- `packages/screen-stream/src/windows_encoders.rs`(新增)+ `src/bin/ss-encoders.rs`(新增):Media Foundation H.264 编码器 MFT 枚举(硬件优先、软件兜底),为"独显>核显>CPU"探测链第一层
- `packages/screen-stream/src/bin/ss-probe.rs`:新增 `--vfr` 集成(空闲超时同样 tick 门控,支持心跳语义)
- 实测:静止削减 ~60 倍编码(约 1 次/秒系统小刷新触发);活动场景 ~43-56 原始帧/秒收敛到 ~27-31 编码/秒;本机探测到 2×AMD 硬件编码器 + 微软软编

### E-2 屏幕采集引擎批次(2026-10-17)

- `packages/screen-stream/`(新增):E-2 屏幕推流引擎原型 crate。本批含 DXGI Desktop Duplication 采集层(脏区/移动区/空闲检测,平台门控:非 Windows 为空实现)+ 探针二进制 `ss-probe`;不触碰 core 协议层
- `Cargo.toml`(workspace 根):新增成员 `packages/screen-stream`

### E-2 屏鼠共享工具批次(2026-10-17)

- `tools/e2-latency-clock/`(新增):玻璃到玻璃延迟测量工具(双窗毫秒时钟,单张照片同框对比物理屏/虚拟屏读数);含 README 操作规程与注意事项。内部测量工具,不随产品分发

### 传输完成通知批次(2026-10-15,PRD F-INT-R3)

- `app/lib/util/native/transfer_complete_notification.dart`(新增):系统级"传输完成"通知(桌面用 `local_notifier`,Android 走通知渠道);点击回前台并打开目标目录(单文件成功时选中该文件)
- `app/lib/util/native/channel/android_channel.dart`:新增通知显示与点击回传的方法通道封装
- `app/android/app/src/main/kotlin/io/anyshare/app/MainActivity.kt`:通知显示、点击转发(含冷启动重放机制)、POST_NOTIFICATIONS 未授权时静默跳过
- `app/android/app/src/main/res/drawable/ic_stat_transfer.xml`(新增):通知小图标
- `app/lib/config/init.dart`:preInit 初始化通知设施
- `app/lib/provider/network/send_provider.dart`、`app/lib/provider/network/server/controller/receive_controller.dart`:会话正常结束时触发通知(取消/拒绝不通知;接收方携带目标目录)
- `app/lib/model/state/settings_state.dart`(+ `.mapper.dart`)、`app/lib/provider/settings_provider.dart`、`app/lib/provider/persistence_provider.dart`(键 `ls_transfer_complete_notification`,默认开)、`app/lib/pages/tabs/settings_tab.dart`:接收设置区新增开关
- `app/assets/i18n/{en,zh-CN,zh-HK,zh-TW}.json`(+ `app/lib/gen/strings_*.g.dart`):通知文案
- `app/pubspec.yaml`(+ `pubspec.lock`):新增运行时依赖 `local_notifier 0.1.6`(桌面通知;平台注册文件随之更新)
- `app/test/unit/util/transfer_complete_notification_test.dart`(新增):文件状态汇总计数单测

### 配对信任语义裁决批次(2026-10-14)

- 产品裁决:**配对 = 接收方一次性确认**。已配对设备(含临时信任)传输不再弹确认;信任等级仅决定限额是否生效(temp/full 行为一致,limited 走限额检查,blocked 拒绝);未知设备仍走原确认流
- `app/lib/util/trust_evaluator.dart`:temp → 自动接收
- `app/lib/provider/pairing_provider.dart`、`app/lib/provider/network/extension_server_provider.dart`:配对落库注释与默认(仍为 temp)对齐新语义
- 文案 14 语言更新(配对完成提示/等级标签);`docs/扩展协议设计.md` §3.2/§6 同步

### 安装器 AppId 批次(2026-10-13,Stage 3)

- `support/scripts/compile_windows_exe-inno.iss`:AppId 更换为新 GUID(EC7921F5-…,与 LocalSend 安装器隔离,避免升级路径串扰)

### 图标替换批次(已回退,2026-10-13)

- 曾将全平台图标替换为新图形(双向交换弧,tools/gen_icons.py),按产品决定回退为**原版图形**(LocalSend 形状的青色换色版);形状层面的商标风险已知悉,原版为当前发布形态,后续可再议


### 配对真机回归修复批次(2026-10-13,Stage 2 回归)

- `app/lib/config/init.dart`:preInit 主动启动扩展服务器(Provider 懒初始化无人触发;init() 内嵌套 dispatch 会无限递归)
- `app/lib/provider/network/extension_server_provider.dart`:响应方默认信任 full→temp;发起方 transcript 指纹改用 register 响应值;服务器 dual-stack(anyIPv6, v6Only off);confirm 需本地用户开门(60s),单边接受不完成配对;响应方落库收敛到 confirm 单点(含发起方 ownerId);IPv4-mapped 地址清洗
- `app/lib/provider/pairing_provider.dart`:IPv6 host 加方括号+%25 转义;confirm 长轮询 75s
- `app/lib/widget/dialogs/pairing_dialog.dart`:发起方自动等待(仅响应方确认,产品裁决 2026-10-12)
- `app/lib/provider/persistence_provider.dart`:getStringList 容错(外部工具写坏类型不再崩)
- `app/lib/pages/device_details_page.dart`:配对入口 IPv4 通道优先

### SAS 配对与扩展服务器批次(2026-10-12,Stage 2-C)

- `app/pubspec.yaml`:新增依赖 `cryptography 2.7.0`(X25519+HKDF,纯 Dart)与 dev `convert`(测试 hex 解码)
- `app/lib/util/sas.dart`(新增):SAS 派生(临时 X25519 + HKDF-SHA256 + 6 位码,transcript 绑定)
- `app/lib/provider/owner_provider.dart`(新增)+ `persistence_provider.dart`(`ls_owner_id/ls_owner_name`):本机归属者身份
- `app/lib/provider/network/extension_server_provider.dart`(新增):53318 扩展服务器(capabilities/pair/register/pair/confirm,IP 限速 5 次分,pending 5 分钟 TTL)
- `app/lib/provider/pairing_provider.dart`(新增):发起方客户端(探测/register/confirm)
- `app/lib/widget/dialogs/pairing_dialog.dart`(新增)、`app/lib/pages/device_details_page.dart`:配对对话框(双端 SAS 码比对)与详情页入口
- `app/assets/i18n/en.json`、`app/assets/i18n/zh-CN.json`:配对文案
- 协议安全:纯 HTTP + SAS 绑定(设计文档 §2 修订);LocalSend 互操作零影响(通告与 53317 主服务未动)

### 信任 UI 与发送历史批次(2026-10-12,Stage 2-B)

- `app/lib/widget/trust_settings_section.dart`(新增):设备详情页信任区块(等级切换/拉黑/单文件上限/容量限额/用量显示与显式重置)
- `app/lib/pages/device_details_page.dart`:挂接信任区块(仅收藏设备显示)
- `app/lib/model/persistence/send_history_entry.dart`(新增)、`app/lib/provider/send_history_provider.dart`(新增)、`app/lib/provider/persistence_provider.dart`(新增 `ls_send_history` 键,100 条窗口):发送记录模型/状态/持久化
- `app/lib/provider/network/send_provider.dart`:会话收尾记录发送历史(成功逐文件一条、失败/拒绝/取消汇总一条)
- `app/lib/pages/send_history_page.dart`(新增)、`app/lib/pages/tabs/send_tab.dart`:发送历史页与发送页入口按钮
- `app/assets/i18n/en.json`、`app/assets/i18n/zh-CN.json`:信任设置与发送历史文案

### 信任模型引擎批次(2026-10-12,Stage 2-A)

- `app/lib/model/persistence/favorite_device.dart`:新增 `TrustLevel/QuotaMode` 枚举与 trustLevel/blocked/maxFileSize/quotaMode/quotaValue/ownerId/ownerName 字段(旧条目反序列化默认 full,保持上游 quickSaveFromFavorites 行为连续)
- `app/lib/model/persistence/receive_history_entry.dart`:新增 `senderFingerprint`(配额统计键)
- `app/lib/util/trust_evaluator.dart`(新增):纯函数信任判定链
- `app/lib/provider/trust_provider.dart`(新增):按指纹聚合已用量 + 磁盘容量查询(占比模式)
- `app/lib/provider/network/server/controller/receive_controller.dart`:prepare-upload 挂判定链(超限自动拒绝);两处 quickSaveFromFavorites 收紧为仅 full;历史写入携带指纹
- `app/lib/provider/receive_history_provider.dart`:Action 增加可选 senderFingerprint
- `app/test/unit/util/trust_evaluator_test.dart`(新增):10 个判定链单测

**明确保留(不计入修改义务,均为内部标识或互操作所必需)**
- Dart 包名 `localsend_app`(app/pubspec.yaml 的 `name`)及全部 `package:localsend_app/*` import:内部代码标识,非用户可见;保留以最小化 rebase 成本
- 协议常量:端口 53317、`/api/localsend/v2/*` 路径、组播组 224.0.0.167 —— LocalSend protocol v2.2 互操作所必需
- Rust crate 名 `rust_lib_localsend_app` 及其产物名:内部构建标识
- 平台通道名 `org.localsend.localsend_app/platform`(Dart↔Linux native 内部协议,两端一致)
- 持久化键前缀 `ls_*`、主题枚举 `ColorMode.localsend`(已持久化取值,改名破坏设置迁移)
- `app/assets/CHANGELOG.md`:上游历史版本记录,保留作为溯源
- macOS entitlements 中 `AppIdentifierPrefix` 与 `TeamIdentifierPrefix` 的差异:上游原始状态,原样保留
- 上游 issue 链接注释(代码注释中的出处引用)

## 待办(TODO)

- [ ] 全套应用图标/启动图替换(不得复用上游图形资产)——首次对外分发前必须完成
- [x] 应用内 About 页与 pubspec homepage 切换为 AnyShare 自有仓库 URL(已完成:github.com/sunmerx/AnyShare)
- [x] Inno 安装器 AppId GUID 更换(已完成,见"安装器 AppId 批次 2026-10-13")
- [ ] `support/scripts` 打包脚本的仓库目录名假设与 MSIX 逻辑复核 —— Stage 5
