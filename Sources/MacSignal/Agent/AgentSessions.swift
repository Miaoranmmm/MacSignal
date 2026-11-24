// Agent sessions reported by the hooks.
import Foundation

/// Claude Code / Codex / iCode sessions reported by `MacSignal hook` as "J:{json}".
final class AgentSessions {
    enum State: String {
        case waiting, working, done

        var label: String {
            [.waiting: L("Waiting for you", "等待你确认"), .working: L("Working", "工作中"), .done: L("Done", "已完成")][self]!
        }
    }

    struct Entry {
        var state: State
        var project: String
        /// Last report (keeps the session from going stale).
        var updated: Date
        /// When the current state began (when it finished / started waiting).
        var since = Date()
        /// When the current turn began; a stop to wait for you doesn't restart it.
        var turnStart = Date()
        /// Desktop app session id (local_...), empty for terminal sessions.
        var host = ""
        /// Bundle id of the app running the session (Claude, Terminal, iTerm, VS Code...).
        var app = ""
        /// "claude", "codex" or "icode".
        var agent = "claude"
        /// First line of the prompt that started the current turn.
        var title = ""
        /// The agent process and its start time (µs), 0 when unknown; the session goes once it exits.
        var pid: pid_t = 0
        var start = 0
        /// Like an unread badge: a waiting/finished session counts until clicked in the menu.
        var seen = false

        /// Whether it still lights the lamp and shows in the menu bar count (working always does).
        var counts: Bool { state == .working || !seen }
    }

    var entries: [String: Entry] = [:]
    // Sessions that stop reporting (crashed, window closed without SessionEnd) eventually drop out.
    let staleAfter: [State: TimeInterval] = [.waiting: 3600, .working: 3600, .done: 12 * 3600]

    /// Applies one hook report; returns the session's id when it just finished.
    @discardableResult
    func apply(_ msg: String) -> String? {
        guard msg.hasPrefix("J:"),
              let r = try? JSONSerialization.jsonObject(with: Data(msg.dropFirst(2).utf8)) as? [String: Any] else { return nil }
        let field = { (key: String) in r[key] as? String ?? "" }
        let id = field("session")
        guard !id.isEmpty else { return nil }
        // State changes only (PostToolUse repeats "working" all the time), to see what each agent reports.
        if entries[id]?.state.rawValue != field("state") {
            agentLog("session \(field("agent")) \(id.prefix(8)) \(field("project")): \(entries[id]?.state.rawValue ?? "new") -> \(field("state"))")
        }
        if field("state") == "end" {
            entries[id] = nil
        } else if let state = State(rawValue: field("state")) {
            let finished = state == .done && entries[id]?.state != .done
            let old = entries[id]
            let keep = { (key: String, oldValue: String?) in field(key).isEmpty ? oldValue ?? "" : field(key) }
            let pid = (r["pid"] as? NSNumber)?.int32Value ?? 0
            entries[id] = Entry(state: state,
                                project: keep("project", old?.project),
                                updated: Date(),
                                since: old?.state == state ? old!.since : Date(),
                                turnStart: old == nil || (old!.state == .done && state != .done) ? Date() : old!.turnStart,
                                host: keep("host", old?.host),
                                app: keep("app", old?.app),
                                agent: field("agent").isEmpty ? old?.agent ?? "claude" : field("agent"),
                                title: keep("title", old?.title),
                                pid: pid != 0 ? pid : old?.pid ?? 0,
                                start: pid != 0 ? (r["start"] as? NSNumber)?.intValue ?? 0 : old?.start ?? 0,
                                // Repeated reports of the same state (e.g. a second permission prompt) keep it read.
                                seen: old?.state == state ? old!.seen : false)
            return finished ? id : nil
        }
        return nil
    }

    /// Drops sessions that went quiet for too long, and those whose agent process exited
    /// (unread finished ones stay until read, so a result isn't lost when its window closes).
    func prune() {
        let now = Date()
        entries = entries.filter { _, e in
            guard now.timeIntervalSince(e.updated) < staleAfter[e.state]! else { return false }
            guard e.pid != 0, e.state != .done || e.seen else { return true }
            if processInfo(e.pid)?.start == e.start { return true }
            agentLog("dropping \(e.agent) session \(e.project): agent pid \(e.pid) exited")
            return false
        }
    }

    /// Menu bar count per state across all agents (unread only, except working).
    func count(_ state: State) -> Int {
        entries.values.filter { $0.state == state && $0.counts }.count
    }

    /// Menu bar summary across all agents: [waiting, working, unread done].
    var counts: [Int] { [State.waiting, .working, .done].map(count) }

    /// Waiting sessions that still count; a new one makes the menu bar's red lamp blink.
    var waitingIDs: Set<String> {
        Set(entries.filter { $0.value.state == .waiting && $0.value.counts }.keys)
    }

    func markSeen(_ id: String) {
        entries[id]?.seen = true
    }

    /// (session id, entry): unread waiting, working, unread done, then read ones; newest first within each.
    var sorted: [(id: String, entry: Entry)] {
        let rank = { (e: Entry) in e.counts ? [State.waiting: 0, .working: 1, .done: 2][e.state]! : 3 }
        return entries.map { (id: $0.key, entry: $0.value) }
            .sorted { (rank($0.entry), $1.entry.updated) < (rank($1.entry), $0.entry.updated) }
    }
}
