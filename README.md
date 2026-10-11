# AnyShare

局域网跨平台文件互传工具:Windows / Linux / macOS / Android / iOS / **HarmonyOS**。

基于开源项目 [LocalSend](https://github.com/localsend/localsend)(Apache License 2.0,Copyright 2022-2026 Tien Do Nam)二次开发。

> **Attribution / 声明**:This project is a fork of [LocalSend](https://github.com/localsend/localsend), licensed under the [Apache License 2.0](LICENSE). Modifications are tracked in [MODIFICATIONS.md](MODIFICATIONS.md). All LocalSend trademark rights remain with its authors; this project is an independent fork and is not affiliated with the LocalSend team.

## 与上游的差异(AnyShare 增量)

1. **HarmonyOS NEXT 原生移植**(上游不支持鸿蒙);
2. **深度系统集成**:微信 / QQ / 系统文件管理器"分享到"直达、桌面右键菜单、扫码直连;
3. **信任分级**:配对时可选「临时传输 / 加入信任列表」,一般信任可设单文件大小上限与接收容量限制(绝对值 / 磁盘占比 / 不限),同一归属者设备间无限制;
4. 中文体验与国产 ROM 适配。

## 许可证

本项目遵循 [Apache License 2.0](LICENSE)。对上游代码的修改均已在 [MODIFICATIONS.md](MODIFICATIONS.md) 登记。

## 构建

```bash
cd app
flutter pub get
flutter run -d <device>
```

各平台打包方式见上游文档(README 的 Building 一节随上游维护),鸿蒙构建文档见 `docs-harmony/`(待补)。
