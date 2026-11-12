> **已废弃(2026-11-12)**:屏幕共享/键鼠共享功能已下线,本目录仅作历史记录;见 [MODIFICATIONS.md](../../MODIFICATIONS.md) 的「下线屏幕共享与键鼠共享」一节。

# 控制面 TLS 设计(启用数据面加密的前提)

> 自包含设计文档。仓库 `E:\code\AnyShare`,分支 `anyshare`。
> 目标:让屏幕共享的**控制面**(发起/接受/停止/关键帧/码率/帧率反馈)走 TLS,
> 并让双方用**证书指纹**确认对端身份,从而可以安全地在 offer 里携带数据面 AES 密钥。

---

## 1. 现状与问题

| 通道 | 端口 | 当前安全状态 |
|---|---|---|
| 屏幕数据面(H.264 over UDP) | 53319 | AES-256-GCM **已实现但未启用**(等本项) |
| 屏幕控制面 `/screen/*` | 53318 | **明文 HTTP**;`/screen/offer` 信任请求体里的 `fingerprint` 自述 |
| 文件传输 / 目录浏览 `/dir/*`(在本仓库实现里同样挂在 53318) | 53318 | 明文 HTTP |
| 核心 Rust HTTP(文件/发现) | 53317 | 双向证书 TLS(不受本项影响) |

因此:若现在把 AES 密钥放进 offer,同网段嗅探者可直接拿到密钥,加密无效;
同时 `/screen/offer` 允许任何人伪称任意指纹,存在冒充风险。

---

## 2. 目标与非目标

**目标**
1. `/screen/*` 的请求与响应在 TLS 上传输(机密性 + 完整性)。
2. 双向身份认证:服务端要求客户端证书;客户端校验服务端证书的 **SHA-256 指纹**等于预期对端指纹。
3. 对端身份以 **连接层证书** 为准,不再信任请求体的 `fingerprint` 字段。
4. 完成后在 `/screen/offer` 中恢复携带数据面密钥,发送端/接收端引擎启用 AES-GCM。

**非目标(保持现状)**
- 不改动 53317 的核心 TLS 服务,不改动文件传输协议。
- 不引入公网 CA:沿用设备自签证书 + 指纹固定(pinning),与现有配对/信任模型一致。

---

## 3. 方案:屏幕专用 TLS 端口(53320)

### 3.1 为什么单独端口而不是把 53318 整体 TLS
53318 上还挂着 `/pair/*`、`/dir/*` 等路径,它们各自有客户端与测试;整体改 TLS 的影响面远大于本项
目标。屏幕控制路径独立成 53320 后:

- 只有屏幕流程需要改客户端/服务端;
- 其他路径保持现有行为,回归风险最小;
- 旧的 53318 `/screen/*` 路由**保留一个版本周期**,但**不携带密钥**、且接收端在 TLS 可用时忽略其 offer。

### 3.2 服务端(Rust 终止 TLS + Dart 回环处理器)
> **实施修订(2026-10-27)**:Dart `HttpServer.bindSecure(requestClientCertificate: true)` 会校验证书链,
> 未预置信任锚的自签客户端证书会直接握手失败,无法实现"任意自签设备证书"的 mTLS。
> Rust core 的 `CustomClientCertVerifier` 本身就是"验签但接受任意合法证书",因此 53320 的 TLS 移到 Rust。

1. `packages/core/src/http/screen_proxy.rs` 用本机证书/私钥在 53320 起 mTLS 监听(强制客户端证书),
   把请求回环转发到 Dart 的 `127.0.0.1` 处理器;转发前注入
   - `x-anyshare-peer-fingerprint` = `sha256(客户端证书 DER)` 大写十六进制
   - `x-anyshare-peer-ip` = TLS 连接看到的真实对端地址
2. Dart 侧只绑定回环 `HttpServer`(随机端口),并且**只信任来自回环**的上述头:
   - 无指纹头 → 403 `tls_required`;
   - 只处理 `/api/anyshare/v1/screen/*`,其余 404;
   - 用证书指纹作为对端身份去查信任/收藏(替换 `body['fingerprint']`);
   - 其余逻辑复用现有 screen 处理器(把"取 body 指纹"改成"传参指纹")。
3. 启动失败(端口占用/证书不可用)时记录错误并**不阻塞**应用启动:关闭回环处理器,TLS 前端保持不可用;
   屏幕共享报明确错误,不静默走明文。

### 3.3 客户端(Dart,`postScreenControl`)
1. 调用方必须提供 `expectedFingerprint`(预期对端的证书指纹)。
2. 构造客户端:
   ```dart
   final ctx = SecurityContext(withTrustedRoots: false)
     ..useCertificateChainBytes(utf8.encode(certPem))
     ..usePrivateKeyBytes(utf8.encode(keyPem));
   final client = HttpClient(context: ctx)
     ..badCertificateCallback = (cert, host, port) {
        final fp = sha256Hex(cert.der).toUpperCase();
        return fp == expectedFingerprint;   // 指纹固定,不做 PKI 验证
     };
   final request = await client.postUrl(Uri.parse('https://$host:$kScreenSecurePort/...'));
   ```
3. 服务端指纹不匹配 → 请求失败并上报用户可见错误("对端证书指纹不匹配"),**不降级**为明文。
4. 超时保持现状(连接 5s、请求 10s)。

### 3.4 指纹来源(状态改动)
- `ActiveScreenSession` 增加 `peerFingerprint`(发送/接收两侧都要);
- `WaitingScreenAccept`、`PendingScreenOffer` 已有/增加 `peerFingerprint`;
- UI 入口(`device_details_page` / 设备列表 / 我的设备)调用 `StartScreenShareAction` 时传入
  `device.fingerprint`;
- `IncomingScreenAcceptAction` 使用 `waiting.peerFingerprint`;`/screen/accept` 回调再带回来(校验一致)。

### 3.5 完成后启用数据面加密
1. `HandleScreenOfferAction` 从 TLS offer 里读 `key`,校验 64 hex;接收端引擎
   `startReceiver(keyHex: key)`。
2. 发送端 `StartScreenShareAction` 恢复生成密钥并放进 offer,`startSenderSession(keyHex: key)`。
3. 关闭 53318 上的 `/screen/*`:返回 `421 upgrade_required`。

---

## 4. 威胁分析

| 威胁 | TLS 前 | TLS 后 |
|---|---|---|
| 同网段嗅探屏幕内容 | 明文 H.264 可还原 | AES-GCM 密文(密钥经 TLS 分发) |
| 冒充可信设备发起共享 | 伪造 body 指纹即可 | 需持有对应证书私钥(指纹固定校验) |
| 中间人替换密钥 | 不适用(无密钥) | 客户端 pin 服务端指纹;服务端要求客户端证书 |
| 篡改控制指令(如码率) | 可篡改 | TLS 完整性保护 |
| 重放旧的 offer | 可重放 | TLS 会话 + 现有 sessionId/信任校验;数据面另有会话号 |

残余风险(需记账):
- 指纹来源仍是"配对/发现"阶段的信任,配对本身的安全性取决于既有 QR/SAS 流程;
- 老版本对端不支持 53320 时,屏幕共享会明确失败而不是降级(可接受,优于静默明文)。

---

## 5. 实施步骤(建议按此顺序,每步可独立编译/测试)

1. **状态与指纹**:`ActiveScreenSession`/`WaitingScreenAccept` 增加 `peerFingerprint`,
   UI 三处入口传入;`postScreenControl` 增加必填 `expectedFingerprint`(先仍走 http,忽略该参数)。
   跑 `flutter test`。
2. **服务端 53320**:`bindSecure` + 客户端证书;新增处理器复用现有 screen 分支(身份取自证书);
   老 53318 的 `/screen/*` 暂时保留。手工验证:用 `openssl s_client` 携带客户端证书访问
   `/api/anyshare/v1/screen/offer` 得到 409/403 等预期响应。
3. **客户端 https**:`postScreenControl` 切到 53320 + 指纹 pin;测试里的 stub peer 同步改为
   TLS 服务器(测试用固定自签证书 PEM 放 `app/test/fixtures/`),`screenControlPortProvider`
   改指 53320。
4. **启用密钥**:offer 携带 `key`,两端引擎传 `keyHex`;验证 `auth_fail=0` 且抓包不可读。
5. **关闭旧路**:53318 `/screen/*` 返回 421;更新文档与回归脚本。

---

## 6. 测试与验收清单

**自动**
- `flutter analyze` 0 issue;`flutter test` 全绿(含新 stub TLS peer)。
- `cargo test --features viewer`(52 项)保持全绿(本项不改 Rust 协议,仅参数传递)。
- 新增 Dart 用例:
  - offer 走 https 且服务端指纹不匹配时**不发送**(fail-closed);
  - 服务端拒绝无客户端证书的请求(403 `tls_required`);
  - 收到的 offer 指纹来自**连接证书**而非 body(篡改 body 不影响信任判定)。

**人工**
| 编号 | 步骤 | 通过标准 |
|---|---|---|
| G1-M1 | 双机正常共享 | 画面正常;`auth_fail=0` |
| G1-M2 | 用错误指纹的客户端访问 53320 | 请求失败,日志明确;不建立会话 |
| G1-M3 | Wireshark 抓 53318/53320/53319 | 控制面不可读;数据面密文无 NAL 特征 |
| G1-M4 | 旧版本对端(改造前构建)发起共享 | 明确报错(不降级明文) |

---

## 7. 当前状态
- 数据面 AES-256-GCM 已实现并 CLI 验证(见 `docs/E2-S0/串流数据面加密.md`),**应用侧未启用**。
- 第 1 步(指纹贯通)、第 2 步(53320 mTLS)、第 3 步(客户端 https + 指纹 pin)已完成:
  - 53320 的 TLS 由 Rust `screen_proxy` 终止(Dart 无法接受任意自签客户端证书),回环转发 Dart 处理器;
  - `postScreenControl` 全部走 https,无预期指纹不发送,证书不匹配 fail-closed;
  - Ubuntu 实测:带证书请求回显客户端指纹,无证书握手失败;243 Dart 测试、core Rust 测试全绿。
- 第 4 步已完成:发送端生成 64 hex 会话密钥并随 TLS offer 发送,双方引擎 `keyHex` 启用 AES-256-GCM;
  明文 53318 的 offer 忽略 `key`。真实双机 `auth_fail=0` + 抓包不可读待人工验收。
- 第 5 步已完成:53318 的 `/screen/*` 全部返回 421 `upgrade_required`,屏幕控制只剩 53320 的 mTLS 监听;
  旧版本对端明确失败,不降级明文。
- 剩余人工验收:G1-M1/M3(双机 `auth_fail=0`、抓包不可读)、G1-M4(旧版本对端明确报错)。
