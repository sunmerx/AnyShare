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
