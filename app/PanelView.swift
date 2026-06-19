import AppKit
import ServiceManagement

// ── 原生面板界面 ──
// 用 AppKit 控件重画 index.html 的四块：顶部代理栏、同步目标、Claude/Hermes 行、消息。
// 背景透明，让外层 NSVisualEffectView 毛玻璃透出桌面。文字用语义色跟随系统深浅。

// 配色（状态色固定 sRGB；文字色用语义色跟随系统）
let greenColor = NSColor(srgbRed: 0x34/255, green: 0xc7/255, blue: 0x59/255, alpha: 1)
let redColor = NSColor(srgbRed: 0xff/255, green: 0x3b/255, blue: 0x30/255, alpha: 1)
let yellowColor = NSColor(srgbRed: 0xff/255, green: 0xcc/255, blue: 0x00/255, alpha: 1)
let blueColor = NSColor(srgbRed: 0x0a/255, green: 0x84/255, blue: 0xff/255, alpha: 1)

// 按钮文字常量（避免 -O 优化吞掉中文字符串）
let btnDirectTitle = "写死 DeepSeek"
let btnUndirectTitle = "取消写死"
let refreshingText = "刷新中…"
let syncingText = "同步中…"

// 面板与外部的交互
protocol PanelDelegate: AnyObject {
    func panelClick(target: SyncTarget)
    func panelClickHermesDirect()
    func panelClickHermesUndirect()
}

// MARK: - 状态圆点

final class StatusDot: NSView {
    var color: NSColor = NSColor.tertiaryLabelColor {
        didSet { applyColor() }
    }
    var pulsing = false {
        didSet {
            if pulsing { startPulse() } else { stopPulse() }
        }
    }

    // size：顶部用默认 12（醒目），行内状态点用 7
    private let dotSize: CGFloat
    init(size: CGFloat = 12) {
        dotSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size / 2
        applyColor()
    }
    required init?(coder: NSCoder) { fatalError() }

    // 中心实心圆 + 同色柔光晕，比扁平圆点更有质感
    private func applyColor() {
        layer?.backgroundColor = color.cgColor
        layer?.shadowColor = color.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = dotSize * 0.5
        layer?.shadowOffset = .zero
    }

    private func startPulse() {
        stopPulse()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.3
        anim.duration = 0.75
        anim.autoreverses = true
        anim.repeatCount = .infinity
        layer?.add(anim, forKey: "pulse")
    }
    private func stopPulse() {
        layer?.removeAnimation(forKey: "pulse")
    }
}

// MARK: - 可点击容器

final class ClickableStack: NSStackView {
    var onClick: (() -> Void)?
    private var hovered = false
    private var pressed = false
    private var baseColor: CGColor?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateBg() }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; updateBg() }
    override func mouseDown(with event: NSEvent) { pressed = true; updateBg() }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        updateBg()
        onClick?()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    private func updateBg() {
        let base = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        let hover = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        let press = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = pressed ? press : (hovered ? hover : base)
    }
}

// MARK: - 退出按钮（点击+悬停）

final class QuitButton: NSView {
    private var hovered = false
    private var pressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateBg() }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; updateBg() }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateBg()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.terminate(nil)
        }
    }
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    private func updateBg() {
        let base = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        let hover = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        let press = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = pressed ? press : (hovered ? hover : base)
    }
}

// MARK: - 同步目标按钮

final class TargetView: NSView {
    let dot = StatusDot(size: 6)
    let nameLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    var warn = false { didSet { updateStyle() } }
    var onClick: (() -> Void)?
    private var hovered = false
    private var pressed = false
    var syncing = false

    init(name: String, systemImage: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        updateStyle()

        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center

        stateLabel.font = .systemFont(ofSize: 9)
        stateLabel.alignment = .right

        for v in [nameLabel, stateLabel, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            // 名称：水平居中，顶部
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            // 状态圆点 + 文字：底部水平居中
            stateLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -4),
            stateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            dot.leadingAnchor.constraint(equalTo: stateLabel.trailingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateStyle() {
        // syncing 时不覆盖状态文字和圆点
        if syncing { return }
        // 背景：默认半透，悬停/按下时加深，给出"活着"的反馈
        let base = NSColor.separatorColor.withAlphaComponent(0.28)
        let bg = pressed ? base.withAlphaComponent(0.6)
              : (hovered ? base.withAlphaComponent(0.5) : base)
        layer?.backgroundColor = bg.cgColor
        if warn {
            layer?.borderWidth = 1
            layer?.borderColor = yellowColor.withAlphaComponent(0.55).cgColor
            dot.color = yellowColor
            stateLabel.stringValue = "待同步"
            stateLabel.textColor = yellowColor
        } else {
            layer?.borderWidth = 0
            dot.color = greenColor
            stateLabel.stringValue = "已同步"
            stateLabel.textColor = greenColor
        }
    }

    // 显示"同步中…"状态，覆盖 warn 样式
    func showSyncing() {
        syncing = true
        stateLabel.stringValue = syncingText
        stateLabel.textColor = blueColor
        dot.color = blueColor
        layer?.borderWidth = 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateStyle() }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; updateStyle() }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateStyle()
        onClick?()
    }
    override func mouseUp(with event: NSEvent) { pressed = false; updateStyle() }
    // 鼠标悬停变手型
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 主面板

final class PanelView: NSView {
    weak var delegate: PanelDelegate?

    // 顶部代理栏
    private let dot = StatusDot()
    private let titleLabel = NSTextField(labelWithString: refreshingText)
    private let hintLabel = NSTextField(labelWithString: "")

    // 同步目标
    private var targetViews: [SyncTarget: TargetView] = [:]

    // 底部两行
    private let ccName = makeName("Claude")
    private let ccVal = makeMono()
    private let ccDot = StatusDot(size: 7)
    private let ccTag = makeTag()
    private let heName = makeName("Hermes")
    private let heVal = makeMono()
    private let heDot = StatusDot(size: 7)
    private let heTag = makeTag()
    // 退出按钮
    private lazy var quitButton: QuitButton = {
        let v = QuitButton()
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor

        let label = NSTextField(labelWithString: "退出")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()

    // 开机自启
    // 开机自启开关
    private let launchSwitch: NSSwitch = {
        let s = NSSwitch()
        s.controlSize = .small
        s.state = SMAppService.mainApp.status == .enabled ? .on : .off
        s.target = nil  // 在 buildLayout 中设置
        return s
    }()

    // 消息
    private let msgLabel = NSTextField(labelWithString: "")
    private var msgClear: DispatchWorkItem?

    // 底部信息
    private let footerLabel: NSTextField = {
        let f = NSTextField(labelWithString: "ProxyHelper · 1915199181@qq.com")
        f.font = .systemFont(ofSize: 9)
        f.textColor = .tertiaryLabelColor
        f.alignment = .center
        return f
    }()

    init() {
        super.init(frame: .zero)
        // 构建 4 个目标按钮（在 init 里才能引用 self 绑定点击回调）
        // 名称 + SF Symbol 图标：终端/git/VS Code/CC Switch
        let meta: [SyncTarget: (name: String, icon: String)] = [
            .terminal: ("终端", "terminal"),
            .git: ("git", "arrow.triangle.branch"),
            .vscode: ("VS Code", "chevron.left.forwardslash.chevron.right"),
            .ccswitch: ("CC Switch", "arrow.2.squarepath"),
        ]
        for t in SyncTarget.allCases {
            let m = meta[t] ?? (t.rawValue, "circle")
            let v = TargetView(name: m.name, systemImage: m.icon)
            v.onClick = { [weak self] in self?.delegate?.panelClick(target: t) }
            targetViews[t] = v
        }
        // 标题样式
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right

        msgLabel.font = .systemFont(ofSize: 12)
        msgLabel.lineBreakMode = .byTruncatingTail
        msgLabel.maximumNumberOfLines = 2

        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 布局

    private func buildLayout() {
        let pad: CGFloat = 16

        // 顶部代理栏（横排：圆点 + 标题 + 弹性占位 + hint）
        let proxyBar = NSStackView(views: [dot, titleLabel, makeSpacer(), hintLabel])
        proxyBar.orientation = .horizontal
        proxyBar.spacing = 10
        proxyBar.alignment = .centerY

        // 顶部视觉重心：圆角卡片包裹代理栏，与下方列表拉开层次
        let proxyCard = makeCard()
        proxyBar.translatesAutoresizingMaskIntoConstraints = false
        proxyCard.addSubview(proxyBar)
        NSLayoutConstraint.activate([
            proxyBar.topAnchor.constraint(equalTo: proxyCard.topAnchor, constant: 12),
            proxyBar.bottomAnchor.constraint(equalTo: proxyCard.bottomAnchor, constant: -12),
            proxyBar.leadingAnchor.constraint(equalTo: proxyCard.leadingAnchor, constant: 14),
            proxyBar.trailingAnchor.constraint(equalTo: proxyCard.trailingAnchor, constant: -14),
        ])

        // 分组标题行：左边"一键同步"，右边开机自启开关
        let launchLabel = NSTextField(labelWithString: "开机自启")
        launchLabel.font = .systemFont(ofSize: 10)
        launchLabel.textColor = .tertiaryLabelColor
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunch)
        let syncHeader = NSStackView(views: [makeSectionTitle("一键同步"), makeSpacer(), launchLabel, launchSwitch])
        syncHeader.orientation = .horizontal
        syncHeader.spacing = 6
        syncHeader.alignment = .centerY

        let targetRow1 = makeTargetRow([.terminal, .git])
        let targetRow2 = makeTargetRow([.vscode, .ccswitch])

        // Claude 行：名称靠上，信息靠下
        let ccInfoRow = NSStackView(views: [ccVal, ccDot, ccTag])
        ccInfoRow.orientation = .horizontal
        ccInfoRow.spacing = 4
        ccInfoRow.alignment = .centerY

        let ccRow = NSView()
        ccRow.wantsLayer = true
        ccRow.layer?.cornerRadius = 10
        ccRow.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        ccName.translatesAutoresizingMaskIntoConstraints = false
        ccInfoRow.translatesAutoresizingMaskIntoConstraints = false
        ccRow.addSubview(ccName)
        ccRow.addSubview(ccInfoRow)
        NSLayoutConstraint.activate([
            ccName.centerXAnchor.constraint(equalTo: ccRow.centerXAnchor),
            ccName.topAnchor.constraint(equalTo: ccRow.topAnchor, constant: 4),
            ccInfoRow.centerXAnchor.constraint(equalTo: ccRow.centerXAnchor),
            ccInfoRow.bottomAnchor.constraint(equalTo: ccRow.bottomAnchor, constant: -4),
        ])

        // Hermes 行：名称靠上，信息靠下
        let heInfoRow = NSStackView(views: [heVal, heDot, heTag])
        heInfoRow.orientation = .horizontal
        heInfoRow.spacing = 4
        heInfoRow.alignment = .centerY

        let heRow = ClickableStack()
        heRow.wantsLayer = true
        heRow.layer?.cornerRadius = 10
        heRow.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        heName.translatesAutoresizingMaskIntoConstraints = false
        heInfoRow.translatesAutoresizingMaskIntoConstraints = false
        heRow.addSubview(heName)
        heRow.addSubview(heInfoRow)
        NSLayoutConstraint.activate([
            heName.centerXAnchor.constraint(equalTo: heRow.centerXAnchor),
            heName.topAnchor.constraint(equalTo: heRow.topAnchor, constant: 4),
            heInfoRow.centerXAnchor.constraint(equalTo: heRow.centerXAnchor),
            heInfoRow.bottomAnchor.constraint(equalTo: heRow.bottomAnchor, constant: -4),
        ])
        heRow.onClick = { [weak self] in
            guard let self = self else { return }
            // 根据标签文字判断当前状态
            if self.heTag.stringValue == "已写死 DeepSeek" {
                self.delegate?.panelClickHermesUndirect()
            } else {
                self.delegate?.panelClickHermesDirect()
            }
        }

        // 加入面板并启用 Auto Layout
        let blocks: [NSView] = [proxyCard, syncHeader, targetRow1, targetRow2, ccRow, heRow, msgLabel, quitButton, footerLabel]
        for v in blocks {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // 纵向堆叠：分区靠 header 与留白隔开，不再用分隔线
        NSLayoutConstraint.activate([
            proxyCard.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            syncHeader.topAnchor.constraint(equalTo: proxyCard.bottomAnchor, constant: 18),
            targetRow1.topAnchor.constraint(equalTo: syncHeader.bottomAnchor, constant: 8),
            targetRow2.topAnchor.constraint(equalTo: targetRow1.bottomAnchor, constant: 6),
            ccRow.topAnchor.constraint(equalTo: targetRow2.bottomAnchor, constant: 12),
            heRow.topAnchor.constraint(equalTo: ccRow.bottomAnchor, constant: 6),
            msgLabel.topAnchor.constraint(equalTo: heRow.bottomAnchor, constant: 0),
            quitButton.topAnchor.constraint(equalTo: msgLabel.bottomAnchor, constant: -4),
            footerLabel.topAnchor.constraint(equalTo: quitButton.bottomAnchor, constant: 4),
        ])
        // 满宽元素左右贴边
        for v in [proxyCard, syncHeader, targetRow1, targetRow2, ccRow, heRow, msgLabel, quitButton, footerLabel] {
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad).isActive = true
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad).isActive = true
        }
        // 行高
        NSLayoutConstraint.activate([
            targetRow1.heightAnchor.constraint(equalToConstant: 46),
            targetRow2.heightAnchor.constraint(equalToConstant: 46),
            ccRow.heightAnchor.constraint(equalToConstant: 46),
            heRow.heightAnchor.constraint(equalToConstant: 46),
            quitButton.heightAnchor.constraint(equalToConstant: 46),
            ccDot.widthAnchor.constraint(equalToConstant: 8),
            ccDot.heightAnchor.constraint(equalToConstant: 8),
            heDot.widthAnchor.constraint(equalToConstant: 8),
            heDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        // val 占据中间空间，把状态点/tag/按钮推到右边
        for v in [ccVal, heVal] {
            v.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        }
        // 锁定面板宽度，防止刷新时内容文字变长导致面板被撑宽
        widthAnchor.constraint(equalToConstant: 280).isActive = true
    }

    // 一行两个等宽目标按钮
    private func makeTargetRow(_ targets: [SyncTarget]) -> NSStackView {
        let views = targets.compactMap { targetViews[$0] }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        row.alignment = .centerY
        return row
    }

    // MARK: 渲染数据

    // 显示"检测中…"
    func setRefreshing() {
        dot.color = NSColor.tertiaryLabelColor
        dot.pulsing = false
        titleLabel.stringValue = refreshingText
        hintLabel.stringValue = ""
    }

    // 用全量状态刷新整块面板
    func render(_ status: FullStatus) {
        let cur = status.current
        // 顶部代理栏：圆点三色（绿通/黄端口开但不通/红无代理），文字只两档
        switch cur.mode {
        case "tun":
            dot.color = cur.proxyOk ? greenColor : yellowColor
            dot.pulsing = !cur.proxyOk
            titleLabel.stringValue = "\(cur.app ?? "代理") · TUN"
            hintLabel.stringValue = cur.proxyOk ? "能上外网" : "不能上外网"
        case "port":
            titleLabel.stringValue = "\(cur.app ?? "代理") · \(cur.port ?? 0)"
            // 端口模式：系统代理开关没开 = 用户没在用代理 = 不能上外网（不管端口能不能转发）
            if cur.proxyOk && cur.systemProxy {
                dot.color = greenColor
                dot.pulsing = false
                hintLabel.stringValue = "能上外网"
            } else {
                dot.color = yellowColor
                dot.pulsing = true
                hintLabel.stringValue = "不能上外网"
            }
        default:
            dot.color = redColor
            dot.pulsing = false
            titleLabel.stringValue = "未检测到代理"
            hintLabel.stringValue = "不能上外网"
        }

        // 同步目标一致性
        for t in SyncTarget.allCases {
            targetViews[t]?.syncing = false
            targetViews[t]?.warn = !consistent(t, cur: cur, full: status)
        }

        // Claude 行
        let cc = status.claudeCode
        if !cc.configured {
            ccVal.stringValue = ""
            ccTag.stringValue = "未配置"
            ccTag.textColor = redColor
            ccDot.color = redColor
        } else {
            ccVal.stringValue = "\(cc.provider) · \(cc.model)"
            ccTag.stringValue = cc.working ? "正常" : "连不上"
            ccTag.textColor = cc.working ? greenColor : redColor
            ccDot.color = cc.working ? greenColor : redColor
        }

        // Hermes 行：按钮"写死 DeepSeek"；已写死→灰禁用并说明，未写死→可用
        let he = status.hermes
        if !he.configured {
            heVal.stringValue = ""
            heTag.stringValue = "未安装"
            heTag.textColor = .tertiaryLabelColor
            heDot.color = NSColor.tertiaryLabelColor
        } else {
            heVal.stringValue = "\(he.provider) · \(he.model)"
            if he.direct {
                heTag.stringValue = "已写死 DeepSeek"
                heTag.textColor = greenColor
                heDot.color = greenColor
            } else {
                heTag.stringValue = "未写死"
                heTag.textColor = redColor
                heDot.color = redColor
            }
        }
    }

    // 消息提示：success/error 4 秒后自动清空
    // 在按钮内显示"同步中…"
    func showSyncing(target: SyncTarget) {
        targetViews[target]?.showSyncing()
    }

    func setMsg(_ text: String, _ kind: MsgKind) {
        msgClear?.cancel()
        msgLabel.stringValue = text
        switch kind {
        case .info: msgLabel.textColor = blueColor
        case .success: msgLabel.textColor = greenColor
        case .error: msgLabel.textColor = redColor
        case .none: msgLabel.textColor = .secondaryLabelColor
        }
        if kind == .success || kind == .error {
            let item = DispatchWorkItem { [weak self] in
                self?.msgLabel.stringValue = ""
            }
            msgClear = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
        }
    }

    @objc private func hermesDirect() {
        delegate?.panelClickHermesDirect()
    }
    @objc private func hermesUndirect() {
        delegate?.panelClickHermesUndirect()
    }

    @objc private func toggleLaunch() {
        do {
            if launchSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("开机自启切换失败: \(error)")
            launchSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

}

enum MsgKind { case info, success, error, none }

// MARK: - 小工具：label 工厂 / 分隔线 / 弹性占位

private func makeName(_ text: String) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = .systemFont(ofSize: 14, weight: .medium)
    f.textColor = .labelColor
    f.alignment = .center
    return f
}
private func makeMono() -> NSTextField {
    let f = NSTextField(labelWithString: "")
    f.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    f.textColor = .secondaryLabelColor
    f.lineBreakMode = .byTruncatingTail
    f.cell?.truncatesLastVisibleLine = true
    f.cell?.wraps = false
    return f
}
private func makeTag() -> NSTextField {
    let f = NSTextField(labelWithString: "")
    f.font = .systemFont(ofSize: 9)
    f.alignment = .center
    return f
}
private func makeSectionTitle(_ text: String) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = .systemFont(ofSize: 11, weight: .semibold)
    f.textColor = .tertiaryLabelColor
    return f
}
// 圆角半透明卡片容器：用作顶部代理栏的视觉重心
private func makeCard() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.cornerRadius = 12
    v.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
    return v
}
private func makeSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
    v.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
    return v
}
