# macOS 实验包(S0-②,待用户在 VM/云 Mac 执行)

> 目标:验证「无签名分发 + 辅助功能授权」链路下,CGEvent 注入与捕获可行(评估文档 §2.1/§2.2 的灰区)。
> 工具:`spike.swift`(单文件,无依赖,本机编译)。

## 环境要求

- macOS 11+(Big Sur)以上均可;Intel/Apple Silicon 都行
- Xcode Command Line Tools(`xcode-select --install`)提供 `swiftc`
- **不需要** Apple Developer 账号、不需要签名/公证(这正是要验证的路径)

## 执行步骤

```bash
# 1. 编译(在 Mac 上,把 spike.swift 拷过去)
swiftc spike.swift -o spike

# 2. 授权前状态
./spike status
# 预期第一次:accessibility trusted: false / event tap creatable: false

# 3. 授予辅助功能权限
#    打开 系统设置 → 隐私与安全性 → 辅助功能,把终端(Terminal/iTerm)加进去并勾选

# 4. 再次检查
./spike status
# 预期:trusted: true / creatable: true

# 5. 注入测试(tap 会真的点击屏幕坐标,选安全位置)
./spike tap 500 500
./spike move 100 0
./spike type "hello-from-any share-spike"

# 6. 捕获测试(运行后 10 秒内移动鼠标、按几个键)
./spike listen 10
# 预期:stderr 逐条输出 event type/pos/时间戳
```

## 记录表(执行后回填)

| 检查项 | 预期 | 实测 |
|---|---|---|
| 未授权时 `status` | false/false | |
| 授权弹窗路径(系统设置手动勾选) | 可完成,无需重启工具 | |
| 授权后注入鼠标 | 光标移动/点击生效 | |
| 授权后注入文本 | 目标输入框收到文本 | |
| `listen` 事件回传 | 鼠标/键盘事件可见,时间戳间隔合理 | |
| **Secure Input 场景**:在密码框中聚焦时注入 | 预期受限(记录现象即可) | |
| 无签名工具首次运行 | 本地编译产物可直接运行(无 Gatekeeper 拦截) | |

## 注意事项

- 若从网盘等渠道下载本工具再运行,需 `xattr -d com.apple.quarantine spike`;本地编译不涉及
- 捕获/注入均要求终端进程被授予辅助功能权限(产品实现时是 AnyShare.app 自身申请)
- 结果(尤其失败模式截图/文字)记录到本目录,或直接回复给主会话整理进 `S0报告.md`
