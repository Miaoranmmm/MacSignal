import AppKit
import MacSignalCore

/// The menu's details of what the menu bar shows: a section per module, in the menu bar's order
/// (the light's is 「Agent 会话」, at the top of the menu, see AgentMenuContent). CPU and memory
/// list the top processes; network, power and AI quota their readings in full. While the menu is
/// open, the rows follow the readings and the sections follow 设置 › 显示.
final class DetailMenuContent {
    let processes: ProcessMenuContent
    /// The modules shown, without the light.
    private(set) var modules: [StatusModule] = []
    private weak var menu: NSMenu?
    /// Headings, separators and process rows; the reading rows are in `sections`.
    private var items: [NSMenuItem] = []
    /// Network, power and quota: the heading and the rows under it.
    private var sections: [StatusModule: (heading: NSMenuItem, rows: [NSMenuItem])] = [:]

    init(processes: ProcessMenuContent) {
        self.processes = processes
    }

    /// Where the sections start in the menu; nil when there are none.
    var startIndex: Int? { items.first.flatMap { menu?.items.firstIndex(of: $0) } }

    /// Inserts the sections of `shown` (the menu bar's modules) into `menu` at `index`.
    func add(_ shown: [StatusModule], readings r: Readings, to menu: NSMenu, at index: Int, now: Date = Date()) {
        remove()
        self.menu = menu
        modules = shown.filter { $0 != .light }
        let cpu = modules.contains(.cpu), memory = modules.contains(.memory)
        // Both process sections come at once: they are next to each other in the order.
        var processItems = processes.sections(cpu: cpu, memory: memory)
        var built: [NSMenuItem] = []
        for module in modules {
            switch module {
            case .cpu, .memory:
                built += processItems
                items += processItems
                processItems = []
            default:
                let heading = ProcessMenuContent.heading(module.menuTitle), separator = NSMenuItem.separator()
                let rows = Self.lines(module, r, now: now).map(Self.rowItem)
                sections[module] = (heading, rows)
                built += [heading] + rows + [separator]
                items += [heading, separator]
            }
        }
        for (offset, item) in built.enumerated() { menu.insertItem(item, at: index + offset) }
    }

    func remove() {
        (items + sections.values.flatMap(\.rows)).forEach { $0.menu?.removeItem($0) }
        items = []
        sections = [:]
        modules = []
    }

    /// Brings the reading rows up to date; a section whose number of rows changed (a quota
    /// arrived, a window reset) gets new rows under its heading.
    func update(_ r: Readings, now: Date = Date()) {
        for (module, section) in sections {
            let lines = Self.lines(module, r, now: now)
            if lines.count == section.rows.count {
                for (item, line) in zip(section.rows, lines) { (item.view as? ProcessMenuRow).map { Self.fill($0, line) } }
                continue
            }
            guard let menu, let heading = menu.items.firstIndex(of: section.heading) else { continue }
            section.rows.forEach(menu.removeItem)
            let rows = lines.map(Self.rowItem)
            for (offset, item) in rows.enumerated() { menu.insertItem(item, at: heading + 1 + offset) }
            sections[module] = (section.heading, rows)
        }
    }

    /// The rows of a module that lists readings, as (name, value).
    static func lines(_ module: StatusModule, _ r: Readings, now: Date) -> [(String, String)] {
        switch module {
        case .network:
            func rate(_ value: Double?) -> String {
                value.map { RateFormatter.string(bytesPerSecond: $0) } ?? ProcessMenuContent.sampling
            }
            return [(L("Upload", "上传"), rate(r.snapshot.upload)), (L("Download", "下载"), rate(r.snapshot.download))]
        case .power:
            guard let p = r.snapshot.power else { return [(ProcessMenuContent.sampling, "")] }
            var lines = [(L("Total", "整机"), p.wattsText)]
            if let battery = p.batteryText { lines.append((L("Battery", "电量"), battery)) }
            if let span = p.timeLeft { lines.append((p.charging ? L("Until Full", "充满还需") : L("Remaining", "还可使用"), span)) }
            return lines
        case .quota:
            return r.quotaAgents.flatMap { agent -> [(String, String)] in
                let name = agentNames.first { $0.id == agent }?.name ?? agent
                guard let quota = r.quota[agent] else { return [(name, L("Shown after use", "使用后显示"))] }
                let live = quota.live(at: now)
                guard !live.isEmpty else { return [(name, AgentQuota.allReset)] }
                return live.map { window in
                    let used = Int(window.used.rounded())
                    return ("\(name) · \(window.span)",
                            L("\(used)% · resets \(window.resetTime)", "\(used)% · \(window.resetTime) 重置"))
                }
            }
        case .cpu, .memory, .light:
            return []
        }
    }

    private static func rowItem(_ line: (String, String)) -> NSMenuItem {
        let row = ProcessMenuRow()
        fill(row, line)
        return ProcessMenuContent.item(row)
    }

    private static func fill(_ row: ProcessMenuRow, _ line: (String, String)) {
        row.update(name: line.0, value: line.1)
        // Wide enough for its text: the menu widens to the widest row.
        if row.frame.width < row.fittingWidth { row.setFrameSize(NSSize(width: row.fittingWidth, height: row.frame.height)) }
    }
}

extension StatusModule {
    /// The menu section's heading.
    var menuTitle: String {
        switch self {
        case .cpu: return L("Top CPU", "CPU 占用")
        case .memory: return L("Top Memory", "内存占用")
        case .light: return L("Agent Sessions", "Agent 会话")
        default: return title
        }
    }
}
