import Foundation

// ── 状态汇总模块 ──
// 对应 server.py 的 Claude Code / Hermes 状态读取，以及前端的一致性判断 + 全量汇总。

// Claude Code 状态
struct ClaudeStatus {
    let configured: Bool
    let working: Bool
    let provider: String
    let model: String
}

// Hermes 状态
struct HermesStatus {
    let configured: Bool
    let provider: String
    let model: String
    let direct: Bool
}

// 全量状态（一次刷新拿到的所有数据）
struct FullStatus {
    let current: CurrentProxy
    let zshrcProxy: ZshrcProxy
    let git: GitStatus
    let claudeCode: ClaudeStatus
    let ccSwitch: CcswitchStatus
    let hermes: HermesStatus
    let vscode: VscodeStatus
}

// MARK: - Claude Code

// 从 base_url 域名识别服务商
func identifyProvider(_ baseUrl: String) -> String {
    let mapping: [(domain: String, name: String)] = [
        ("bigmodel.cn", "Zhipu GLM"),
        ("deepseek.com", "DeepSeek"),
        ("moonshot.cn", "Kimi"),
        ("ofox.ai", "ofox"),
        ("cherryin", "cherryIN"),
        ("openai.com", "OpenAI"),
        ("anthropic.com", "Anthropic Official"),
    ]
    for m in mapping where baseUrl.contains(m.domain) { return m.name }
    return "unknown"
}

// 实测 Claude 接口能否通：POST /v1/messages
func testClaudeApi(baseUrl: String, token: String, model: String, timeout: TimeInterval = 10) -> Bool {
    let endpoint = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    guard let url = URL(string: endpoint + "/v1/messages") else { return false }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = timeout
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(token, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
        "model": model,
        "max_tokens": 5,
        "messages": [["role": "user", "content": "hi"]],
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        if let r = resp as? HTTPURLResponse, r.statusCode == 200 { ok = true }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return ok
}

func getClaudeStatus() -> ClaudeStatus {
    guard let text = readFileText(CLAUDE_SETTINGS),
          let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ClaudeStatus(configured: false, working: false, provider: "unknown", model: "unknown")
    }
    let env = (obj["env"] as? [String: Any]) ?? [:]
    let baseUrl = (env["ANTHROPIC_BASE_URL"] as? String) ?? ""
    let token = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? ""
    let model = (env["ANTHROPIC_MODEL"] as? String) ?? "unknown"
    let provider = identifyProvider(baseUrl)
    var working = false
    if !baseUrl.isEmpty && !token.isEmpty {
        working = testClaudeApi(baseUrl: baseUrl, token: token, model: model, timeout: 3)
    }
    return ClaudeStatus(configured: true, working: working, provider: provider, model: model)
}

// MARK: - Hermes

// 取 model: 块下的某个字段（default/provider/base_url）
private func hermesField(_ text: String, key: String) -> String {
    // 先定位 model: 块（其后紧跟缩进行），没匹配到就用全文兜底
    var section = text
    if let block = matchFirst(#"(?ms)model:\s*\n((?:[ \t]{1,6}\S.*\n?)+)"#, in: text) {
        section = block
    }
    return matchFirst(#"(?m)\#(key):\s*(\S+)"#, in: section) ?? "unknown"
}

func getHermesStatus() -> HermesStatus {
    guard let text = readFileText(HERMES_CONFIG) else {
        return HermesStatus(configured: false, provider: "unknown", model: "unknown", direct: false)
    }
    let provider = hermesField(text, key: "provider")
    let model = hermesField(text, key: "default")
    let baseUrl = hermesField(text, key: "base_url")
    // 直连判定：deepseek 且指向官方 API
    let direct = provider == "deepseek" && baseUrl.contains("api.deepseek.com")
    return HermesStatus(configured: true, provider: provider, model: model, direct: direct)
}

// Hermes 切回 DeepSeek 直连：正则改 model 块的服务商/地址/模型，保留其他内容
func setHermesDirect() -> ApplyResult {
    guard let content = readFileText(HERMES_CONFIG) else {
        return ApplyResult(ok: false, message: "Hermes 配置文件不存在")
    }
    // 匹配 model:\n 后紧跟的缩进块
    guard let re = try? NSRegularExpression(pattern: #"(?ms)(model:\n)((?:[ \t]+\S.*\n?)+)"#, options: []) else {
        return ApplyResult(ok: false, message: "正则编译失败")
    }
    let nsr = NSRange(content.startIndex..., in: content)
    guard let m = re.firstMatch(in: content, options: [], range: nsr), m.numberOfRanges > 2,
          let headerRange = Range(m.range(at: 1), in: content),
          let bodyRange = Range(m.range(at: 2), in: content) else {
        return ApplyResult(ok: false, message: "找不到 model 配置块")
    }
    let header = String(content[headerRange])
    var body = String(content[bodyRange])
    body = rewriteField(body, key: "default", value: "deepseek-v4-pro")
    body = rewriteField(body, key: "provider", value: "deepseek")
    body = rewriteField(body, key: "base_url", value: "https://api.deepseek.com")
    let oldBlock = header + String(content[bodyRange])
    let newBlock = header + body
    if oldBlock == newBlock {
        return ApplyResult(ok: true, message: "Hermes 已是 DeepSeek 直连，无需修改")
    }
    let newContent = content.replacingOccurrences(of: oldBlock, with: newBlock)
    do {
        try newContent.write(toFile: HERMES_CONFIG, atomically: true, encoding: .utf8)
        return ApplyResult(ok: true, message: "Hermes 已切回 DeepSeek 直连")
    } catch {
        return ApplyResult(ok: false, message: "写入失败: \(error)")
    }
}

// Hermes 取消 DeepSeek 直连：清除 model 块的 provider/base_url，恢复自身默认
func unsetHermesDirect() -> ApplyResult {
    guard let content = readFileText(HERMES_CONFIG) else {
        return ApplyResult(ok: false, message: "Hermes 配置文件不存在")
    }
    guard let re = try? NSRegularExpression(pattern: #"(?ms)(model:\n)((?:[ \t]+\S.*\n?)+)"#, options: []) else {
        return ApplyResult(ok: false, message: "正则编译失败")
    }
    let nsr = NSRange(content.startIndex..., in: content)
    guard let m = re.firstMatch(in: content, options: [], range: nsr), m.numberOfRanges > 2,
          let headerRange = Range(m.range(at: 1), in: content),
          let bodyRange = Range(m.range(at: 2), in: content) else {
        return ApplyResult(ok: false, message: "找不到 model 配置块")
    }
    let header = String(content[headerRange])
    var body = String(content[bodyRange])
    // 清除 provider 和 base_url，让 Hermes 用自身默认
    body = rewriteField(body, key: "provider", value: "")
    body = rewriteField(body, key: "base_url", value: "")
    let oldBlock = header + String(content[bodyRange])
    let newBlock = header + body
    if oldBlock == newBlock {
        return ApplyResult(ok: true, message: "Hermes 已在使用自身默认配置")
    }
    let newContent = content.replacingOccurrences(of: oldBlock, with: newBlock)
    do {
        try newContent.write(toFile: HERMES_CONFIG, atomically: true, encoding: .utf8)
        return ApplyResult(ok: true, message: "Hermes 已恢复自身默认配置")
    } catch {
        return ApplyResult(ok: false, message: "写入失败: \(error)")
    }
}

// 把块内 "key: 旧值" 整行替换成 "key: 新值"（NSRegularExpression 模板替换）
private func rewriteField(_ text: String, key: String, value: String) -> String {
    let pattern = #"(?m)(\b\#(key):\s*).*"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\(key): \(value)")
}

// MARK: - 一致性判断（移植 index.html consistentOf）

// 某个目标当前的代理设置是否与"想要的"一致
// wantDirect：TUN/none/不可用端口应设直连；可用端口应填端口
func consistent(_ target: SyncTarget, cur: CurrentProxy, full: FullStatus) -> Bool {
    let wantDirect = !shouldSyncPortProxy(cur)
    let wantUrl = shouldSyncPortProxy(cur) ? "http://127.0.0.1:\(cur.port!)" : nil
    switch target {
    case .terminal:
        let z = full.zshrcProxy
        return wantDirect ? !z.enabled : (z.enabled && z.port == cur.port)
    case .git:
        return full.git.consistent
    case .vscode:
        let p = full.vscode.proxy
        return wantDirect ? (p == nil) : (p == wantUrl)
    case .ccswitch:
        let p = full.ccSwitch.globalProxy
        return wantDirect ? (p == nil) : (p == wantUrl)
    }
}

// MARK: - 全量汇总

// 一次性收集全部状态（含网络探测，耗时，应在后台线程调用）
func getFullStatus() -> FullStatus {
    let cur = detectCurrentProxy()
    return FullStatus(
        current: cur,
        zshrcProxy: getZshrcProxyStatus(),
        git: getGitStatus(cur: cur),
        claudeCode: getClaudeStatus(),
        ccSwitch: getCcswitchStatus(),
        hermes: getHermesStatus(),
        vscode: getVscodeStatus()
    )
}
