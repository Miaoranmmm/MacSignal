import AppKit
import MacSignalCore

/// What the menu bar item can show. The user picks them in 设置 › 显示; they appear in this order,
/// the light always last. A module whose condition is not met (no battery, no agent hooked up) is
/// neither offered there nor drawn, but its checkbox is remembered.
enum StatusModule: String, CaseIterable {
    case network, cpu, memory, power, quota, light

    var title: String {
        switch self {
        case .network: return L("Network", "网速")
        case .cpu: return "CPU"
        case .memory: return L("Memory", "内存")
        case .power: return L("Power", "功耗")
        case .quota: return L("AI Usage", "AI 额度")
        case .light: return L("Traffic Light", "红绿灯")
        }
    }

    var defaultsKey: String { "show." + rawValue }

    /// The modules of the earlier menu bar item are on; the newer ones start off.
    var shownByDefault: Bool { self != .power && self != .quota }

    var isChecked: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? shownByDefault
    }

    func setChecked(_ checked: Bool) { UserDefaults.standard.set(checked, forKey: defaultsKey) }

    /// The condition for offering and drawing the module.
    func isAvailable(_ r: Readings) -> Bool {
        switch self {
        case .network, .cpu, .memory: return true
        case .power: return r.powerAvailable
        case .quota: return !r.quotaAgents.isEmpty
        case .light: return r.lamps != nil
        }
    }

    /// The cells this module draws.
    func cells(_ r: Readings, now: Date = Date()) -> [MenuBarRenderer.Cell] {
        switch self {
        case .network: return [.network(up: r.snapshot.upload, down: r.snapshot.download)]
        case .cpu: return [.percent("CPU", r.snapshot.cpu)]
        case .memory: return [.percent("MEM", r.snapshot.memory)]
        case .power:
            return [.reading(caption: "PWR", value: r.snapshot.power.map { Self.watts($0.watts) } ?? "—",
                             fraction: nil, scaled: false, widest: "999W")]
        case .quota:
            // A cell per hooked agent that has reported once; past a reset it shows "—" until new data.
            return r.quotaAgents.compactMap { agent in
                r.quota[agent].map { .percent(agent.uppercased(), $0.used(at: now)) }
            }
        case .light:
            return r.lamps.map { [.lamps(lit: $0, redDimmed: r.redDimmed)] } ?? []
        }
    }

    /// The modules in the menu bar, in order; the menu lists their details.
    static func shown(_ r: Readings) -> [StatusModule] { allCases.filter { $0.isChecked && $0.isAvailable(r) } }

    /// Everything to draw, in order; empty draws the app's icon.
    static func cells(_ r: Readings, now: Date = Date()) -> [MenuBarRenderer.Cell] {
        shown(r).flatMap { $0.cells(r, now: now) }
    }

    /// "11W", "6.8W" under 10 W.
    static func watts(_ value: Double) -> String {
        String(format: value < 9.95 ? "%.1fW" : "%.0fW", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// What the modules read: the sampler's snapshot, agent state and quota.
struct Readings: Equatable {
    var snapshot = MetricsSnapshot.empty
    /// The Mac reports its power draw (a laptop that has the telemetry).
    var powerAvailable = PowerSampler.isAvailable
    /// Hooked agents that report quota, in drawing order ("codex", "claude").
    var quotaAgents: [String] = []
    var quota: [String: AgentQuota] = [:]
    /// Each lamp lit [waiting, working, unread done]; nil without an agent hooked up.
    var lamps: [Bool]?
    /// The red lamp is in the dark half of a blink.
    var redDimmed = false
}

extension MenuBarRenderer.Cell {
    /// A 0–100 reading: a percentage with 显示数字, a bar without.
    static func percent(_ caption: String, _ value: Double?) -> Self {
        .reading(caption: caption, value: MenuBarRenderer.percent(value), fraction: value, scaled: true, widest: "100%")
    }
}

extension Readings {
    /// The readings in full, for the menu bar item's tooltip.
    func tooltipLines(now: Date = Date()) -> [String] {
        let sampling = ProcessMenuContent.sampling
        func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? sampling }
        func rate(_ value: Double?) -> String { value.map { RateFormatter.string(bytesPerSecond: $0) } ?? sampling }
        var lines = [L("Upload: ", "上传：") + rate(snapshot.upload), L("Download: ", "下载：") + rate(snapshot.download),
                     L("CPU: ", "CPU：") + percent(snapshot.cpu), L("Memory: ", "内存：") + percent(snapshot.memory),
                     L("Interfaces: ", "网络接口：") + snapshot.interfaces.joined(separator: ", ")]
        if powerAvailable {
            lines.append(L("Power: ", "功耗：") + (snapshot.power.map(Self.describe) ?? sampling))
        }
        for agent in quotaAgents {
            guard let quota = quota[agent] else { continue }
            let name = agentNames.first { $0.id == agent }?.name ?? agent
            let age = Int(now.timeIntervalSince1970 - quota.captured) / 60
            let updated = age < 1 ? L("updated just now", "刚刚更新")
                : age < 60 ? L("updated \(age) min ago", "\(age) 分钟前更新") : L("updated \(age / 60) hr ago", "\(age / 60) 小时前更新")
            lines.append(L("\(name) usage: \(quota.describe(now: now)) (\(updated))", "\(name) 额度：\(quota.describe(now: now))（\(updated)）"))
        }
        return lines
    }

    /// 「Total 11.4 W · Battery 86%, charging, 40 min until full」
    static func describe(_ p: PowerReading) -> String {
        var text = L("Total ", "整机 ") + p.wattsText
        guard let battery = p.batteryText else { return text }
        text += L(" · Battery ", " · 电量 ") + battery
        if let span = p.timeLeft {
            text += p.charging ? L(", \(span) until full", "，还需 \(span)充满") : L(", \(span) remaining", "，还可使用 \(span)")
        }
        return text
    }
}

extension PowerReading {
    /// 「11.4 W」.
    var wattsText: String { String(format: "%.1f W", locale: Locale(identifier: "en_US_POSIX"), watts) }

    /// 「86%, on battery」; nil without a battery.
    var batteryText: String? {
        level.map {
            "\(Int(($0 * 100).rounded()))%" + (charging ? L(", charging", "，正在充电")
                : pluggedIn ? L(", plugged in, not charging", "，已接电源，未充电") : L(", on battery", "，使用电池"))
        }
    }

    /// Until full while charging, until empty on battery: 「5 hr」, 「1 hr 20 min」.
    var timeLeft: String? { minutesLeft.map(durationText) }
}
