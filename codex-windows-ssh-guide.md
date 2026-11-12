# 让 Codex / ChatGPT 桌面端通过 SSH 连上 Windows 远端

> 一份可复现的实战手册 · 基于 2026-11 Windows 环境的真实排查记录
>
> 适用：Windows 客户端 → Windows 远端（原生 OpenSSH，非 WSL）
> 现象：连接显示"已断开连接 · SSH 连接失败"，日志里出现 `'sh' 不是内部或外部命令`

---

## 0. 先看结论

Codex 桌面端的 SSH 远端**在 Windows 上并非"不支持"**，而是它的远端引导脚本是按 POSIX 写的，且默认假设远端能长期驻留后台进程。Windows 原生 OpenSSH + cmd 环境需要补齐四件事才能真正跑通：

| # | 需要补齐的 | 一句话原因 |
|---|---|---|
| 1 | 远端登录 shell 换成 Git Bash | 引导脚本用 `sh` / `[` / `umask` / `mkdir -p` 等 POSIX 语法 |
| 2 | `SHELL` 环境变量指向 bash | 引导里有一段门禁：`SHELL` 不可执行就 `exit 127` |
| 3 | 让 app-server 能脱离 SSH 会话存活 | `nohup … &` 在 Windows 上会被会话回收杀掉 |
| 4 | `pkill` 与 socket 目录属主 | 旧进程占着 socket 和日志；目录属主必须是当前用户 |

**这四层是串行暴露的**：不修第 1 层，你看不到第 2 层；不修第 3 层，错误永远是 `socket hang up`，看不出第 4 层。

> 另一条独立坑：模型选择器里缺 `GPT-6.1 Sol/Terra`，原因是**远端 codex CLI 版本过旧**，与桌面端版本无关。

---

## 1. 原理：桌面端连远端时发生了什么

Codex 桌面端不是"开个 SSH 终端给你用"，它做的是**把远端的 codex app-server 拉起来，再通过 SSH 里套一条 WebSocket 连上去**。真实流程（从 `app.asar` 逆向确认）：

```text
ssh <alias> "sh 包装脚本 → exec /bin/sh -c '<payload>'"     ← 全部 POSIX
  ├─ codex_path_probe        command -v codex            → 必须 exit 0
  ├─ codex_version_probe     codex --version
  ├─ app_server_bootstrap    mkdir -p && pkill && : > log
  │                          && nohup codex app-server --listen unix:// &
  └─ proxy                   codex app-server proxy      ← 连远端 unix socket
```

其中 bootstrap 那一步的原始形态（关键）：

```sh
uid=$(id -u) || exit 1
umask 077
mkdir -p -- "$CODEX_HOME/app-server-control"
pkill -9 -U "$uid" -f "codex.*[d]esktop-ssh-websocket-v0.sock" || true
: > "$CODEX_HOME/app-server-control/app-server.log"
nohup codex -c features.code_mode_host=true app-server --listen unix:// &
```

这段脚本里有四个 Windows 上会翻车的点，分别对应下面四步修复。

**为什么日志里是 `'sh' 和 '[' 不是内部或外部命令`**：sshd 把整条命令交给默认 shell（cmd.exe）执行，cmd 不认识 `sh` 和 `[`。

---

## 2. 环境与前置条件

本文验证过的组合：

| 项 | 值 |
|---|---|
| 客户端 | Windows 11，ChatGPT/Codex 桌面端 26.1106+（Store 版 MSIX） |
| 远端 | Windows 11 26H2，OpenSSH_for_Windows **9.5p2** |
| 远端 CLI | npm 全局安装的 `@openai/codex`（**必须 ≥ 0.167**，见第 7 步） |
| 网络 | Tailscale 内网（公网建议只走 VPN，不要暴露 22 端口） |
| 远端 Git | Git for Windows（提供 Git Bash） |

前置检查（全部通过再往下走）：

```bash
# 1. 能免密登录（别名写在 ~/.ssh/config，不要硬编码 IP/用户）
ssh <alias> "whoami"

# 2. 远端有 codex，且在 PATH 里
ssh <alias> 'command -v codex; codex --version; codex login status'

# 3. 远端有 Git Bash（记下真实路径，可能不在 C 盘）
ssh <alias> 'ls -la /e/"Program Files"/Git/bin/bash.exe'   # 或用 PowerShell 查
```

> **路径引号注意**：远端改成 bash 之后，路径含空格必须自己处理，而且经 ssh 传参时引号容易被各层吞掉（见 §9.1）。最稳的是用 PowerShell `-EncodedCommand` 或写成脚本文件传过去。

---

## 3. 第一步：把远端登录 shell 换成 Git Bash

在**远端**用管理员 PowerShell 执行：

```powershell
$bash = 'E:\Program Files\Git\bin\bash.exe'   # 换成你的实际路径

New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value $bash -PropertyType String -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption `
  -Value '-c' -PropertyType String -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellEscapeArguments `
  -Value 1 -PropertyType DWord -Force

# SHELL 必须两级都设，用户级会覆盖机器级
[Environment]::SetEnvironmentVariable('SHELL', '/usr/bin/bash', 'Machine')
[Environment]::SetEnvironmentVariable('SHELL', '/usr/bin/bash', 'User')

Restart-Service sshd -Force
```

`DefaultShellCommandOption` 有两种写法：`-c` 和 `-lc`。`-lc` 是登录 shell，能读到 `/etc/profile`；但有报告显示在某些桌面端版本上会卡在"远端文件夹校验"失败。**本文在 `-c` 下验证通过**。

`DefaultShellEscapeArguments`：社区多篇教程写 `0`，本文最终采用 **`1`（OpenSSH 默认行为）**并在该值下完成端到端验证。要注意的是，早期的 0/1 对照实验被 PowerShell 传参问题污染过（见 §9.1），因此这里给的是"**本环境已验证可用值**"，不是"唯一正确值"。若你照抄 `0` 后出现命令被拆词，先改回 `1` 再排查。

### 验证

```bash
ssh <alias> 'echo "SHELL=$SHELL"; command -v sh; command -v codex'
# 期望：SHELL=/e/program files/git/bin/bash.exe（或类似）
#       /usr/bin/sh
#       /c/Users/<user>/AppData/Roaming/npm/codex
```

再复现桌面端那两条探测：

```bash
ssh <alias> 'if command -v codex >/dev/null 2>&1; then exit 0; fi; exit 86'
echo $?    # 必须是 0；86 表示找不到 codex，其它值表示 shell 有问题

ssh <alias> 'if [ -z "$SHELL" ] || [ ! -x "$SHELL" ]; then echo GATE_FAIL; exit 127; fi; echo GATE_OK'
# 必须是 GATE_OK
```

⚠️ **到这一步还没结束**。此时桌面端会报 `socket hang up`，而不是原来的 shell 错误——这是进度，不是退步。

---

## 4. 第二步：让 app-server 活过 SSH 会话

### 4.1 为什么 `nohup … &` 不行

Windows OpenSSH 在会话结束时会回收该会话的进程树。实测对照（10 秒后观察）：

| 启动方式 | 结果 |
|---|---|
| `nohup codex … app-server --listen unix:// &`（桌面端用的方式） | ❌ 无进程、无 socket、日志 0 字节 |
| Windows 计划任务 `Start-ScheduledTask` | ❌ 任务动作结束时子进程被一起杀掉 |
| **WMI `Win32_Process::Create`** | ✅ 进程挂在 `WmiPrvSE` 名下，存活 |

还有两个必须注意的细节：

- **必须重定向 stdin**：`< nul`。没有 stdin，codex 启动后立即退出（本文实测）。
- **进程能创建 ≠ 能连上**：`--listen unix://` 生成 `%USERPROFILE%\.codex\app-server-control\app-server-control.sock`。

### 4.2 方案：shim + 常驻看护进程

问题的本质是**竞态**：桌面端执行 `nohup … &` 后立刻返回，会话几乎马上被回收，任何"要花 1 秒才完成"的启动脚本都会被腰斩。所以不能靠 shim 自己启动服务，而要让它**只写一个请求**，由常驻进程去真正启动。

三个组件：

```text
/usr/bin/nohup  (shim)  ──写请求文件──▶  watcher.ps1 (WMI 常驻)
     │                                        │
     └─ 非 app-server 命令 → exec nohup.real   └─ WMI 创建 codex app-server（< nul）
```

**① `pkill` shim**（Git Bash 里根本没有 pkill）

`E:\Program Files\Git\usr\bin\pkill`：

```bash
#!/bin/bash
# MSYS 会吃掉传给原生 exe 的 Windows 路径反斜杠，必须用正斜杠
pat=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then pat="$a"; fi
  prev="$a"
done
case "$pat" in
  *codex*|*app-server*|*desktop-ssh*)
    /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile \
      -ExecutionPolicy Bypass -File 'C:/Users/<user>/codex-shims/kill-appserver.ps1' >/dev/null 2>&1
    exit $?
    ;;
  *) exit 1 ;;
esac
```

> 匹配模式要注意：桌面端实际传的是 `codex.*[d]esktop-ssh-websocket-v0.sock`，**里面没有 "app-server"**。只匹配 `app-server` 会漏掉，表现为"pkill 返回 0 但进程没死"。

**② `nohup` shim**（把启动转成请求文件）

先把原版备份：`cp /usr/bin/nohup /usr/bin/nohup.real`

`E:\Program Files\Git\usr\bin\nohup`：

```bash
#!/bin/bash
case "$*" in
  *app-server*--listen*)
    touch "$HOME/.codex/app-server-control/start-request" 2>/dev/null
    exit 0
    ;;
  *)
    exec /usr/bin/nohup.real "$@"
    ;;
esac
```

**③ 常驻看护 `watcher.ps1`**（纯 ASCII，见 §9.4）

逻辑：每 700 ms 检查一次；发现没有 app-server 就用 WMI 拉起；限流 5 秒。

启动它（父级是 WmiPrvSE，所以能跨会话、跨 ssh 存活）：

```powershell
$inner = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:/Users/<user>/codex-shims/watcher.ps1"'
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $inner }
```

**④ 开机自启**：把下面内容存成
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\codex-appserver-watcher.cmd`

```bat
@echo off
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\<user>\codex-shims\watcher.ps1"
```

> 限制：Startup 只在**交互式登录**时执行。如果机器重启后你只从 ssh 操作、没登录桌面，看护进程不会起来（此时手动执行 `start-appserver.ps1` 即可）。

### 4.3 关键：不要让旧的 app-server 占着日志

bootstrap 里有 `: > app-server.log`（截断日志）。**只要有一个 app-server 正在运行，它就一直持有这个日志文件**，截断会失败：

```text
/bin/sh: line 1: .../app-server-control/app-server.log: Device or resource busy
```

`&&` 链随即断裂，后面的 `nohup` 根本不执行。所以 `pkill` shim 是**必须**的——它负责先释放 socket 和日志锁。

---

## 5. 第三步：socket 目录的属主

CLI 有一道安全校验（对应 openai/codex#42326 的加固）：控制 socket 目录必须是**当前用户私有**的受保护目录。否则报：

```text
Error: socket directory is not private to the current user
```

**最容易踩的陷阱**：如果你的 ssh 会话是**提权**的（UAC 设为"无提示提升"，即 `ConsentPromptBehaviorAdmin=0`，管理员登录即完整令牌），那么手动 `mkdir` 出来的目录**属主会变成 `BUILTIN\Administrators`**，直接被 CLI 拒绝。实测 `icacls /setowner` 也改不动（属主未变）。

**正确做法：不要预建这个目录，删掉它让 `codex.exe` 自己创建。** CLI 建出来的形态是正确的：

```text
Owner = <计算机名>\<用户>
Protected = True
ACE 数量 = 1（仅当前用户 FullControl，不继承）
```

```bash
# 删掉后启动一次，让它自己建
ssh <alias> 'rm -rf "$HOME/.codex/app-server-control" && timeout 10 codex -c features.code_mode_host=true app-server --listen unix://'
```

然后核对（PowerShell）：

```powershell
$acl = Get-Acl "$env:USERPROFILE\.codex\app-server-control"
$acl.Owner; $acl.AreAccessRulesProtected; $acl.Access.Count
```

> 顺带一提：`codex app-server daemon start` 在提权会话下会被明确拒绝——
> `start the Windows daemon from a non-elevated terminal`。
> 桌面端走的是 `--listen unix://`，**不触发这条限制**，所以不影响本方案。但如果官方后续切到 daemon 模式，就必须把 UAC 改回"提示提升"。

---

## 6. 验证清单

按顺序跑，全绿再回桌面端点连接：

```bash
# 1) POSIX 探测（桌面端第一步）
ssh <alias> 'if command -v codex >/dev/null 2>&1; then exit 0; fi; exit 86'; echo "probe=$?"      # 0

# 2) SHELL 门禁
ssh <alias> 'if [ -z "$SHELL" ] || [ ! -x "$SHELL" ]; then exit 127; fi; echo GATE_OK'           # GATE_OK

# 3) app-server 能起来
ssh <alias> 'codex app-server proxy </dev/null; echo "proxy=$?"'                                # proxy=0

# 4) 模拟桌面端 bootstrap（pkill → 截断日志 → nohup → 再连）
ssh <alias> 'pkill -9 -U "$(id -u)" -f "codex.*[d]esktop-ssh-websocket-v0.sock" || true; sleep 3; codex app-server proxy </dev/null; echo "after_kill=$?"'  # 0（看护会补起）

# 5) ACL 属主
#    用 §5 的 PowerShell 片段，确认 Owner 是当前用户、Protected=True、ACE=1
```

桌面端侧的判断依据（日志路径）：
`%LOCALAPPDATA%\Packages\OpenAI.Codex_*\LocalCache\Local\Codex\Logs\<年>\<月>\<日>\*.log`

关键字段：

| 日志字段 | 含义 |
|---|---|
| `sshSetupStage=remote_codex_lookup` | 卡在第 1/2 步（shell 或 SHELL） |
| `operation=app_server_bootstrap code=0` | **不代表成功**（进程可能已死） |
| `socket hang up` / `ECONNRESET` | 卡在第 3/4 步（服务没起来 / socket 被占） |
| `nextState=connected` + `initialized=true` | 真正成功 |

---

## 7. 模型列表缺失（GPT-6.1 Sol / Terra）

**症状**：同一账号，网页版和远端本机的桌面端都有 `GPT-6.1 Sol/Terra`，但通过 SSH 连接时只看到 `6-astra` 之类。

**原因**：SSH 会话的模型目录由**远端 app-server**（也就是远端 PATH 里的 `codex` CLI）提供，与客户端桌面端版本无关。远端 npm CLI 太旧时，目录里就没有新模型。

**排查**：

```bash
ssh <alias> 'which codex; codex --version'
# 再看远端桌面端自带的 CLI（作为对照，版本通常更新）
ssh <alias> '"/c/Program Files/WindowsApps/OpenAI.Codex_*/app/resources/codex.exe" --version'
```

**修复**：

```bash
# 先停掉看护与 app-server，避免文件占用
ssh <alias> 'npm install -g @openai/codex@latest'
ssh <alias> 'codex --version'      # 期望 ≥ 0.167
```

然后重启看护进程，再在桌面端断开重连。

**核对**（升级后远端会重新拉取模型目录）：

```powershell
$raw = Get-Content "$env:USERPROFILE\.codex\models_cache.json" -Raw
[regex]::Matches($raw, '"([A-Za-z0-9._\-]*gpt-6[A-Za-z0-9._\-]*)"') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
```

实测从 `0.155.0` 升到 `0.167.1` 后，`models_cache.json` 里出现了 `gpt-6.1-sol`、`gpt-6.1-terra`。

---

## 8. 最终形态一览

```text
客户端 Windows ── ssh（别名） ──▶ 远端 Windows
                                    ├─ sshd：DefaultShell = Git Bash（-c）
                                    ├─ SHELL = /usr/bin/bash（机器级 + 用户级）
                                    ├─ /usr/bin/pkill      ← shim：按需杀 app-server
                                    ├─ /usr/bin/nohup      ← shim：写启动请求
                                    ├─ watcher.ps1         ← 常驻，700ms 轮询，WMI 拉起
                                    ├─ codex CLI ≥ 0.167   ← 决定模型目录
                                    └─ ~/.codex/app-server-control/  ← 由 CLI 自己创建
```

---

## 9. 避坑指南

### 9.1 从 PowerShell 调 ssh 传命令，双引号会被吞

这是本次排查里**最浪费时间**的一个坑，因为它会伪装成"远端 shell 有问题"。

```powershell
# 错：内层双引号被 PowerShell 吃掉，远端收到的是拆过词的命令
ssh TX 'a="x y"; echo "$a"'
```

现象是远端报 `y: command not found`、`/e/program: Is a directory` 之类，看起来像 shim 或 sshd 的问题。**用 PowerShell 直接做 A/B 对照实验是无效的**，两个注册表值会得到一模一样的"错误"，从而导出错误结论。

可靠姿势（按推荐度）：

```powershell
# 1) PowerShell 侧编码后下发（最稳）
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
ssh TX "powershell -NoProfile -EncodedCommand $b64"

# 2) 用 Node/其它语言 spawn(args 数组)，完全绕过 shell 拼接
#    spawn("ssh", ["-o","BatchMode=yes","TX", cmd])

# 3) 脚本写文件再传过去执行
```

在 **bash 侧**调用 PowerShell 时同理：路径必须用**正斜杠**，否则 MSYS 会吃掉反斜杠：

```bash
# 错：远端收到 C:Users<user>codex-shimsstart-appserver.ps1
powershell.exe -File 'C:\Users\<user>\codex-shims\start-appserver.ps1'

# 对
powershell.exe -File 'C:/Users/<user>/codex-shims/start-appserver.ps1'
```

### 9.2 远端是 bash 后，命令里别带中文

```bash
ssh TX 'ls -la ~/.codex 2>/dev/null || echo (无文件)'
# bash: syntax error near unexpected token `$'\227\227...'
```

中文全角括号会被 bash 当成语法。命令里坚持纯 ASCII，或加引号。

### 9.3 日志里的中文是乱码，要转码再读

桌面端日志把远端 GBK 输出按 UTF-8 存了，直接读会看到 ``。还原方式：

```powershell
$fixed = [System.Text.Encoding]::GetEncoding(936).GetString(
  [System.Text.Encoding]::GetEncoding(28591).GetBytes($line))
```

Git Bash 本身不改代码页，这个问题**不能靠 `chcp 65001` 解决**；读中文文件建议用 `scp` 拉回本地。

### 9.4 传给远端的 `.ps1` 必须是纯 ASCII

远端的 Windows PowerShell 按 GBK（ANSI）读取 `.ps1`。文件里带中文注释会直接解析失败：

```text
字符串缺少终止符
表达式无效
```

脚本里不要写中文注释，也别写中文输出。

### 9.5 `bootstrap code=0` 是假象

桌面端只检查命令退出码。`nohup … &` 这类后台启动永远返回 0，**进程死没死它不知道**。所以不能拿它当成功标志，必须去看 socket 文件、进程和 `proxy` 的返回码。

### 9.6 计划任务会杀掉子进程

用 `Start-ScheduledTask` 启动的后台程序，在任务动作结束时会被一起回收。这也是为什么本方案用 **WMI 创建**而不是计划任务。

顺带记录：用 `New-ScheduledTaskPrincipal -LogonType Interactive` 注册任务，在部分本地账户上会稳定报 `0x80070534`（账户名与安全标识无映射），`-UserId` 写 SID / 用户名都不行；`schtasks /RU` 同样失败。

### 9.7 提权会话是一系列坑的根源

如果 `ConsentPromptBehaviorAdmin=0`（无提示提升），管理员 ssh 会话会拿到完整令牌：

- 你 `mkdir` 的任何东西属主都是 `BUILTIN\Administrators` → 触发 §5 的 ACL 拒绝
- `codex app-server daemon start` 直接拒绝运行

判断当前会话是否提权：

```powershell
(New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrators')
```

### 9.8 别手动预建 `app-server-control`

动机通常是"想让它早点就绪"，结果反而会让 bootstrap 的 `: > 日志` 失败（§4.3）或属主不对（§5）。**交给 CLI 自己创建。**

### 9.9 改动的影响面（Windows 远端特有）

把远端默认 shell 换成 Git Bash 后：

| 不受影响 | 原因 |
|---|---|
| VS Code Remote-SSH | 它显式下发 `ssh <host> powershell`，集成终端仍是 PowerShell |
| scp / WinSCP / FileZilla | 走 sftp 子系统，不经过登录 shell |
| 系统服务（Syncthing 等） | 与 ssh 无关 |

| 会变 | 对策 |
|---|---|
| cmd 内建命令（`dir`/`type`/`set`/`if exist`/`copy`） | 显式 `cmd /c "..."` |
| 变量写法 `%VAR%` → `$VAR` | 改脚本；注意静默失效 |
| 路径 `C:\…` → `/c/…` | 反斜杠在 bash 里是转义 |
| `conda activate` | 远端需一次性 `conda init bash`；`conda.exe` 可直接用 |

---

## 10. 排错方法论（比结论更有用）

1. **读桌面端的真实日志，不要猜**。`AppServerTransportSshWebsocket` / `remote_connections.*` 两个前缀基本能定位到阶段。
2. **区分"认证失败"和"认证后失败"**。日志里出现 `Authenticated to <ip> ... using "publickey"` 就说明密钥/网络/known_hosts 全都没问题，不要再折腾 `authorized_keys` 的 ACL。
3. **判断连接是否真的发起了**：看远端 `~/.codex/app-server-control/` 的时间戳，以及看护日志。时间戳没动 = 桌面端根本没发请求（UI 状态可能是旧的）。
4. **A/B 实验要在可信的调用层做**。用 PowerShell 传参做 A/B 会得到假象（§9.1）；用 Node `spawn(args)` 才等价于桌面端的调用方式。
5. **对"后台启动"要独立验证存活**，至少等 8–10 秒后再查一次进程和 socket。

---

## 11. 回滚

改动前的原始值（本环境全部为"未设置"）：

```text
DefaultShell                  = <NOT SET>
DefaultShellCommandOption     = <NOT SET>
DefaultShellEscapeArguments   = <NOT SET>
SHELL(Machine) / SHELL(User)  = <NOT SET>
```

回滚步骤：

```powershell
$k = 'HKLM:\SOFTWARE\OpenSSH'
foreach ($n in 'DefaultShell','DefaultShellCommandOption','DefaultShellEscapeArguments') {
  Remove-ItemProperty -Path $k -Name $n -ErrorAction SilentlyContinue
}
[Environment]::SetEnvironmentVariable('SHELL', $null, 'Machine')
[Environment]::SetEnvironmentVariable('SHELL', $null, 'User')
Restart-Service sshd -Force
```

再恢复 shim（`mv /usr/bin/nohup.real /usr/bin/nohup`、删除 `/usr/bin/pkill`、删掉 Startup 里的 `.cmd`、结束 watcher 进程）。

⚠️ 回滚后 Codex 的 SSH 远端会立刻恢复失败状态。

---

## 12. 附录：完整脚本

### `kill-appserver.ps1`

```powershell
$ErrorActionPreference = 'SilentlyContinue'
$procs = Get-CimInstance Win32_Process -Filter "Name='codex.exe'" |
  Where-Object { $_.CommandLine -like '*app-server*--listen*' }
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force }
if (@($procs).Count -gt 0) { exit 0 } else { exit 1 }
```

### `start-appserver.ps1`

```powershell
$ErrorActionPreference = 'SilentlyContinue'
$ctrl = Join-Path $env:USERPROFILE '.codex\app-server-control'
New-Item -ItemType Directory -Force -Path $ctrl | Out-Null
$log = Join-Path $ctrl 'boot-server.log'

# WMI 创建：父级是 WmiPrvSE，能跨 ssh 会话存活
# stdin 必须重定向，否则 codex 立即退出
$inner = 'codex -c features.code_mode_host=true app-server --listen unix:// < nul > "' + $log + '" 2>&1'
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
Write-Output ('WMI ReturnValue=' + $r.ReturnValue + ' PID=' + $r.ProcessId)
```

### `watcher.ps1`

```powershell
$ErrorActionPreference = 'SilentlyContinue'
$ctrl = Join-Path $env:USERPROFILE '.codex\app-server-control'
$req  = Join-Path $ctrl 'start-request'
$log  = Join-Path $ctrl 'boot-server.log'
$wlog = Join-Path $ctrl 'watcher.log'

Add-Content -Path $wlog -Value ((Get-Date -Format s) + ' watcher started')

$lastStart = Get-Date '2000-01-01'
while ($true) {
  Start-Sleep -Milliseconds 700
  if (Test-Path -LiteralPath $req) { Remove-Item -LiteralPath $req -Force -ErrorAction SilentlyContinue }

  $has = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" |
           Where-Object { $_.CommandLine -like '*app-server*--listen*' }).Count
  if ($has -gt 0) { continue }

  if (((Get-Date) - $lastStart).TotalSeconds -lt 5) { continue }
  $lastStart = Get-Date

  $inner = 'codex -c features.code_mode_host=true app-server --listen unix:// < nul > "' + $log + '" 2>&1'
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
  Add-Content -Path $wlog -Value ((Get-Date -Format s) + ' auto-start rv=' + $r.ReturnValue + ' pid=' + $r.ProcessId)
}
```

> 看护进程同时充当 watchdog：服务崩了会自动补起（限流 5 秒），不需要人工干预。

---

## 13. 参考

官方文档
- [Remote connections — ChatGPT Learn](https://learn.chatgpt.com/docs/remote-connections)（只要求"远端登录 shell 里能找到 codex"，未列出 OS 支持矩阵）

同类问题（截至成文均未关闭）
- [openai/codex#56794](https://github.com/openai/codex/issues/56794) — Windows→Windows 最完整记录，Git Bash + ACL 修复后连通成功
- [openai/codex#22965](https://github.com/openai/codex/issues/22965) — 同类问题，含 `-lc` 卡在文件夹校验的案例
- [openai/codex#44581](https://github.com/openai/codex/issues/44581) — socket 目录 ACL 的 A/B/C 受控复现
- [openai/codex#31390](https://github.com/openai/codex/issues/31390) — 功能请求：原生支持 Windows OpenSSH 远端
- [openai/codex#22757](https://github.com/openai/codex/issues/22757) — 默认 shell 为 PowerShell 时的同类失败
- [microsoft/vscode-remote-release#11388](https://github.com/microsoft/vscode-remote-release/issues/11388) — VS Code 连 Git Bash 主机（仅影响 macOS/Linux 客户端）

---

*本文基于一次真实的端到端排查整理。文中所有命令与脚本均在 Windows 11 + OpenSSH 9.5p2 + Git for Windows 环境实测通过；标注"未定论"的地方保留原始不确定性，未做美化。*