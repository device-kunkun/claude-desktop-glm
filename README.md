# Claude Desktop × GLM：让 Cowork 沙箱跑第三方模型的完整逆向报告

> **English TL;DR**: Claude Desktop (MSIX, 2.2553.1) silently blocks non-Anthropic models on its custom "3P gateway" deployment at *five* independent layers: `/v1/models` family filtering, a picker-side route validator, per-session model resolvers (chat & code), an Electron ASAR-integrity fuse, and a WinVerifyTrust + certificate-thumbprint pin inside the Cowork VM service (`cowork-svc.exe`). This repo documents all five gates with code evidence, and ships two working workarounds: (A) a zero-patch gateway proxy injecting `anthropic_family_tier` / masquerading model ids, and (B) a full local patch kit (equal-length binary patches + fuse flip + local re-signing). **Use at your own risk — this violates Anthropic's ToS and may get your account banned.**

---

> ⚠️ **免责声明**
> 本项目仅为技术研究与个人本地互操作用途。修改客户端二进制与绕过模型限制**违反 Anthropic 服务条款**，可能导致账号受限或封禁。仓库中不含任何 Anthropic 代码或二进制，仅含补丁脚本与原理说明。请自行权衡风险。
> 另：**请勿通过 Windows「设置 → 应用 → 移动」把 Claude Desktop 挪到其他盘**——这是本报告第 6 节一系列问题的总根源。

## 成果

| 能力 | 状态 |
|---|---|
| Claude Desktop (MSIX 2.2553.1) 模型选择器显示 GLM 全系模型 | ✅ |
| 聊天 / Code 会话使用 GLM-5.3 / GLM-5.3-Flash（智谱开放平台） | ✅ |
| Cowork 沙箱会话创建、RPC 管道建立 | ✅ |
| 全程直连 `open.bigmodel.cn`，无本地常驻代理 | ✅ |

---

## 背景：桌面端的"网关"架构

Claude Desktop 内置一个面向企业客户的 **custom-3p 部署模式**：应用不从 `claude.ai` 登录，而是读取

```
%LOCALAPPDATA%\Claude-3p\configLibrary\<uuid>.json
```

```jsonc
{
  "inferenceProvider": "gateway",
  "inferenceCredentialKind": "static",
  "inferenceGatewayBaseUrl": "https://open.bigmodel.cn/api/anthropic", // 任何兼容 Anthropic Messages API 的端点
  "inferenceGatewayApiKey": "<你的智谱 API Key>"
}
```

外层 `claude_desktop_config.json` 需要 `"deploymentMode": "3p"`。这套机制本身是**官方给企业 LLM 网关留的**（社区已有 [LiteLLM](https://docs.litellm.ai)、[TrueFoundry](https://www.truefoundry.com) 等接入文档，开发者模式下也有第三方推理配置入口）。

端点与认证都能官方解决。**真正的问题是：模型。**

---

## 六层防线逆向

以下代码片段均提取自 `app.asar`（2.2553.1.0，明文 JS）与 `cowork-svc.exe`（Go 1.25）。

### 第 1 层：`/v1/models` 家族过滤（发现阶段）

```js
c = a.data.flatMap(e => {
  let t = e ? CPt(e.id) : void 0;
  if (!e || !t) return [];                    // CPt 只校验"字符串且 ≤255 字符"
  let n = o(e.anthropic_family_tier);         // 必须 ∈ ["sonnet","opus","haiku","fable","mythos"]
  if (!Go(t.id) && !n) return [];             // ← id 不匹配 Anthropic 家族 且 无 tier 字段 → 丢弃
  ...
```

- `CPt` 并不检查前缀，**真正的闸是 `!Go(t.id) && !n`**。
- 官方留了旁路口：模型条目带 `"anthropic_family_tier": "opus"` 等字段即可通过——这就是零补丁路线的理论基础。
- 日志表现：`[custom-3p] Gateway /v1/models returned 0 usable models { rawCount: 11 }`

**补丁①**（等长 13 字节）：`!Go(t.id)&&!n` → `!1&Go(t.id)&n`（恒为假，永不过滤）。

### 第 2 层：picker 最终过滤

发现通过的模型在构建选择器时还要过一道：

```js
return e ? a.filter(t => Ko(e, t.id).ok) : a
```

`Ko(provider, id)` 按 provider 分派到 `Yxe(t)`：

```js
function Yxe(e){ return Go(e) ? {ok:!0} : {ok:!1,
  reason:"expected a gateway model route referencing an Anthropic model (e.g. claude-sonnet-4-5, anthropic/claude-*). Name routes to match the underlying model."}}
```

即 **gateway 通道在设计上只接受"指向 Anthropic 模型的路由"**，无任何配置绕过（`anthropic_family_tier` 在这一层不起作用）。

**补丁②**（等长 13 字节）：`Ko(e,t.id).ok` → `""+Ko(e,t.id)`（对象拼接恒真值，过滤失效，Ko 仍被调用、无副作用）。

### 第 3 层：会话模型解析（两个变体）

即使 picker 里能选，`start_session` / `set_model` 时还有一层：

```js
let i = r.validateSessionModel(e, Tin());
if (i.ok) return e;
// 否则: N.warn(`[resolveSessionModel] ... rejected (${i.reason}); falling back to default`)
//       → 静默回退到默认模型！
```

这就是"**界面显示 GLM-5.3-Flash，实际跑的是 GLM-4.5**"的原因：选择被拒后静默回退。Code 会话有一份对称实现 `[resolveCodeSessionModel]`。

**补丁③/④**（等长 7 字节 ×2）：`i.ok?e:` → `!0+0?e:`、`a.ok?e:` → `!0+0?e:`（恒采纳用户所选模型）。

### 第 4 层：Electron ASAR 完整性 fuse

新版启动器分发的二进制带 fuse `EnableEmbeddedAsarIntegrityValidation = ENABLED`（PE 内嵌 fuse 表：哨兵 `dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX` + 状态字节，状态以 ASCII `'0'/'1'/'2'` 表示）。修改 `app.asar` 后启动即报：

```
ASAR Integrity Violation: got a hash mismatch (41677691... vs dfe50aee...)
```

**补丁**：fuse 表中 `AsarIntegrity` 状态字节 `'1'` → `'0'`（1 字节）。fuse 关闭后，上面 4 处 asar 补丁才能生效。

### 第 5 层：cowork-svc 客户端校验（签名 + 指纹固定）

Cowork 的后台服务（Go 1.25，基于 gvisor-tap-vsock）对连接的客户端做两步校验：

1. `WinVerifyTrust`（wintrust.dll）——要求客户端 exe 有**有效受信签名**；
2. **证书指纹固定**——客户端签名证书的 thumbprint 必须等于期望值（运行时确定的 Anthropic 特定证书）。

失败表现：`[vm-client] signature verification failed: client certificate does not match service (client thumbprint: ..., expected: dbde5d16...)` → **VM 的 RPC 管道直接拒绝** → `Failed to start Claude's workspace: RPC pipe closed`。

本地解法分两步：

- **翻转 claude.exe 的 fuse**（1 字节）使 asar 补丁可启动——但这会破坏 claude.exe 的原始签名；
- **本地自签重签**：`New-SelfSignedCertificate -Type CodeSigningCert` 生成证书 → 导入 `LocalMachine\Root` + `TrustedPublisher`（WinVerifyTrust 因此判定受信）→ `Set-AuthenticodeSignature` 重签两个 exe；服务自身的启动自校验同理。
- **指纹固定那一层无法用证书伪造**（需要 Anthropic 私钥），期望值也不在本地任何文件中（运行时确定）。因此对 `cowork-svc.exe` 做了 6 字节原生补丁：`jne <success>`（`0F 85 60 02 00 00`）→ `jmp <success>`（`E9 61 02 00 00` + `90`），恒走成功分支。定位方法：搜索错误字符串 → 解析 PE 计算 VA → 扫描 `.text` 中指向该 VA 的 `lea rip-relative` 引用 → capstone 反汇编回溯比对分支。

### 第 6 层（附加坑）：MSIX 移动应用的路径陷阱

通过「设置 → 应用 → 移动」把 Claude Desktop 挪到其他盘后：

- 原注册路径变成指向新位置的 **junction**；
- 应用把自身路径规范化为真实路径（E:\...），而 cowork-svc 按注册路径（C:\...）做字符串比对 → **一切 VM RPC 永久失败**；
- VM 运行时还会拒绝 junction 路径的镜像文件（`refusing to open: is a symlink or junction`）。

**结论：装回 C 盘真目录，永远不要移动这个应用。** 需要腾空间的是数据目录和 VM 镜像（见 FAQ）。

---

## 两条落地方案

### 路线 A：零补丁（网关代理 + 模型名伪装，社区主流）

原理：让网关在 `/v1/models` 里**只返回 Anthropic 形状的模型名**（如 `claude-sonnet-4-5`），并在 `/v1/messages` 里把它们映射回真实 GLM 模型。三层校验全部天然通过，fuse 不用碰。

`gateway-proxy/proxy.mjs` 是一个最小实现（Node ≥18）：

1. `start.bat` 启动（监听 `127.0.0.1:8787`）；
2. configLibrary 的 `inferenceGatewayBaseUrl` 指向 `http://127.0.0.1:8787`；
3. 代理把 bigmodel 的模型列表注入 `anthropic_family_tier` 字段并透传其余请求。

想更进一步"零补丁 + 零代理"：新版（1.44121.2+）的网关配置已官方支持 `models` 字段直接声明模型列表并跳过发现流程；或者让代理把模型名伪装成 `claude-*`（智谱端点本身也接受 claude 系名字）。

### 路线 B：本地补丁全家桶（本仓库脚本，真实模型名直连）

适用：2.2553.1.0 MSIX。**管理员 PowerShell** 依次执行：

```powershell
# 0) 备份（重要！）
$pkg  = Get-AppxPackage -Name Claude
Copy-Item (Join-Path $pkg.InstallLocation 'app\resources\app.asar') .\app.asar.official.bak
Copy-Item (Join-Path $pkg.InstallLocation 'app\resources\cowork-svc.exe') .\cowork-svc.exe.bak

# 1) 关应用
Get-Process claude | Where-Object { $_.Path -like '*WindowsApps*' } | Stop-Process -Force

# 2) 四闸 asar 补丁（自动触发 UAC）
powershell -File patches\repatch-fresh.ps1

# 3) 关 ASAR 完整性 fuse（UAC）
powershell -File patches\fuse-flip.ps1

# 4) cowork-svc 指纹比对补丁（UAC）
powershell -File patches\svcpatch.ps1

# 5) 对 claude.exe + cowork-svc.exe 重签（UAC）
powershell -File patches\resign.ps1

# 6) 启动
Start-Process ("shell:AppsFolder\" + $pkg.PackageFamilyName + "!Claude")
```

脚本自带防呆：每处补丁都校验"模式唯一出现 + 等长替换 + 回读验证"，版本不符会拒绝执行而不是盲改。

### 验证方法

```powershell
Get-Content "$env:LOCALAPPDATA\Claude-3p\logs\main.log" -Tail 20
# 期望看到:
#   [custom-3p] Model discovery: 11 found ...; picker = 11 (discovery)
#   [custom-3p] ConfigHealth recomputed { state: 'healthy', provider: 'gateway' }
```

⚠️ 不要用"问模型你是谁"来验证——大模型对自身版本的自述极不可靠。以日志和响应的 `model` 字段为准。

---

## 仓库结构

```
claude-desktop-glm/
├── README.md
├── LICENSE
├── patches/
│   ├── repatch-fresh.ps1   # 四闸 asar 补丁（合并版，一次 UAC）
│   ├── fuse-flip.ps1       # ASAR 完整性 fuse 翻转
│   ├── svcpatch.ps1        # cowork-svc 指纹比对补丁（6 字节）
│   └── resign.ps1          # claude.exe + cowork-svc.exe 本地重签
├── gateway-proxy/          # 路线 A：零补丁网关代理
│   ├── proxy.mjs           # family_tier 注入 + 流式转发
│   └── start.bat
└── switch/
    └── switch-mode.ps1     # GLM 补丁版 / 官方原版 一键切换
```

## FAQ / 维护

**Q: 应用自动更新后全失效了？**
正常。更新会装新版包（新目录、新二进制）。流程：重跑 `repatch-fresh.ps1`（新版模式若不匹配会拒绝并提示）→ 闪退则加 `fuse-flip.ps1` → 需要 Cowork 则 `svcpatch.ps1` + `resign.ps1`。**每次更新模式都可能变化**，需要按 README"第 N 层"的方法重新定位（找 `usable models` / `resolveSessionModel` 字符串 → 提取上下文 → 设计等长替换）。

**Q: C 盘空间不够装 VM 镜像（要求 15 GiB）？**
先清 `C:\Windows\SoftwareDistribution\Download`（Windows 更新缓存）和 `%LOCALAPPDATA%\NVIDIA\DXCache`（着色器缓存，会自动重建，也可用目录联接迁去其他盘）。⚠️ 但 `vm_bundles` 本体**不能用联接**——VM 运行时会拒绝打开 junction 路径。

**Q: 想要沙箱但又想要 GLM？**
当前（2.2553.1）无法两全：沙箱的模型校验是独立的一层，配合补丁也只能在"沙箱可用"与"GLM 可用"之间二选一（本仓库 `switch/switch-mode.ps1` 提供一键切换）。1.44121.2+ 新版已官方支持网关自定义模型列表，等 Cowork 侧放开即为正解。

**Q: 撤销一切？**
`patches\` 每个脚本都有对应备份（生成于首次执行时），覆盖回原文件即可；重签的证书在 `Cert:\LocalMachine\Root` / `TrustedPublisher`（指纹 `88AD...`），删除即吊销本机信任。

## 已知限制

- 仅验证于 Windows 11 (26200) x64 + Claude Desktop 2.2553.1.0 + 智谱 `open.bigmodel.cn/api/anthropic`。
- 订阅套餐不包含的模型（如 GLM-5.3-FlashX）即使出现在列表里，推理时会被智谱侧拒绝（错误码 1311）。
- 事件/遥测通道（vm-client resubscribe）在补丁状态下会持续刷签名告警，不影响功能，但日志会变大。

## 参考 / 致谢

- 社区讨论：[linux.do「接入第三方模型后，Claude Desktop 基本废了？」](https://linux.do)、[cowork 3p 沙盒讨论](https://linux.do)
- 网关接入生态：[LiteLLM](https://docs.litellm.ai) · [TrueFoundry](https://www.truefoundry.com) · [Eigent](https://www.eigent.ai) · [QCode](https://docs.qcode.cc)
- GLM 侧：[智谱开放平台文档](https://docs.bigmodel.cn) · [Z.AI 文档](https://docs.z.ai) · [Open-Claude-Cowork](https://github.com)
- 原理工具：[Electron fuses](https://www.electronjs.org/docs/latest/tutorial/fuses) · [capstone](https://www.capstone-engine.org)

## LICENSE

MIT（仅限本仓库脚本与文档；Claude Desktop 本体版权归 Anthropic 所有）
