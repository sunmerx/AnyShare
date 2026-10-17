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
