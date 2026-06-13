# Claude Code Proxy Panel

> A local macOS web panel that centralizes **proxy-status monitoring** and **Claude Code provider switching** — built to live alongside **FlClash** (proxy) and **CC Switch** (provider manager).

> 一个 macOS 本地网页面板，把**代理状态监控**和 **Claude Code 的 provider 切换**集中到一页，专门配合 **FlClash**（代理）和 **CC Switch**（provider 管理）使用。

---

## Features / 功能

- **Proxy status at a glance** — auto-detects whether the configured FlClash port is listening.
- **One-click fix** — when the port changes, syncs the new port into CC Switch's `global_proxy_url` so Claude Code keeps working.
- **Provider switching** — reads every provider from the CC Switch database; click a button to switch Claude Code's active provider and sync `settings.json`.
- **Zero dependencies** — pure Python standard library; no `pip install` needed.
- **Auto-refresh** — the page refreshes itself every 30 seconds.

中：

- **代理状态一目了然**：自动检测 FlClash 配置端口是否在监听。
- **一键修复**：端口变了，自动把新端口写进 CC Switch 的 `global_proxy_url`，让 Claude Code 继续可用。
- **切换 provider**：从 CC Switch 数据库读出所有 provider，点按钮切换并同步 Claude Code 的 `settings.json`。
- **零依赖**：纯 Python 标准库，无需 `pip install`。
- **自动刷新**：页面每 30 秒自动刷新一次。

## Prerequisites / 前置条件

- **macOS** — the launcher and `no_proxy` setup assume macOS/zsh.
- **Python 3** — system Python is fine.
- **FlClash** — the proxy client whose port this panel monitors.
- **CC Switch** — a Claude Code provider manager; this panel reads/writes its database. *(This panel is a companion to CC Switch — without it the switching features have nothing to read.)*

中：

- **macOS**：启动脚本和 `no_proxy` 设置都假定 macOS/zsh。
- **Python 3**：系统自带即可。
- **FlClash**：被监控端口的代理客户端。
- **CC Switch**：Claude Code 的 provider 管理工具，本面板读写它的数据库。（本面板是 CC Switch 的配套，没有 CC Switch，切换功能无从读起。）

## Quick Start / 快速开始

```bash
git clone https://github.com/guobiaochen-tech/claude-code-proxy-panel.git
cd claude-code-proxy-panel
cp secrets.example.json secrets.json   # then edit secrets.json with your key
python3 server.py
```

Then open <http://127.0.0.1:8866> in your browser, or double-click **`启动.command`**.

中：

```bash
# 同上命令
cp secrets.example.json secrets.json   # 然后把 secrets.json 里的 key 改成你自己的
python3 server.py
```

浏览器打开 <http://127.0.0.1:8866>，或双击 **`启动.command`**。

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

## How it works / 工作原理

- Reads CC Switch's configured proxy port and checks whether it's listening.
- On **fix**, rewrites `global_proxy_url` (CC Switch DB) and Claude Code's `settings.json`.
- Lists all providers from the CC Switch DB and lets you set the active one with one click.

中：

- 读取 CC Switch 配置的代理端口，检测是否在监听。
- 点**修复**时，重写 CC Switch 数据库里的 `global_proxy_url` 和 Claude Code 的 `settings.json`。
- 列出 CC Switch 数据库里的所有 provider，可一键设为当前。

## Known Issues / 已知问题

- **FlClash doesn't listen after restart.** FlClash sometimes stops listening on its configured port (e.g. 7890) after a restart. Workaround: open FlClash and toggle the proxy core manually. This is a FlClash bug, not a network issue.
- **DeepSeek / Zhipu GLM are not affected by the proxy.** With `no_proxy` set in `~/.zshrc`, these providers connect directly and still work when the proxy is down.

中：

- **FlClash 重启后不监听**：FlClash 有个 bug，重启后经常不在配置端口（如 7890）上监听。临时办法：打开 FlClash 手动重启代理核心。这是 FlClash 软件的问题，不是网络问题。
- **DeepSeek / 智谱 GLM 不受代理影响**：`~/.zshrc` 里设了 `no_proxy`，这两个 provider 直连，代理挂了也不影响。

## Files / 文件

| File | Role / 作用 |
|---|---|
| `server.py` | Python backend, stdlib only / Python 后端，纯标准库 |
| `templates/index.html` | Frontend page / 前端页面 |
| `secrets.example.json` | Template for `secrets.json` / `secrets.json` 模板 |
| `启动.command` | macOS double-click launcher / macOS 双击启动脚本 |

## Debug / 调试

```bash
curl http://127.0.0.1:8866/api/status | python3 -m json.tool
```
