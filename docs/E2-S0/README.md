> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# E2-S0:屏幕共享(已下线)

本目录记录 2026-10 期间的屏幕共享与内嵌远程桌面(RustDesk)设计、实现细节、性能优化与验收数据。对应的代码已整体移除,文中提到的模块、端点、常量与配置项**都不再存在于当前代码中**:

| 文中提到 | 当前状态 |
| --- | --- |
| `packages/screen-stream`、`packages/remote_desktop` | 已删除 |
| `third_party/rustdesk` 子模块 | 已删除 |
| FRB `screen` / `screen_control` / `mouse` / `remote_desktop` API | 已删除 |
| 控制面 TLS 专线(53320)、`/api/anyshare/v1/screen/*`、`/api/anyshare/v1/input/*` | 已删除 |
| `screen_provider`、投屏会话状态/横幅、`screen_capabilities`、`screen_trust` | 已删除 |
| Android 屏幕接收(MediaCodec/SurfaceView)、无障碍注入服务 | 已删除 |

保留的能力(配对、信任分级、同归属者、共享目录、WebRTC 文件传输)不受影响。

以下目录外的文档仍包含已下线功能的描述,阅读时请以当前代码为准:

- `docs/UI实施计划.md`
- `docs/UI重设计-需求与界面设计.md`
- `docs/详细设计文档.md`
- `docs/实施计划.md`
- `docs/验收记录/`
- `docs/屏鼠共享专项评估.md`

保留这部分文档是为了记录当时的设计取舍与实测数据(例如 VFR、FEC/NACK、控制面 TLS 的踩坑),便于将来若重新引入类似能力时参考。
