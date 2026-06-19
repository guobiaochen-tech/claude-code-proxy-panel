# ProxyHelper

macOS 菜单栏原生 App（状态栏图标 + 毛玻璃面板，纯 Swift / AppKit，无网页无 Python）：显示当前代理状态，并把当前代理一键同步到 **终端 / git / VS Code / CC Switch**；只读展示 **Codex / Hermes** 状态。配合 FlClash / Clash Verge（代理）和 CC Switch（provider 管理）使用。

## 功能

1. **当前代理** — 检测 FlClash / Clash Verge 谁在跑、是 TUN 模式还是端口监听、端口号、系统代理是否接管。
   - 🟢 绿：能上外网
   - 🟡 黄：端口开着但上不去外网
   - 🔴 红：未检测到代理
2. **同步到各软件** — 把当前代理（TUN→直连，端口→填端口）应用到 终端 / git / VS Code / CC Switch。每行 ✓ 已同步 / ⚠ 待同步，点击即同步。
3. **Codex** — 只读显示 provider / model + 连通性探测。**切换 provider 请在 CC Switch 软件里做**。
4. **Hermes** — 只读显示 provider / model；「写死 DeepSeek」按钮把 Hermes 强制切回 deepseek-v4-pro 官方 API。

## 关键设计

- **系统代理开关 = 代理总开关**：用户在 FlClash/Clash Verge 关掉系统代理，即便 mihomo 端口仍在监听，也视为"代理已停"，各软件随之判定待同步。
- **代理探测并发执行**：端口存活 + 代理实测 + 系统状态并发跑，刷新耗时 ~4s。
- **绝不阻塞 UI 线程**：所有网络探测在后台线程，结果回主线程渲染。

## 启动

```bash
cd ~/proxy-helper/app
swiftc -O -sdk $(xcrun --show-sdk-path) -target arm64-apple-macosx14.0 \
  -o ProxyHelper ProxyHelper.swift Common.swift ProxyDetect.swift \
  ConfigSync.swift StatusCollector.swift PanelView.swift \
  -framework AppKit -framework Foundation -lsqlite3
open ProxyHelper.app
```

## 源码结构（app/）

| 文件 | 职责 |
|---|---|
| `ProxyHelper.swift` | 入口：菜单栏图标、毛玻璃面板、刷新调度、点外部关闭、退出 |
| `Common.swift` | 路径常量、带超时 shell 调用、正则助手 |
| `ProxyDetect.swift` | 代理检测：端口存活、进程检测、TUN 检测、代理实测、yaml 解析 |
| `ConfigSync.swift` | 把当前代理同步到 terminal(.zshrc)/git/vscode/ccswitch(sqlite) |
| `StatusCollector.swift` | Codex / Hermes 状态读取、一致性判断、全量汇总 |
| `PanelView.swift` | 原生 AppKit 界面（四块布局）+ 状态色 |

详细设计与约定见 `AGENTS.md`。
