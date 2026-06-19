import Foundation
import Darwin

// ── 代理检测模块 ──
// 对应 server.py 的代理检测部分：端口存活、进程检测、TUN 检测、代理实测、配置读取。

// 单个代理软件的检测结果
struct ProxySource {
    let app: String            // "Clash Verge" / "FlClash"
    let running: Bool          // 主程序是否在跑（排除 helper 后台进程）
    let configPort: Int?       // 配置文件里写的 mixed-port
    let listening: Bool        // 该端口是否在监听
    let tunConfig: Bool        // 配置里是否开了 tun
}

// 当前代理汇总
struct CurrentProxy {
    let app: String?           // 活动软件名
    let mode: String           // "none" / "tun" / "port"
    let port: Int?             // 端口模式下的端口号
    let proxyOk: Bool          // 代理是否真能转发（实测）
    let tunActive: Bool        // 系统是否有 TUN 接管（带 IPv4 的 RUNNING utun）
    let systemProxy: Bool      // 系统代理开关是否打开（networksetup/scutil）
    let sources: [ProxySource] // 各软件明细
    let listeningPorts: [Int]  // 全部在监听的候选端口
}

// ── TCP 端口存活探测：非阻塞 connect + poll 超时（本地回环，不卡线程）──
func portAlive(_ port: Int, timeoutMS: Int32 = 300) -> Bool {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    // 设为非阻塞
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, size)
        }
    }
    if rc == 0 { return true }
    if errno != EINPROGRESS { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    if poll(&pfd, 1, timeoutMS) <= 0 { return false }  // 超时或出错
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0 { return false }
    return err == 0
}

// ── 通过指定代理端口实际转发一次请求，验证端到端能用 ──
// 端口能连上 ≠ 代理能转发：核心进程僵死时端口仍监听但转不动流量。
// 用 google generate_204（国内被墙，拿到 204/200 即证明端到端通）。
func proxyWorks(_ port: Int, timeout: TimeInterval = 3) -> Bool {
    return httpProbe(port: port, timeout: timeout)
}

// ── 强制不走代理端口，直连测系统能否出网（用于判断 TUN 是否真接管）──
func directReachable(timeout: TimeInterval = 3) -> Bool {
    return httpProbe(port: nil, timeout: timeout)
}

// port=nil：强制不走代理（空代理字典），测系统直连可达性
// port=数字：把请求经该端口转发，测代理能否转发
// 单目标短超时：用 gstatic generate_204（google 系，国内被墙，能拿到即证明翻出去了）
private func httpProbe(port: Int?, timeout: TimeInterval) -> Bool {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    if let port = port {
        // 经指定端口转发
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: port,
        ]
    } else {
        // 空字典=强制不走任何代理
        config.connectionProxyDictionary = [:]
    }
    let session = URLSession(configuration: config)
    guard let url = URL(string: "https://www.gstatic.com/generate_204") else { return false }
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    let task = session.dataTask(with: url) { _, resp, _ in
        if let r = resp as? HTTPURLResponse, r.statusCode == 200 || r.statusCode == 204 {
            ok = true
        }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + timeout)
    task.cancel()
    return ok
}

// ── 从环境变量 + .zshrc 读已配置的代理端口 ──
func getConfiguredPorts() -> Set<Int> {
    var ports = Set<Int>()
    for key in ["http_proxy", "https_proxy", "ALL_PROXY"] {
        if let val = ProcessInfo.processInfo.environment[key],
           let m = matchFirst(#":(\d+)"#, in: val),
           let p = Int(m) {
            ports.insert(p)
        }
    }
    if let text = readFileText(ZSHRC) {
        for m in matchAll(#"export\s+(?:http_proxy|https_proxy|ALL_PROXY)=.*?:(\d+)"#, in: text) {
            if let p = Int(m) { ports.insert(p) }
        }
    }
    return ports
}

// ── 检测含任一关键词的主程序是否在跑（排除 helper / mihomo 后台进程）──
// Clash Verge 的 io.github.clashverge.helper 装完即自启、主程序关了仍在；
// verge-mihomo 核心关 GUI 后也常驻——两者进程名都含 "verge" 会误判，需排除。
// 否则 Verge 关 GUI 后 mihomo 残留，仍判定 Verge 在跑，遮蔽其他代理（如 FlClash）。
func procRunning(_ keywords: [String]) -> Bool {
    let out = shell(["/bin/ps", "-Ao", "comm="])
    for ln in out.split(separator: "\n") {
        let low = ln.trimmingCharacters(in: .whitespaces).lowercased()
        if low.contains("helper") { continue }   // 特权助手
        if low.contains("mihomo") { continue }   // 核心进程（GUI 关了仍残留）
        if keywords.contains(where: { low.contains($0) }) { return true }
    }
    return false
}

// ── 系统是否有 TUN 接管（RUNNING 的 utun 且带 IPv4 地址）──
// 收紧：系统自带的 utun（iCloud 私密中继 / 系统 VPN / 接力）只有 IPv6 link-local，
// 而代理软件的 TUN 必然配 IPv4 地址（如 mihomo 默认 198.18.0.1）。
// 用"有 IPv4 的 RUNNING utun"区分真假 TUN，避免系统 utun 造成误判。
func tunActive() -> Bool {
    let out = shell(["/sbin/ifconfig"])
    var name = ""
    var running = false
    var hasIPv4 = false
    func hit() -> Bool { name.hasPrefix("utun") && running && hasIPv4 }
    for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.first.map({ !$0.isWhitespace }) == true {
            // 行首非空白 = 新网卡块；先结算上一块
            if hit() { return true }
            name = matchFirst(#"^(\S+):"#, in: line) ?? ""
            running = line.contains("RUNNING")
            hasIPv4 = false
        } else {
            if line.contains("RUNNING") { running = true }
            // "inet" + 空格 + 数字 = IPv4；inet6 不匹配（紧跟 6 而非空格）
            if line.range(of: #"inet \d"#, options: .regularExpression) != nil { hasIPv4 = true }
        }
    }
    return hit()
}

// ── 系统代理开关是否打开（macOS 全局 HTTP/HTTPS/SOCKS/PAC）──
// 与端口是否监听无关：用于面板区分"端口已开但系统未接管"与"系统正在走代理"。
// 读 scutil --proxy 的合并视图，任一使能位为 1 即视为打开。
func systemProxyActive() -> Bool {
    let out = shell(["/usr/sbin/scutil", "--proxy"])
    return testMatch(#"(?m)^\s*(?:HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable)\s*:\s*1\b"#, in: out)
}

// ── 从 yaml 配置读 mixed-port ──
func yamlMixedPort(_ path: String) -> Int? {
    guard let text = readFileText(path),
          let m = matchFirst(#"(?m)^mixed-port:\s*(\d+)"#, in: text) else { return nil }
    return Int(m)
}

// ── 从 yaml 配置读 tun 块里的 enable: true ──
func yamlTunEnabled(_ path: String) -> Bool {
    guard let text = readFileText(path),
          let block = matchFirst(#"(?ms)^tun:\s*\n((?:[ \t]+.+\n?)+)"#, in: text) else {
        return false
    }
    return testMatch(#"(?m)^\s+enable:\s*true"#, in: block)
}

// ── 扫描所有候选端口，返回实际在监听的 ──
func scanListeningPorts() -> [Int] {
    var candidates = Set<Int>(PROXY_PORTS)
    for path in [FLCLASH_CONFIG, CLASH_VERGE_CONFIG] {
        if let p = yamlMixedPort(path) { candidates.insert(p) }
    }
    // 也纳入 .zshrc/环境变量里配过的端口
    candidates.formUnion(getConfiguredPorts())
    return candidates.sorted().filter { portAlive($0) }
}

// ── 核心：当前哪个代理在跑 + TUN/端口模式 + 端口 ──
// 网络探测并发跑（端口存活 × N + 代理实测 + 系统直连测），总耗时≈单次最长探测而非累加。
func detectCurrentProxy() -> CurrentProxy {
    let specs: [(app: String, keys: [String], cfg: String)] = [
        ("Clash Verge", ["clash verge", "verge"], CLASH_VERGE_CONFIG),
        ("FlClash", ["flclash"], FLCLASH_CONFIG),
    ]

    // 第一阶段：并发探测每个软件的端口存活（本地回环，快）
    var sources: [ProxySource] = []
    let group = DispatchGroup()
    let lock = DispatchSemaphore(value: 1)
    // 预先占位，并发填充
    for _ in specs { sources.append(ProxySource(app: "", running: false, configPort: nil, listening: false, tunConfig: false)) }
    for (i, s) in specs.enumerated() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let port = yamlMixedPort(s.cfg)
            let src = ProxySource(
                app: s.app,
                running: procRunning(s.keys),
                configPort: port,
                listening: port != nil ? portAlive(port!) : false,
                tunConfig: yamlTunEnabled(s.cfg)
            )
            lock.wait(); defer { lock.signal() }
            sources[i] = src
            group.leave()
        }
    }
    // 系统状态也并发跑
    var tun = false, sys = false
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        tun = tunActive()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        sys = systemProxyActive()
        group.leave()
    }
    group.wait()

    // 第二阶段：活动软件确定后，并发实测代理可达性
    let running = sources.first(where: { $0.running })
    let fallback = running == nil ? sources.first(where: { $0.listening && $0.configPort != nil }) : nil
    let active = running ?? fallback

    var mode = "none", port: Int? = nil, app: String? = nil, proxyOk = false
    var probeOk = false  // 代理实测结果（线程安全填充）
    if let active = active {
        app = active.app
        if active.tunConfig && tun {
            mode = "tun"
        } else if active.listening {
            mode = "port"
            port = active.configPort
        }
        // 并发实测：TUN 测直连，端口测经端口转发
        if mode != "none" {
            let g2 = DispatchGroup()
            g2.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                probeOk = mode == "tun" ? directReachable() : proxyWorks(port ?? 0)
                g2.leave()
            }
            g2.wait()
            proxyOk = probeOk
        }
    }
    return CurrentProxy(
        app: app,
        mode: mode,
        port: port,
        proxyOk: proxyOk,
        tunActive: tun,
        systemProxy: sys,
        sources: sources,
        listeningPorts: sources.compactMap { $0.listening ? $0.configPort : nil }
    )
}
