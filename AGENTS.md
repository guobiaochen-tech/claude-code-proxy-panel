# ProxyHelper — 代理状态菜单栏面板

macOS 菜单栏原生 App（状态栏图标 + 毛玻璃面板，纯 Swift / AppKit，无网页无 Python）：显示当前代理状态，并把当前代理一键同步到 **终端 / git / VS Code / CC Switch**；只读展示 **Codex / Hermes** 状态。配合 FlClash / Clash Verge（代理）和 CC Switch（provider 管理）使用。

源码在 `app/`，编译产物 `app/ProxyHelper`。

## 启动

```bash
cd ~/proxy-helper/app
swiftc -O -sdk $(xcrun --show-sdk-path) -target arm64-apple-macosx14.0 \
  -o ProxyHelper ProxyHelper.swift Common.swift ProxyDetect.swift \
  ConfigSync.swift StatusCollector.swift PanelView.swift \
  -framework AppKit -framework Foundation -lsqlite3
./ProxyHelper
```

或直接运行已编译的 `app/ProxyHelper`。

## 文件（app/）

| 文件 | 职责 |
|---|---|
| `ProxyHelper.swift` | 入口：菜单栏图标、毛玻璃面板、刷新调度（后台探测→主线程渲染，30s）、点外部关闭、退出 |
| `Common.swift` | 路径常量、带超时 shell 调用、正则助手 |
| `ProxyDetect.swift` | 代理检测：端口存活、进程检测（排除 helper 后台进程）、TUN 检测、代理实测、yaml 解析 |
| `ConfigSync.swift` | 把当前代理同步到 terminal(.zshrc)/git/vscode/ccswitch(sqlite) |
| `StatusCollector.swift` | Codex / Hermes 状态读取、一致性判断、全量汇总 |
| `PanelView.swift` | 原生 AppKit 界面（四块布局）+ 状态色 |

## 功能（面板四块）

1. **当前代理** — 检测 FlClash / Clash Verge 谁在跑、是 TUN 模式还是端口监听、端口号、系统代理是否接管。绿=代理生效中（系统代理/TUN 接管且通），黄=端口已开但系统未走代理 或 代理不通，红=未检测到代理。
2. **同步到各软件** — 把当前代理（TUN→直连，端口→填端口）应用到 终端 / git / VS Code / CC Switch。每行 ✓ 已同步 / ⚠ 不一致，点击即同步。
3. **Codex** — 只读显示 provider / model + 连通性探测（真实 POST /v1/messages）。**切换 provider 请在 CC Switch 软件里做**。
4. **Hermes** — 只读显示 provider / model；「写死 DeepSeek」按钮把 Hermes 强制切回 deepseek-v4-pro 官方 API。

## 关键设计

- **检测靠配置 + 进程 + TUN 网卡 + 系统代理位**：读 FlClash/Clash Verge 的 yaml 配置取端口和 tun 开关，`ps` 查主程序（排除 helper 后台进程），`ifconfig` 查带 IPv4 的 RUNNING utun 网卡（系统自带 utun 只有 IPv6，以此排除误判），`scutil --proxy` 查系统代理开关。
- **端口能连 ≠ 代理能转发**：端口存活用非阻塞 connect + poll；代理能否真转发用经端口请求 google `generate_204` 实测。
- **绝不阻塞 UI 线程**：所有网络探测在 `DispatchQueue.global`，结果回主线程渲染。
- **TUN/端口判定**：配置开了 tun 且系统有带 IPv4 的 RUNNING utun → TUN 模式（各软件应设直连）；否则端口监听 → 端口模式（各软件填端口）。
- **系统代理开关 = 代理总开关**：`shouldSyncPortProxy`（`ConfigSync.swift`）只在 `mode=="port" && proxyOk && systemProxy` 时返回 true。用户在 FlClash/Clash Verge 里关掉系统代理，即便 mihomo 端口仍在监听、仍能转发，也视为"代理已停"——各目标应回到直连，按钮随之显示待同步。`consistent`/`applyTarget`/`getGitStatus` 全部经此函数联动，无需各自判断 systemProxy。
- **mode 仅做模式分类**：`mode`（none/tun/port）只描述"当前是哪种代理形态"，不直接决定同步行为；是否同步端口由 `shouldSyncPortProxy` 统一把关（已含 systemProxy）。面板顶部颜色另看 `systemProxy`：端口开但系统代理/TUN 都没接管 → 黄「端口已开·系统未走代理」。

## 退出

面板底部「退出」按钮 → `NSApp.terminate`，关闭整个 App 进程。
