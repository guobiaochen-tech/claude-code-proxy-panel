# Claude Code Proxy Panel

> A local macOS web panel that shows your current proxy status and syncs it into **Terminal / git / VS Code / CC Switch** — with read-only views of Claude Code and Hermes. Built to live alongside **FlClash** / **Clash Verge** (proxy) and **CC Switch** (provider manager).

> 一个 macOS 本地网页面板：显示当前代理状态，并一键同步到 **终端 / git / VS Code / CC Switch**；只读展示 Claude Code、Hermes 状态。配合 **FlClash** / **Clash Verge**（代理）和 **CC Switch**（provider 管理）使用。

---

## Features / 功能

- **Current proxy at a glance** — auto-detects which proxy (FlClash or Clash Verge) is running, and whether it's in **TUN mode** or listening on a **port**.
- **Sync to apps** — one click applies the current proxy (or *direct* under TUN) to **Terminal** (`.zshrc`), **git**, **VS Code**, and **CC Switch**. Each row shows ✓ synced or ⚠ mismatched.
- **Claude Code / Hermes status (read-only)** — shows the active provider, model, and connectivity (Claude Code is probed via a real `/v1` call).
- **Near-zero dependencies** — mostly Python standard library; PyYAML is *optional* (used only to read the Hermes config, falls back to regex if absent).
- **Auto-refresh** — the page refreshes itself every 30 seconds.

中：

- **当前代理一目了然**：自动检测当前是 FlClash 还是 Clash Verge 在跑，是 **TUN 模式**还是某个**端口**在监听。
- **同步到各软件**：一键把当前代理（或 TUN 下的直连）应用到 **终端**（`.zshrc`）、**git**、**VS Code**、**CC Switch**；每行用 ✓/⚠ 标示是否已同步。
- **Claude Code / Hermes 状态（只读）**：显示当前后台、模型和连通性（Claude Code 会真实发一次 `/v1` 请求探测）。
- **近乎零依赖**：以 Python 标准库为主；PyYAML 是*可选*依赖（仅用于读 Hermes 配置，没装会自动降级正则解析）。
- **自动刷新**：页面每 30 秒刷新一次。

## Prerequisites / 前置条件

- **macOS** — the launcher and `no_proxy` setup assume macOS/zsh.
- **Python 3** — system Python is fine.
- **FlClash** *or* **Clash Verge** — the proxy client this panel detects.
- **CC Switch** (optional but expected) — Claude Code provider manager; the panel reads its database and syncs proxy URLs into it.

中：

- **macOS**：启动脚本和 `no_proxy` 设置都假定 macOS/zsh。
- **Python 3**：系统自带即可。
- **FlClash** *或* **Clash Verge**：本面板检测的代理客户端。
- **CC Switch**（可选但推荐）：Claude Code 的 provider 管理工具；本面板读取它的数据库，并把代理地址同步进去。

## Supported Proxies / 支持的代理

> **Only FlClash and Clash Verge are recognized.** Detection works by process name + each client's config file, so these two are all it knows. Running another proxy app:
> - **TUN mode** — fine: the panel sets your apps to *direct*, which is correct under TUN, so things still work.
> - **Port mode** — the panel can't recognize it and won't auto-fill the port; it shows "no proxy", so you must configure each app by hand.

中：

> **仅支持识别 FlClash 和 Clash Verge。** 检测靠进程名 + 各客户端的配置文件，所以只认这两个。如果你改用别的代理软件：
> - **TUN 模式**——没问题：面板会把各软件设为*直连*，TUN 下正好正确，照常能用。
> - **端口模式**——面板识别不到、也不会自动填端口，会显示"未检测到代理"，需要你手动给各软件配置。

---

## Quick Start / 快速开始

```bash
git clone https://github.com/guobiaochen-tech/claude-code-proxy-panel.git
cd claude-code-proxy-panel
cp secrets.example.json secrets.json   # then edit secrets.json with your key
python3 server.py
```

Open <http://127.0.0.1:8866>, or double-click **`启动.command`**.

中：

```bash
# 同上命令
cp secrets.example.json secrets.json   # 然后把 secrets.json 里的 key 改成你自己的
python3 server.py
```

浏览器打开 <http://127.0.0.1:8866>，或双击 **`启动.command`**。

## How it works / 工作原理

- **Detects** the active proxy by reading the FlClash/Clash Verge config + checking the process + checking for a TUN interface.
- **"Apply" button** writes the current proxy into the chosen target: in TUN mode → sets it to *direct*; in port mode → fills in the port. Targets: `.zshrc` (terminal), git global config, VS Code `settings.json`, CC Switch DB (`global_proxy_url`).
- Claude Code / Hermes panels are **read-only**. To **switch** Claude Code's provider, do it in the **CC Switch** app — this panel only displays it.

中：

- **检测**：读 FlClash/Clash Verge 配置 + 查进程 + 查 TUN 网卡，判断当前代理。
- **"应用"按钮**：把当前代理写进选定目标——TUN 模式→设为*直连*；端口模式→填入端口。目标：`.zshrc`（终端）、git 全局配置、VS Code `settings.json`、CC Switch 数据库（`global_proxy_url`）。
- Claude Code / Hermes 面板是**只读**的。要**切换** Claude Code 的 provider，请到 **CC Switch** 软件里操作——本面板只显示。

## Configuration / 配置

`secrets.json` (**gitignored — never committed**):

```json
{
  "glm_auth_token": "<your Zhipu GLM API Key, format: id.secret>"
}
```

This key is used **only** to health-check a provider's endpoint (a tiny `/v1` probe). The panel still runs without it — you just lose the connectivity test. The key is read at runtime and **never** appears in the source code.

中：

`secrets.json`（**已被 gitignore，不会提交**）：

```json
{ "glm_auth_token": "<你的智谱 GLM API Key，格式：id.secret>" }
```

这个 key **只**用于健康探测某个 provider 的接口（发一个极小的 `/v1` 请求）。没有它面板照常运行，只是少了连通性检测。key 在运行时读取，**绝不**出现在源码里。

## API

| Method | Path | 作用 / Purpose |
|---|---|---|
| GET | `/api/status` | 全部状态 / full status |
| GET | `/api/proxy/scan` | 扫描在监听的代理端口 / scan listening proxy ports |
| POST | `/api/apply/{terminal\|git\|vscode\|ccswitch}` | 同步当前代理到指定目标 / sync current proxy to a target |
| GET | `/api/claude/providers` | provider 列表（后端已实现，前端暂未接入） |

## Known Issues / 已知问题

- **FlClash doesn't listen after restart.** FlClash sometimes stops listening on its configured port (e.g. 7890) after a restart. Workaround: open FlClash and toggle the proxy core manually. This is a FlClash bug, not a network issue.
- **DeepSeek / Zhipu GLM are not affected by the proxy.** With `no_proxy` set in `~/.zshrc`, these providers connect directly and still work when the proxy is down.

中：

- **FlClash 重启后不监听**：FlClash 有个 bug，重启后经常不在配置端口（如 7890）上监听。临时办法：打开 FlClash 手动重启代理核心。这是 FlClash 软件的问题，不是网络问题。
- **DeepSeek / 智谱 GLM 不受代理影响**：`~/.zshrc` 里设了 `no_proxy`，这两个 provider 直连，代理挂了也不影响。

## Files / 文件

| File | Role / 作用 |
|---|---|
| `server.py` | Python backend (stdlib `http.server`) / Python 后端（标准库） |
| `templates/index.html` | Frontend page, auto-refresh / 前端页面，自动刷新 |
| `secrets.example.json` | Template for `secrets.json` / `secrets.json` 模板 |
| `启动.command` | macOS double-click launcher / macOS 双击启动脚本 |

## Debug / 调试

```bash
curl http://127.0.0.1:8866/api/status | python3 -m json.tool
```
