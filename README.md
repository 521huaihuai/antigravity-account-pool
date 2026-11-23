# Antigravity 账号池

为 **Google Antigravity 桌面版** 提供多账号本地管理与一键切换。
只做三件事：**备份凭据 → 写回凭据 → 重启客户端**。

不代理请求、不做协议转换、不监听端口、不修改客户端文件。

> 请求链路始终是官方客户端直连 Google。切换账号只改变"用哪个身份登录"，不改变请求本身。

---

## 为什么需要它

Antigravity 桌面版同一时刻只能登录一个 Google 账号。额度用完或需要切换工作/个人账号时，官方流程是：

1. 退出登录
2. 浏览器重新走一遍 OAuth
3. 授权、跳转、等待

每次大约 30 秒到 1 分钟。账号越多，越难受。

这个工具把每个账号的 OAuth 凭据做成本地加密快照，切换时直接写回系统凭据管理器并重启客户端——通常 5~10 秒完成，且不需要浏览器授权。

---

## 与反代/网关类工具的区别

| | 本工具 | 反代 / API 网关类工具 |
|---|---|---|
| 请求链路 | 官方客户端直连 | 经本地网关转发 |
| 协议转换 | 无 | OpenAI / Anthropic / Gemini 互转 |
| 端口监听 | **无** | 通常监听 127.0.0.1:xxxx |
| 请求重放 / UA 伪装 | 无 | 常见 |
| 典型用途 | 手动切号 | 给第三方客户端供 API |

如果你只需要"换号"，不需要给 Claude Code、NextChat 之类的外部工具供 API，这个工具是更轻、更少侵入的选择。

---

## 功能

- **登录即入库**：GUI 运行期间，检测到新的登录账号会自动保存到号池，无需手动操作
- **一键切换**：列表点击「切换」，自动关闭客户端、写入凭据、校验、重启
- **账号昵称**：每个账号可设置独立昵称，便于记忆
- **令牌轮换自愈**：切走前会回存当前账号的最新凭据，避免 refresh token 轮换导致快照过期
- **写入校验**：写回后读回比对 SHA256，失败会明确报错，不会静默写坏
- **本地加密**：快照使用 Windows DPAPI（CurrentUser）加密，换用户或换机器无法解密
- **日志留存**：切号过程与结果记录在本地，便于排查

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11（x64） |
| PowerShell | Windows PowerShell 5.1（系统自带） |
| 客户端 | Antigravity 桌面版 2.x（在 2.33.0 上验证） |
| 权限 | 普通用户即可，无需管理员 |

> 仅针对 **Antigravity 桌面版 App**。Antigravity IDE（VS Code 内核）的存储方式不同，未做适配。

---

## 快速开始

### 1. 获取代码

```powershell
git clone https://github.com/<your-name>/antigravity-account-pool.git
cd antigravity-account-pool
```

或直接下载 ZIP 解压。

### 2. 启动界面

双击 **`agpool-gui.cmd`**。

首次打开时，当前已登录的账号会自动出现在列表里。

### 3. 加入更多账号

1. 在 Antigravity 里退出登录，换另一个 Google 账号登录
2. 回到账号池界面（或点击「刷新」），新账号会自动入库

### 4. 切换

在目标账号卡片上点击「切换」。

客户端会被关闭并重启，登录态由官方客户端自行加载。

---

## 图形界面

```
┌──────────────────────────────────────────┐
│  ● Antigravity 账号池              [刷新] │
│    当前：工作号 · user@example.com        │
├──────────────────────────────────────────┤
│  ┌────────────────────────────────────┐  │
│  │ 工作号                    [昵称][当前] │  │
│  │ user@example.com · 11-23 15:45      │  │
│  └────────────────────────────────────┘  │
│  ┌────────────────────────────────────┐  │
│  │ 备用号                  [昵称][切换] │  │
│  │ backup@example.com · 11-23 15:38    │  │
│  └────────────────────────────────────┘  │
├──────────────────────────────────────────┤
│ 登录新账号自动入库        [收藏当前][打开目录] │
└──────────────────────────────────────────┘
```

- 点击卡片上的「昵称」可设置/修改昵称，留空即清除
- 右键卡片可设置昵称或从号池移除
- 「收藏当前」用于手动补录（自动入库未触发时）
- 「打开目录」直达号池数据目录

---

## 命令行

```powershell
.\agpool.ps1 list                      # 查看号池
.\agpool.ps1 current                   # 当前生效账号
.\agpool.ps1 capture <名称>            # 保存当前登录账号
.\agpool.ps1 switch <名称>             # 切换（会重启客户端）
.\agpool.ps1 switch <名称> -NoRestart  # 只写凭据，稍后手动启动
.\agpool.ps1 nickname <名称> <昵称>    # 设置昵称
.\agpool.ps1 nickname <名称> -Clear    # 清除昵称
.\agpool.ps1 rename <旧> <新>          # 重命名快照
.\agpool.ps1 remove <名称>             # 删除快照
.\agpool.ps1 shortcut <名称>           # 生成桌面一键切号快捷方式
```

也可以使用 `agpool.cmd` 作为入口，它会自动选择可用的 PowerShell。

---

## 数据与安全

### 存放位置

| 内容 | 路径 |
|---|---|
| 凭据快照 | `%USERPROFILE%\.antigravity-pool\profiles\<label>\cred.dat` |
| 账号元数据 | `%USERPROFILE%\.antigravity-pool\profiles\<label>\meta.json` |
| 当前状态 | `%USERPROFILE%\.antigravity-pool\state.json` |
| 运行日志 | `%TEMP%\agpool-logs\` |

### 加密方式

`cred.dat` 使用 `ConvertFrom-SecureString`（Windows DPAPI，CurrentUser 作用域）加密。
只有当前 Windows 用户能解密；复制到其他机器或其他用户下无法还原。

### 安全边界

- 不发起任何网络请求，不包含任何外部依赖，不监听端口
- 不读取 Antigravity 进程内存，不修改客户端文件
- 快照中保存的是 OAuth refresh token，**请勿**把 `.antigravity-pool` 目录打包分享或上传网盘
- 公共电脑使用后建议删除账号并退出应用

---

## 工作原理

```
登录一次 ──► 读取凭据 ──► DPAPI 加密 ──► 本地快照
                                              │
点击切换 ──► 关闭客户端 ──► 写回凭据管理器 ──► 校验 SHA256 ──► 重启客户端
```

Antigravity 桌面版把 OAuth 凭据存放在 **Windows 凭据管理器** 的 `gemini:antigravity` 条目中（Generic Credential），内容是一段 JSON：

```json
{
  "token": {
    "access_token": "...",
    "refresh_token": "...",
    "expiry": "...",
    "expires_in": 3599
  },
  "auth_method": "consumer",
  "id_token_email": "user@example.com",
  "writer_id": "..."
}
```

本工具通过 `advapi32.dll` 的 `CredRead` / `CredWrite` 读写该条目，写回后重启客户端，由客户端自行完成 token 刷新。整个过程与手动登录后客户端自己写凭据的行为一致。

---

## 常见问题

**切换后提示需要重新登录**

该快照的 refresh token 已被撤销或轮换。重新登录一次，然后执行 `.\agpool.ps1 capture <名称>` 覆盖同名快照。

**界面没有启动**

查看安装目录下的 `AgPool.Gui.error.log`，或 `%TEMP%\agpool-logs\agpool.log`。

**提示"写入校验失败"**

Antigravity 升级后可能改变了凭据结构。请提交 issue，并附上 `agpool.log`（不要附 cred.dat）。

**中文显示为乱码**

所有 `.ps1` 文件必须保存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 ANSI 解析。仓库已通过 `.editorconfig` 约束。

**切换时客户端没有重启**

检查 `%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe` 是否存在；若安装在自定义路径，启动时传 `-AppPath`。

---

## 免责声明

- 本项目与 Google 无关联，非官方工具
- 使用多个账号分摊额度可能违反 Google 服务条款，风险由使用者自行承担
- 本工具不承诺"绝对不会封号"；它只保证不引入请求层面的异常信号（无代理、无重放、无 UA 伪装）
- 建议一号一用，避免短时间内高频轮换、多机并发或共享账号

---

## License

[MIT](LICENSE)

---

## English summary

A local account switcher for the **Google Antigravity desktop app** on Windows.

It snapshots each account's OAuth credential (stored in Windows Credential Manager under
`gemini:antigravity`), encrypts it with DPAPI, and writes it back when you switch accounts.
No proxy, no request rewriting, no listening ports — the official client still talks to Google directly.

Features: auto-import on login, one-click switching, per-account nicknames, SHA256-verified writes.
Requires Windows 10/11 and Windows PowerShell 5.1. Tested with Antigravity 2.33.0.
