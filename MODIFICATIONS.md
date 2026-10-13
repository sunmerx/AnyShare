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
- [ ] 应用内 About 页与 pubspec homepage 切换为 AnyShare 自有仓库 URL(仓库创建后回填)
- [ ] Inno 安装器 AppId GUID 更换(新产品身份)——Stage 5 打包时
- [ ] `support/scripts` 打包脚本的仓库目录名假设与 MSIX 逻辑复核 —— Stage 5
