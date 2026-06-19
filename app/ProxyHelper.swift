import AppKit
import Foundation

// ProxyHelper - 菜单栏代理工具（纯原生，无网页无 Python）
// 编译: swiftc -O -sdk $(xcrun --show-sdk-path) -target arm64-apple-macosx14.0 \
//       -o ProxyHelper ProxyHelper.swift Common.swift ProxyDetect.swift \
//       ConfigSync.swift StatusCollector.swift PanelView.swift \
//       -framework AppKit -framework Foundation -lsqlite3

// ── App Delegate ──
class AppDelegate: NSObject, NSApplicationDelegate, PanelDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var blur: NSVisualEffectView!
    var panelView: PanelView!
    var localMonitor: Any?
    var globalMonitor: Any?
    var isRefreshing = false
    var panelSize = NSSize(width: 280, height: 380)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            if let img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                 accessibilityDescription: "ProxyHelper")?
                                 .withSymbolConfiguration(cfg) {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🔁"
            }
            button.action = #selector(togglePanel)
            button.target = self
        }

        // 无边框透明窗口，承载毛玻璃（透出桌面壁纸）
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 毛玻璃层：跟随系统深浅色
        blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        // 原生面板界面，贴满毛玻璃
        panelView = PanelView()
        panelView.delegate = self
        panelView.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            panelView.topAnchor.constraint(equalTo: blur.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur

        // 内容自适应：按实际布局算高度，消除底部大片留白（+14 底部内边距）
        panelView.layoutSubtreeIfNeeded()
        panelSize.height = max(panelView.fittingSize.height + 14, 400)
        panel.setFrame(NSRect(origin: .zero, size: panelSize), display: false)
        blur.frame = NSRect(origin: .zero, size: panelSize)
    }

    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = statusItem.button, let btnWindow = button.window else { return }
        // 面板贴在状态栏图标正下方
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = btnWindow.frame.midX - panelSize.width / 2
        x = max(screen.minX, min(x, screen.maxX - panelSize.width))
        let y = btnWindow.frame.minY - panelSize.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        startMonitors()
        refresh()              // 打开即刷新
    }

    func hidePanel() {
        panel.orderOut(nil)
        stopMonitors()
    }

    // 刷新：后台探测网络（耗时），回主线程渲染。绝不阻塞 UI 线程。
    func refresh(silent: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if !silent { DispatchQueue.main.async { self.panelView.setRefreshing() } }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = getFullStatus()
            DispatchQueue.main.async {
                self.panelView.render(status)
                self.isRefreshing = false
            }
        }
    }

    // MARK: - PanelDelegate（点击同步 / Hermes 直连）

    func panelClick(target: SyncTarget) {
        runAction(target: target) { applyTarget(target, cur: detectCurrentProxy()) }
    }
    func panelClickHermesDirect() {
        runAction { setHermesDirect() }
    }
    func panelClickHermesUndirect() {
        runAction { unsetHermesDirect() }
    }

    // 后台执行操作 → 回主线程提示 + 刷新
    private func runAction(target: SyncTarget? = nil, _ work: @escaping () -> ApplyResult) {
        if let t = target {
            DispatchQueue.main.async { self.panelView.showSyncing(target: t) }
        } else {
            DispatchQueue.main.async { self.panelView.setMsg("同步中…", .info) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async {
                if target != nil {
                    self.refresh(silent: true)
                } else {
                    self.panelView.setMsg(r.message, r.ok ? .success : .error)
                    self.refresh()
                }
            }
        }
    }

    // 点面板外任意处即关闭：本地监听管自己 app 的事件，全局监听管其他 app 的事件
    func startMonitors() {
        guard localMonitor == nil && globalMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            // 点状态栏图标或面板内部不处理
            if event.window === self.statusItem.button?.window || event.window === self.panel {
                return event
            }
            self.hidePanel()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.hidePanel() }
        }
    }

    func stopMonitors() {
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
    }
}

// ── 主入口 ──
// 多文件编译时顶层代码不被允许，用 @main 结构体作为程序入口
@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
