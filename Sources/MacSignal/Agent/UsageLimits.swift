import Foundation

/// An agent's subscription quota, as the agent last reported it.
/// Codex logs it with each model response (`token_count` events in its session log); Claude Code
/// only passes it to a statusLine command. Both reach the app over the hook socket as "Q:" + JSON.
/// The app also reads Claude Code's itself (ClaudeUsage), since only the terminal runs statusLine.
struct AgentQuota: Codable, Equatable {
    struct Window: Codable, Equatable {
        /// Used share, 0–100.
        var used: Double
        /// Window length (300 = 5 hours, 10080 = a week); nil when the agent does not say.
        var minutes: Int?
        /// When the window resets, Unix seconds.
        var resets: Double

        /// 「5 hours」, 「This week」.
        var span: String {
            minutes == 300 ? L("5 hours", "5 小时") : minutes == 10080 ? L("This week", "本周")
                : minutes.map { L("\($0 / 60) hours", "\($0 / 60) 小时") } ?? L("Limit", "额度")
        }

        /// 「Nov 19, 15:24」, 「11月19日 15:24」.
        var resetTime: String {
            let format = DateFormatter()
            format.locale = Language.current.locale
            format.setLocalizedDateFormatFromTemplate("MMMdHHmm")
            return format.string(from: Date(timeIntervalSince1970: resets))
        }
    }

    var agent: String
    var windows: [Window]
    /// When the agent reported it, Unix seconds.
    var captured: Double

    /// The most used window that has not reset yet, 0–1; nil once every window has reset
    /// (what was used since is unknown until the next report).
    func used(at now: Date) -> Double? {
        live(at: now).map { $0.used / 100 }.max()
    }

    /// The windows that have not reset yet.
    func live(at now: Date) -> [Window] { windows.filter { $0.resets > now.timeIntervalSince1970 } }

    /// Codex `rate_limits`: {"primary": {"used_percent", "window_minutes", "resets_at"}, "secondary": …}.
    static func codex(_ limits: [String: Any], captured: Double) -> AgentQuota? {
        let windows = ["primary", "secondary"].compactMap { key -> Window? in
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percent"]) else { return nil }
            let resets = number(w["resets_at"]) ?? number(w["resets_in_seconds"]).map { captured + $0 }
            return resets.map { Window(used: used, minutes: number(w["window_minutes"]).map { Int($0) }, resets: $0) }
        }
        return windows.isEmpty ? nil : AgentQuota(agent: "codex", windows: windows, captured: captured)
    }

    /// Claude Code statusLine `rate_limits`: {"five_hour": {"used_percentage", "resets_at"}, "seven_day": …}.
    static func claude(_ limits: [String: Any], captured: Double) -> AgentQuota? {
        let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes -> Window? in
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percentage"]),
                  let resets = number(w["resets_at"]) else { return nil }
            return Window(used: used, minutes: minutes, resets: resets)
        }
        return windows.isEmpty ? nil : AgentQuota(agent: "claude", windows: windows, captured: captured)
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    static var allReset: String { L("Reset, waiting for new data", "已重置，等待新数据") }

    /// 「This week: 26% used, resets Nov 19, 15:24」 per window, or `allReset`.
    func describe(now: Date) -> String {
        let live = live(at: now)
        guard !live.isEmpty else { return Self.allReset }
        return live.map { window in
            let used = Int(window.used.rounded())
            return L("\(window.span): \(used)% used, resets \(window.resetTime)", "\(window.span)已用 \(used)%，\(window.resetTime) 重置")
        }.joined(separator: L("; ", "；"))
    }
}

/// The latest quota per agent, kept across launches.
final class UsageLimits {
    static let defaultsKey = "agentQuota"
    private(set) var byAgent: [String: AgentQuota]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        byAgent = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: AgentQuota].self, from: $0) } ?? [:]
    }

    /// Takes a "Q:" message; returns whether anything changed. Several sessions report: an older
    /// report never replaces a newer one.
    @discardableResult
    func apply(_ json: String) -> Bool {
        guard let quota = try? JSONDecoder().decode(AgentQuota.self, from: Data(json.utf8)) else { return false }
        return apply(quota)
    }

    /// Takes a quota read by the app itself (ClaudeUsage), by the same rule.
    @discardableResult
    func apply(_ quota: AgentQuota) -> Bool {
        guard agentNames.contains(where: { $0.id == quota.agent }),
              byAgent[quota.agent].map({ $0.captured <= quota.captured }) ?? true,
              byAgent[quota.agent] != quota else { return false }
        byAgent[quota.agent] = quota
        defaults.set(try? JSONEncoder().encode(byAgent), forKey: Self.defaultsKey)
        return true
    }
}

/// Sends `quota` to the running app; does nothing when the app is not running.
func sendQuota(_ quota: AgentQuota?) {
    guard let quota, let json = try? JSONEncoder().encode(quota) else { return }
    sendToApp("Q:" + String(decoding: json, as: UTF8.self))
}

/// `MacSignal statusline`: Claude Code's statusLine command. Passes the quota in its input on to
/// the app and prints nothing, so Claude Code shows no status line, as without one.
func runStatusLine() -> Never {
    let data = isatty(0) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
    if let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let limits = input["rate_limits"] as? [String: Any] {
        sendQuota(AgentQuota.claude(limits, captured: Date().timeIntervalSince1970))
    }
    exit(0)
}

/// The quota in the latest `token_count` event of a Codex session log. Every model response
/// logs one, so read back at most 4 MB from the end.
func codexQuota(transcript path: String) -> AgentQuota? {
    var found: AgentQuota?
    _ = lastLine(of: path, megabytes: 4) { line in
        guard line.contains("\"rate_limits\":{"),
              let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return false }
        let time = (event["timestamp"] as? String).flatMap(parseTimestamp)?.timeIntervalSince1970
        found = AgentQuota.codex(limits, captured: time ?? Date().timeIntervalSince1970)
        return found != nil
    }
    return found
}

func parseTimestamp(_ text: String) -> Date? {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

/// The last line of a file that `accept` takes, reading back from the end one chunk at a time
/// (a session log can hold megabytes of tool output after it). Gives up after `megabytes`.
func lastLine(of path: String, megabytes: Int = 32, where accept: (String) -> Bool) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    let chunk: UInt64 = 1 << 20
    var end = handle.seekToEndOfFile()
    // The start of a line whose beginning is in the chunk before.
    var rest = Data()
    for _ in 0..<megabytes where end > 0 {
        let start = end > chunk ? end - chunk : 0
        handle.seek(toFileOffset: start)
        var lines = (handle.readData(ofLength: Int(end - start)) + rest)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        rest = start > 0 ? Data(lines.removeFirst()) : Data()
        for line in lines.reversed() {
            let text = String(decoding: line, as: UTF8.self)
            if accept(text) { return text }
        }
        end = start
    }
    return nil
}
