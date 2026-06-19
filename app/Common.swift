import Foundation
import Darwin

// ── 共享基础设施：路径常量 / shell 调用 / 正则助手 ──
// 这些是各模块都要用的底层工具，集中放一处，避免重复。

let HOME = FileManager.default.homeDirectoryForCurrentUser.path

// 各配置文件路径（与原 server.py 保持一致）
let ZSHRC = "\(HOME)/.zshrc"
let CLAUDE_SETTINGS = "\(HOME)/.claude/settings.json"
let CCSWITCH_DB = "\(HOME)/.cc-switch/cc-switch.db"
let HERMES_CONFIG = "\(HOME)/.hermes/config.yaml"
let VSCODE_SETTINGS = "\(HOME)/Library/Application Support/Code/User/settings.json"
let FLCLASH_CONFIG = "\(HOME)/Library/Application Support/com.follow.clash/config.yaml"
let CLASH_VERGE_CONFIG = "\(HOME)/Library/Application Support/un.un.clashrev/clash-verge.yaml"

// 代理常用候选端口（与 server.py PROXY_PORTS 一致）
let PROXY_PORTS: [Int] = [
    7890, 7891, 7892, 7893, 7894,
    7895, 7896, 7897, 7898, 7899,
    1080, 1081, 1082,
    8080, 8118, 9090,
    10808, 10809,
    2080, 33210, 50001, 60001,
]

// ── 读文件为字符串（失败返回 nil，不抛异常）──
func readFileText(_ path: String) -> String? {
    return try? String(contentsOfFile: path, encoding: .utf8)
}

// ── 带超时的 shell 调用，返回 stdout ──
// 超时后杀进程，返回已读到的部分；本地命令(ps/ifconfig/git)一般远低于超时。
func shell(_ args: [String], timeout: TimeInterval = 3) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: args[0])
    task.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return ""
    }
    // 超时兜底：到点强制结束，防止卡死
    var timedOut = false
    let workItem = DispatchWorkItem {
        if task.isRunning {
            timedOut = true
            task.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
    task.waitUntilExit()
    workItem.cancel()
    if timedOut { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// ── 正则助手：取第一个匹配的第 1 个捕获组 ──
func matchFirst(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    if let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges > 1,
       let r = Range(m.range(at: 1), in: text) {
        return String(text[r])
    }
    return nil
}

// ── 正则助手：是否匹配 ──
func testMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
    let range = NSRange(text.startIndex..., in: text)
    return re.firstMatch(in: text, options: [], range: range) != nil
}

// ── 正则助手：取所有匹配的第 1 个捕获组 ──
func matchAll(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    let results = re.matches(in: text, options: [], range: range)
    return results.compactMap { m -> String? in
        guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
