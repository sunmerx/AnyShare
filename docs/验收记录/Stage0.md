# Stage 0 验收记录(Fork 基建与合规改造)

| | |
|---|---|
| 日期 | 2026-10-11 |
| fork 基点 | localsend/localsend `14f3a874`(main) |
| 分支模型 | `main` 跟踪 upstream(只同步不修改);`anyshare` 长期工作分支 |
| 提交 | `f5a3fcc1` 合规基线、`70a48d29` 品牌替换(164 文件,±1466 行) |

## WP 完成情况

| WP | 状态 | 证据 |
|---|---|---|
| WP0-1 分支基线 | ✅ | git branch -vv:main→upstream/main;anyshare 从基点切出;`docs/`、`.secrets/` 经 `.git/info/exclude` 本地隔离(内部 PRD/计划不入公共仓库) |
| WP0-2 合规 | ✅ | LICENSE 原样保留;README 首屏 fork 声明(Apache-2.0 + 版权归属);MODIFICATIONS.md 完整索引;上游无 NOTICE 文件(无该项义务) |
| WP0-3 品牌 | ✅(图标待办) | 见 MODIFICATIONS.md 品牌批次;终验七点全部通过:窗口标题(Windows/Linux)、Android applicationId=io.anyshare.app、macOS PRODUCT_NAME、BINARY_NAME=anyshare_app、web 接收页、i18n 57 语言、gen 生成代码 |
| WP0-4 构建环境 | ✅ 本机 | Flutter stable 已装(E:\flutter);VS 2019/2022 企业版含 C++ 桌面负载(Windows 端可本地构建);Android SDK 未装(Stage 1 前补);鸿蒙 DevEco 待装(Stage 4 前) |
| WP0-5 真机回归 | ⏳ | 需 Android 真机(USB 调试)+ Windows 本机;待 pub get/analyze 通过后出包安装 |

## 残留白名单(确认非用户可见/互操作必需)

`package:localsend_app` dart 包名与 import;协议常量(53317、`/api/localsend/v2/*`、组播 224.0.0.167);Rust crate `rust_lib_localsend_app`;平台通道 `org.localsend.localsend_app/platform`(Dart↔Linux 双端一致);持久化键 `ls_*`;枚举 `ColorMode.localsend`(已持久化);上游 CHANGELOG 历史;issue 链接注释;Inno AppId GUID(Stage 5 换新)。

## 运行时一致性核查(已通过)

- macOS app group:Runner/DebugProfile/ShareExtension entitlements 与 Shared.swift 全部 = `anyshare.shared_group`(前缀变量差异为上游原状)
- iOS app group:Runner + ShareExtension = `group.io.anyshare.app`
- Android namespace/applicationId/MainActivity 包路径三者一致(io.anyshare.app)
- `_windowsLegacyFile` 旧数据迁移路径保持 `org.localsend\localsend_app\`(有意保留)

## 关键决策(实施偏差记录)

1. **不重命名 Dart 包名 `localsend_app`**:非用户可见,改名波及数百 import、增加上游 rebase 成本 —— 已登记 MODIFICATIONS.md
2. **协议路径/端口原样保留**:与 LocalSend 互通是 PRD v0.4 明确收益
3. **`prepare` 阶段未动任何协议逻辑**:Stage 0 仅品牌与合规,代码逻辑零改动(diff 统计 ±1466 行对称,全部为字符串/标识替换)

## 遗留与下一步

- [ ] Android SDK 安装(cmdline-tools + platform-tools + JDK 配置)
- [ ] 图标/启动图占位设计(首次分发前必须)
- [ ] 远程仓库创建(GitHub fork 公开 vs 私有镜像)→ 待用户决策
- [ ] git 提交身份为占位(anyshare-dev@users.noreply.github.com)→ 待用户提供
- [ ] WP0-5 真机回归(Win+Android 互传)
- [ ] Stage 1:上游代码研读(WP1-1 架构地图、PIN/持久化/分享入口挂点)

## 补充(2026-10-11 晚,WP0-4 验证结果)

**依赖解析与静态验证(镜像)**
- 直连 pub.dev 过慢(HEAD 6s,首次解析 10min 未完成)→ 切国内镜像:`PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`,**后续所有 flutter/dart 命令必须带此环境变量**(Bash 不跨调用持久化,已写入本记录供每 Stage 开工引用)
- `flutter pub get` ✅(exit 0);`dart analyze` ✅ **0 错误**(仅 1 条上游 analysis_options 既有弃用 warning,与品牌替换无关)
- `flutter test` ✅ **88/88 全部通过**(含 shared_preferences_portable、discovery、server 行为等既有套件)→ **Stage 0 WP0-4 验证完整收官:品牌替换零破坏**

**构建环境结论**
- Windows 桌面构建可用:VS 2022 Enterprise 含 C++ 桌面负载 ✅
- **阻塞项:Windows 开发者模式未开启**(Flutter 插件 symlink 需要)→ 需用户在 `ms-settings:developers` 打开"开发人员模式",或以管理员执行注册表开关
- Android SDK 未安装;JDK 25 已在 PATH(对 Android Gradle 偏新,届时按需装 JDK 17)

## WP0-5 前置:双端构建打通(2026-10-12)

**Windows Release ✅** `app/build/windows/x64/runner/Release/anyshare_app.exe`(全依赖含 rust_lib_localsend_app.dll)
**Android Release ✅** `app/build/app/outputs/flutter-apk/app-release.apk`(121.6MB,arm32/arm64/x86/x64 四 ABI,AnyShare 密钥签名)

修复链(全部已提交):
- `2ec47733` Windows:manifest 随 BINARY_NAME 重命名;msix helper 改条件安装;**CJK Windows 必须 `CL=/utf-8`**(C4819 警告即错误)
- `5af3dd94` Android:全部 .kt 包名统一 io.anyshare.app(此前仅 MainActivity 迁移,同目录其余文件残留旧包)
- gradle.properties:Flutter 迁移器自动写入 `android.newDsl=false`/`builtInKotlin=false`(版本偏移兼容,保留)
- `.gitignore` 补 `app/android/build/`(上游遗漏,problems-report.html 曾误入提交已移除)

**环境事实(每 Stage 开工必读)**:
- **Flutter 必须用上游锁定版 3.41.9**(`.fvmrc`);E:\flutter 已切 `local-3.41.9` 分支(3.47.7 会触发 android.newDsl 不兼容)
- Android 命令统一带 `JAVA_HOME=E:\jdk17\jdk-17.0.20.1+1`(系统 PATH 的 JDK 25 会让 Gradle 8.13 报错 "25.0.3")
- Android 签名:`app/android/key.properties`(git 忽略)→ `E:\secrets\anyshare-android.jks`(alias=anyshare);**此密钥即 AnyShare 正式 Android 签名身份,勿删**
- Gradle 发行包已缓存官方源(services.gradle.org 下载完成 232MB);腾讯镜像曾致损坏,勿再切换
- Maven 依赖已全量入 ~/.gradle(6GB);NDK 2.2GB 已装 /e/android-sdk
- rust 交叉编译走 cargokit(自动调用 PATH 中的 cargo)

## WP0-5 真机基线回归(2026-10-12,✅ 通过)

**环境**:OPPO PKX110(Android,192.168.1.123,Wi-Fi)↔ Windows 桌面(192.168.1.179,同子网);双端均为 fork 后产物。

| 步骤 | 结果 |
|---|---|
| APK 安装 | ✅(ColorOS 需手动确认一次 USB 安装) |
| 启动 | ✅ 中文 UI、随机设备名"巨大的番茄"、接收/发送/设置三页正常 |
| **双向发现** | ✅ 手机"附近的设备"列出电脑"善良的鳄梨"(Windows 徽标);组播通告+HTTP 应答链路通 |
| **手机→电脑传输** | ✅ anyshare-test.txt(67B):TLS 验证徽标、发送页"已完成"、电脑日志 Saved + Received all files |
| 完整性 | ✅ 与源文件逐字节一致(diff 通过) |
| 元数据 | ✅ mtime 端到端保留(接收文件时间=源文件创建时间) |
| 反向(电脑→手机) | 待用户配合操作 PC 窗口后补测 |

**过程中发现并修复的真 bug**:FRB 版本错位导致双端启动即崩(提交 747dedf8,详见上文)。

**观察记录**:① ColorOS 安装器对 adb 安装需人工确认;② 手机熄屏时 Flutter 引擎暂停,测试需亮屏;③ Git Bash 会把 `/sdcard/...` 转换为本地路径,adb push 需用 `//sdcard/...`;④ 设备卡"HTTP"徽标为发现通道,实际传输走 HTTPS 并有"验证"标;⑤ 电脑多网卡(VMware/WSL/Clash 虚拟网卡 198.18.x)未阻碍发现。

## 下一步

- [ ] WP0-5:手机安装 APK + Windows 安装 exe,基线互传(发现/PIN/传输)
- [ ] 推送 anyshare 分支至 origin
- [ ] Stage 1 收尾研读(WebRTC/IsolateManager)→ Stage 2 信任模型实现

## WP1-1 研读首批发现(Stage 1 提前渗入)

- 上游已将 **HTTP 服务器下沉到 Rust**:`packages/core`(crate,含 prepare-upload/PIN/单会话约束)→ flutter_rust_bridge(`packages/localsend_isolates`)→ Dart 事件流(`HttpServerPrepareUploadEvent` 等);Dart 侧只做策略与 UI
- **信任模型挂点确认**:`receive_controller.dart onPrepareUpload` 的 quickSave 判定块(L129–140);上游已有的 `favoritesProvider` + `quickSaveFromFavorites`(指纹匹配自动接收)即"信任设备"雏形,我们的临时/一般/完全/同归属者判定链在此扩展;信任锚 = mTLS 证书指纹(`event.certFingerprint`,与 DDD 4.3 一致)
- 设备持久化:上游 favorites 存 `ls_favorites`(shared_preferences JSON,非 SQLite)→ 信任分级数据模型按 SP 扩展键设计(修订 DDD 3.2 的 SQLite 假设),或评估迁 SQLite(Stage 1 WP1-4 定)
- PIN 校验在 Rust 侧 → AnyShare SAS/信任扩展走 Dart 侧挂点,Rust crate 不动,与"修改面最小化"一致
