import AppKit

/// The 「Agent 会话」 section at the top of the menu, shown while an agent is hooked up.
/// One standard menu item per session: the status dot in the checkmark column, the agent's icon,
/// 「项目 · 任务」 and 「状态 · 时间」 right-aligned in gray. While the menu is open it refreshes
/// every second; when the same sessions are shown only the text changes, so the highlight stays.
final class AgentMenuContent: NSObject {
    /// At most this many rows; sessions that need attention (waiting, working, unread) always get
    /// one and count toward it. Read sessions quiet for longer go under 「更早的 N 个会话」.
    static let maxRows = 5
    static let quietAfter: TimeInterval = 30 * 60
    static var empty: String { L("No active agent sessions", "没有进行中的 agent 会话") }
    static var markAll: String { L("Mark All as Read", "全部标为已读") }

    private let receiver: AgentReceiver
    private weak var menu: NSMenu?
    private var shown: [NSMenuItem] = []

    init(receiver: AgentReceiver) {
        self.receiver = receiver
    }

    /// Adds the section to `menu`, at the end or at `index`.
    func add(to menu: NSMenu, at index: Int? = nil) {
        self.menu = menu
        shown = items(now: Date())
        for (offset, item) in shown.enumerated() { menu.insertItem(item, at: index.map { $0 + offset } ?? menu.numberOfItems) }
    }

    var isShown: Bool { !shown.isEmpty }

    /// Takes the section out of the menu it was added to (the light is not shown any more).
    func remove() {
        shown.forEach { $0.menu?.removeItem($0) }
        shown = []
        menu = nil
    }

    /// Brings the section up to date while the menu is open.
    func refresh() {
        guard let menu, let first = shown.first, let start = menu.items.firstIndex(of: first) else { return }
        let fresh = items(now: Date())
        if Self.sameRows(fresh, shown) {
            for (new, old) in zip(fresh, shown) { Self.retitle(old, from: new) }
            return
        }
        shown.forEach(menu.removeItem)
        for (offset, item) in fresh.enumerated() { menu.insertItem(item, at: start + offset) }
        shown = fresh
    }

    func items(now: Date) -> [NSMenuItem] {
        var items = [ProcessMenuContent.heading(StatusModule.light.menuTitle)]
        let entries = receiver.sessions.sorted
        var rows: [NSMenuItem] = []
        var older: [NSMenuItem] = []
        for (id, entry) in entries {
            let quiet = !entry.counts && now.timeIntervalSince(entry.updated) > Self.quietAfter
            if entry.counts || (rows.count < Self.maxRows && !quiet) {
                rows.append(row(id, entry, now: now))
            } else {
                older.append(row(id, entry, now: now))
            }
        }
        Self.alignColumns(rows)
        Self.alignColumns(older)
        if entries.isEmpty {
            let none = NSMenuItem(title: Self.empty, action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        items += rows
        if !older.isEmpty {
            let more = NSMenuItem(title: L(older.count == 1 ? "1 Earlier Session" : "\(older.count) Earlier Sessions",
                                           "更早的 \(older.count) 个会话"), action: nil, keyEquivalent: "")
            let submenu = MenuStyle.menu()
            older.forEach(submenu.addItem)
            more.submenu = submenu
            // Which sessions are inside: a different set rebuilds the section instead of retitling it.
            more.representedObject = older.compactMap { $0.representedObject as? String }.joined(separator: ",")
            items.append(more)
        }
        if entries.contains(where: { $0.entry.state != .working && !$0.entry.seen }) {
            let readAll = NSMenuItem(title: Self.markAll, action: #selector(markAllSeen), keyEquivalent: "")
            readAll.target = self
            // Keeps the menu open: the rows turn read in place.
            items.append(MenuActionRow.keepOpen(readAll) { [weak self] in self?.refresh() })
        }
        items.append(.separator())
        return items
    }

    private func row(_ id: String, _ entry: AgentSessions.Entry, now: Date) -> NSMenuItem {
        let agent = agentNames.first { $0.id == entry.agent }?.name ?? entry.agent
        let project = entry.project.isEmpty ? agent : entry.project
        // The task tells apart sessions of the same project; the full prompt line is in the tooltip.
        let task = entry.title.count > 24 ? entry.title.prefix(23) + "…" : entry.title
        let item = NSMenuItem(title: "", action: #selector(openSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.state = .on
        item.onStateImage = Self.dot(entry.counts ? entry.state : nil)
        item.image = AgentIcons.image(for: entry.agent)
        // NSMenuItemImageVisibilityVisible = 1. Look up the setter at runtime for older SDKs.
        if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
        item.toolTip = entry.title.isEmpty ? agent : "\(agent)\n\(entry.title)"
        item.attributedTitle = Self.title(
            left: [project, String(task)].filter { !$0.isEmpty }.joined(separator: " · "),
            right: "\(entry.state.label) · \(Self.elapsed(entry, now: now))", tab: 0)
        return item
    }

    // MARK: Row text

    private static let font = MenuStyle.rowFont

    private static func title(left: String, right: String, tab: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        let text = NSMutableAttributedString(string: left, attributes: [.font: font, .paragraphStyle: paragraph])
        text.append(NSAttributedString(string: "\t" + right, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return text
    }

    /// Right-aligns every row's 「状态 · 时间」 at the same tab stop, past the widest name.
    private static func alignColumns(_ rows: [NSMenuItem]) {
        let parts = rows.map { item -> (String, String) in
            let pieces = (item.attributedTitle?.string ?? "").components(separatedBy: "\t")
            return (pieces[0], pieces.count > 1 ? pieces[1] : "")
        }
        let width = { (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }
        let tab = ceil((parts.map { width($0.0) }.max() ?? 0) + 24 + (parts.map { width($0.1) }.max() ?? 0))
        for (item, (left, right)) in zip(rows, parts) {
            item.attributedTitle = title(left: left, right: right, tab: tab)
        }
    }

    /// Working: how long the current turn has taken ("for 3 min"); waiting / done: when it happened ("3 min ago").
    static func elapsed(_ e: AgentSessions.Entry, now: Date = Date()) -> String {
        let t = max(0, Int(now.timeIntervalSince(e.state == .working ? e.turnStart : e.since)))
        let span = t < 60 ? L("\(t) sec", "\(t) 秒") : durationText(minutes: t / 60)
        if e.state == .working { return L("for \(span)", "已进行 \(span)") }
        return t < 5 ? L("just now", "刚刚") : L("\(span) ago", "\(span)前")
    }

    /// The status dot: filled in the lamp's color, hollow once read.
    private static let dots: [AgentSessions.State?: NSImage] = {
        var images: [AgentSessions.State?: NSImage] = [:]
        let colors: [AgentSessions.State: NSColor] = [.waiting: .systemRed, .working: .systemYellow, .done: .systemGreen]
        for state in [AgentSessions.State.waiting, .working, .done, nil] {
            images[state] = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                if let state {
                    colors[state]!.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                } else {
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                    ring.lineWidth = 1
                    NSColor.secondaryLabelColor.setStroke()
                    ring.stroke()
                }
                return true
            }
        }
        return images
    }()

    private static func dot(_ state: AgentSessions.State?) -> NSImage { dots[state]! }

    // MARK: In-place refresh

    private static func sameRows(_ a: [NSMenuItem], _ b: [NSMenuItem]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.isSeparatorItem == y.isSeparatorItem && x.action == y.action
                && x.representedObject as? String == y.representedObject as? String
                && (x.submenu == nil) == (y.submenu == nil)
                // Fixed items (heading, 「没有…」) by title; session rows by id.
                && (x.action != nil || x.submenu != nil || x.title == y.title)
        }
    }

    private static func retitle(_ old: NSMenuItem, from new: NSMenuItem) {
        if let text = new.attributedTitle, old.attributedTitle != text { old.attributedTitle = text }
        if old.onStateImage !== new.onStateImage { old.onStateImage = new.onStateImage }
        if old.toolTip != new.toolTip { old.toolTip = new.toolTip }
        if let fresh = new.submenu, let shown = old.submenu {
            for (n, o) in zip(fresh.items, shown.items) { retitle(o, from: n) }
        }
    }

    // MARK: Actions

    /// Opens the session, falling back to the app that reported it.
    @objc func openSession(_ sender: NSMenuItem) {
        let workspace = NSWorkspace.shared
        openSession(sender, applicationForURL: workspace.urlForApplication(toOpen:),
                    applicationForBundle: workspace.urlForApplication(withBundleIdentifier:)) { url, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            let finished: (NSRunningApplication?, Error?) -> Void = { app, error in
                let opened = app != nil && error == nil
                DispatchQueue.main.async { completion(opened) }
            }
            if url.isFileURL {
                workspace.openApplication(at: url, configuration: configuration, completionHandler: finished)
            } else {
                workspace.open(url, configuration: configuration, completionHandler: finished)
            }
        }
    }

    func openSession(_ sender: NSMenuItem, applicationForURL: (URL) -> URL?,
                     applicationForBundle: (String) -> URL?,
                     open: (URL, @escaping (Bool) -> Void) -> Void) {
        guard let id = sender.representedObject as? String, let e = receiver.sessions.entries[id] else { return }
        let markOpened: (Bool) -> Void = { [weak receiver] opened in
            guard opened, let receiver, let current = receiver.sessions.entries[id],
                  current.since == e.since, current.agent == e.agent else { return }
            receiver.sessions.markSeen(id)
            receiver.applySessions()
        }
        var url: URL?
        if e.host.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil {
            url = URL(string: "claude://code/continue?session=\(e.host)")
        } else if e.agent == "codex", id.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil {
            url = URL(string: "codex://threads/\(id)")
        }
        if let url, applicationForURL(url) != nil {
            open(url, markOpened)
        } else if !e.app.isEmpty, let appURL = applicationForBundle(e.app) {
            open(appURL, markOpened)
        }
    }

    @objc func markAllSeen() {
        receiver.sessions.entries.keys.forEach(receiver.sessions.markSeen)
        receiver.applySessions()
    }
}
