import Foundation
import SQLite3

// ── 配置同步模块 ──
// 对应 server.py 的各目标读写：terminal(.zshrc)、git、vscode、ccswitch(sqlite)。
// 负责读取各目标的当前代理配置，以及把"当前代理"统一应用过去。

// 各目标当前状态（前端一致性判断要用到的字段）
struct ZshrcProxy { let enabled: Bool; let port: Int? }
struct GitStatus { let proxy: String?; let desired: String?; let consistent: Bool }
struct VscodeStatus { let configured: Bool; let proxy: String? }
struct CcswitchStatus { let configured: Bool; let globalProxy: String? }

// 应用操作的结果
struct ApplyResult { let ok: Bool; let message: String }

// 应用目标类型
enum SyncTarget: String, CaseIterable { case terminal, git, vscode, ccswitch }

// 端口模式、代理实测可转发、且系统代理开关已打开时，才把端口同步给各目标。
// 系统代理开关 = 代理总开关：用户在 FlClash/Clash Verge 关掉系统代理，
// 即便 mihomo 端口仍在监听、仍能转发，也视为"代理已停"，各目标应回到直连。
func shouldSyncPortProxy(_ cur: CurrentProxy) -> Bool {
    return cur.mode == "port" && cur.proxyOk && cur.port != nil && cur.systemProxy
}

// MARK: - terminal（.zshrc 的 export 代理行）

func getZshrcProxyStatus() -> ZshrcProxy {
    guard let text = readFileText(ZSHRC) else { return ZshrcProxy(enabled: false, port: nil) }
    // 匹配未注释的 export http_proxy/https_proxy/ALL_PROXY=...:端口，取端口号
    if let pStr = matchFirst(#"(?m)^export\s+(?:http_proxy|https_proxy|ALL_PROXY)=.*?:(\d+)"#, in: text),
       let port = Int(pStr) {
        return ZshrcProxy(enabled: true, port: port)
    }
    return ZshrcProxy(enabled: false, port: nil)
}

// 开/关终端代理。enable=true 写端口；enable=false 把 export 行注释掉
func toggleZshrcProxy(enable: Bool, port: Int?) -> ApplyResult {
    guard let text = readFileText(ZSHRC) else { return ApplyResult(ok: false, message: ".zshrc 不存在") }
    if enable {
        guard let port = port else { return ApplyResult(ok: false, message: "没有代理端口") }
        let proxyUrl = "http://127.0.0.1:\(port)"
        let lines = text.components(separatedBy: "\n")
        var newLines: [String] = []
        var added = false
        for line in lines {
            if line.range(of: #"^#?\s*export\s+(http_proxy|https_proxy|ALL_PROXY)="#, options: .regularExpression) != nil {
                if !added {
                    newLines.append("export http_proxy=\(proxyUrl)")
                    newLines.append("export https_proxy=\(proxyUrl)")
                    newLines.append("export ALL_PROXY=\(proxyUrl)")
                    added = true
                }
                continue  // 丢掉旧的代理行
            }
            newLines.append(line)
        }
        if !added {
            newLines.append("")
            newLines.append("# 终端代理")
            newLines.append("export http_proxy=\(proxyUrl)")
            newLines.append("export https_proxy=\(proxyUrl)")
            newLines.append("export ALL_PROXY=\(proxyUrl)")
        }
        do {
            try newLines.joined(separator: "\n").write(toFile: ZSHRC, atomically: true, encoding: .utf8)
            return ApplyResult(ok: true, message: "终端代理已开启 → \(proxyUrl)")
        } catch {
            return ApplyResult(ok: false, message: "写入失败: \(error)")
        }
    } else {
        // 关：把所有未注释的 export 代理行注释掉
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            if lines[i].range(of: #"^export\s+(http_proxy|https_proxy|ALL_PROXY)="#, options: .regularExpression) != nil {
                lines[i] = "#\(lines[i])"
            }
        }
        try? lines.joined(separator: "\n").write(toFile: ZSHRC, atomically: true, encoding: .utf8)
        return ApplyResult(ok: true, message: "终端代理已关闭（直连）")
    }
}

// MARK: - git

// 读 git 全局代理，判断是否与当前代理一致
func getGitStatus(cur: CurrentProxy) -> GitStatus {
    let out = shell(["/usr/bin/git", "config", "--global", "--get", "http.proxy"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let proxy = out.isEmpty ? nil : out
    let desired = shouldSyncPortProxy(cur) ? "http://127.0.0.1:\(cur.port!)" : nil
    return GitStatus(proxy: proxy, desired: desired, consistent: proxy == desired)
}

// direct=true 清掉 git 代理；否则写端口
func applyGit(direct: Bool, proxyUrl: String?) -> ApplyResult {
    for key in ["http.proxy", "https.proxy"] {
        if direct {
            _ = shell(["/usr/bin/git", "config", "--global", "--unset", key])
        } else if let url = proxyUrl {
            _ = shell(["/usr/bin/git", "config", "--global", key, url])
        }
    }
    return ApplyResult(ok: true, message: direct ? "git 代理已清除（直连）" : "git 代理已设置 → \(proxyUrl ?? "")")
}

// MARK: - VS Code

func getVscodeStatus() -> VscodeStatus {
    guard let text = readFileText(VSCODE_SETTINGS),
          let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return VscodeStatus(configured: false, proxy: nil)
    }
    let http = obj["http"] as? [String: Any]
    let proxy = http?["proxy"] as? String
    return VscodeStatus(configured: true, proxy: proxy)
}

// 写回 VSCode settings.json
private func writeVscodeSettings(_ settings: [String: Any]) -> ApplyResult {
    do {
        let dir = (VSCODE_SETTINGS as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .fragmentsAllowed])
        if let str = String(data: data, encoding: .utf8) {
            try str.write(toFile: VSCODE_SETTINGS, atomically: true, encoding: .utf8)
        }
        return ApplyResult(ok: true, message: "")
    } catch {
        return ApplyResult(ok: false, message: "写入失败: \(error)")
    }
}

// 读出当前 settings（失败返回空字典）
private func loadVscodeSettings() -> [String: Any] {
    if let text = readFileText(VSCODE_SETTINGS),
       let data = text.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return obj
    }
    return [:]
}

// 应用端口代理
func fixVscode(proxyUrl: String) -> ApplyResult {
    var settings = loadVscodeSettings()
    var http = (settings["http"] as? [String: Any]) ?? [:]
    http["proxy"] = proxyUrl
    http["proxyStrictSSL"] = false
    http["proxySupport"] = "on"
    settings["http"] = http
    let r = writeVscodeSettings(settings)
    return r.ok ? ApplyResult(ok: true, message: "VS Code 代理已设置 → \(proxyUrl)") : r
}

// VS Code 直连开关
func toggleVscodeDirect(enable: Bool, cur: CurrentProxy) -> ApplyResult {
    if enable {
        var settings = loadVscodeSettings()
        var http = (settings["http"] as? [String: Any]) ?? [:]
        http.removeValue(forKey: "proxy")
        http["proxySupport"] = "off"
        settings["http"] = http
        _ = writeVscodeSettings(settings)
        return ApplyResult(ok: true, message: "VS Code 已切换到直连")
    } else {
        guard let port = cur.port else { return ApplyResult(ok: false, message: "没有代理端口") }
        return fixVscode(proxyUrl: "http://127.0.0.1:\(port)")
    }
}

// MARK: - CC Switch（sqlite）

// 轻量 sqlite：打开→执行→关闭，返回第一行第一列文本
private func sqliteScalar(_ dbPath: String, _ sql: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open(dbPath, &db) == SQLITE_OK else { sqlite3_close(db); return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    if sqlite3_step(stmt) == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
    }
    return nil
}

// 执行带一个文本参数的写语句（UPDATE/INSERT/DELETE）
private func sqliteExecBind(_ dbPath: String, _ sql: String, _ param: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(dbPath, &db) == SQLITE_OK else { sqlite3_close(db); return false }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, param, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(stmt) == SQLITE_DONE
}

// 执行无参写语句（DELETE 等）
private func sqliteExec(_ dbPath: String, _ sql: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(dbPath, &db) == SQLITE_OK else { sqlite3_close(db); return false }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

func getCcswitchStatus() -> CcswitchStatus {
    guard FileManager.default.fileExists(atPath: CCSWITCH_DB) else {
        return CcswitchStatus(configured: false, globalProxy: nil)
    }
    let proxy = sqliteScalar(CCSWITCH_DB, "SELECT value FROM settings WHERE key='global_proxy_url'")
    return CcswitchStatus(configured: true, globalProxy: proxy)
}

// CC Switch 直连开关：开=清掉代理URL，关=写回代理URL
func toggleCcswitchDirect(enable: Bool, cur: CurrentProxy) -> ApplyResult {
    guard FileManager.default.fileExists(atPath: CCSWITCH_DB) else {
        return ApplyResult(ok: false, message: "CC Switch 数据库不存在")
    }
    if enable {
        if sqliteExec(CCSWITCH_DB, "DELETE FROM settings WHERE key='global_proxy_url'") {
            return ApplyResult(ok: true, message: "CC Switch 已切换到直连")
        }
        return ApplyResult(ok: false, message: "删除失败")
    } else {
        guard let port = cur.port else { return ApplyResult(ok: false, message: "没有代理端口") }
        let proxyUrl = "http://127.0.0.1:\(port)"
        let existing = sqliteScalar(CCSWITCH_DB, "SELECT value FROM settings WHERE key='global_proxy_url'")
        if existing != nil {
            _ = sqliteExecBind(CCSWITCH_DB, "UPDATE settings SET value=? WHERE key='global_proxy_url'", proxyUrl)
        } else {
            _ = sqliteExecBind(CCSWITCH_DB, "INSERT INTO settings (key, value) VALUES ('global_proxy_url', ?)", proxyUrl)
        }
        return ApplyResult(ok: true, message: "CC Switch 代理已恢复 → \(proxyUrl)")
    }
}

// MARK: - 统一应用：把当前代理应用到指定目标

// TUN/none/不可用端口→目标设直连，可用端口→目标填端口
func applyTarget(_ target: SyncTarget, cur: CurrentProxy) -> ApplyResult {
    let direct: Bool
    let proxyUrl: String?
    if shouldSyncPortProxy(cur) {
        proxyUrl = "http://127.0.0.1:\(cur.port!)"
        direct = false
    } else {
        proxyUrl = nil
        direct = true
    }
    switch target {
    case .terminal:
        return toggleZshrcProxy(enable: !direct, port: direct ? nil : cur.port)
    case .git:
        return applyGit(direct: direct, proxyUrl: proxyUrl)
    case .vscode:
        return direct ? toggleVscodeDirect(enable: true, cur: cur) : fixVscode(proxyUrl: proxyUrl!)
    case .ccswitch:
        return toggleCcswitchDirect(enable: direct, cur: cur)
    }
}
