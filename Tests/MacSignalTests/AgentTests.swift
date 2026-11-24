import AppKit
import XCTest
@testable import MacSignal
@testable import MacSignalCore

/// Written from the plan (.plan/agent-light.md §3), not from the implementation.
final class AgentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The texts below are the Chinese ones; LanguageTests covers English.
        Language.current = .chinese
    }

    private func report(_ sessions: AgentSessions, _ id: String, _ state: String, agent: String = "claude") {
        // Session changes are logged; keep them out of the real log.
        agentLogPath = NSTemporaryDirectory() + "macsignal-tests.log"
        sessions.apply("J:{\"state\":\"\(state)\",\"session\":\"\(id)\",\"agent\":\"\(agent)\",\"project\":\"p-\(id)\"}")
    }

    private func temporaryHome() throws -> String {
        let dir = NSTemporaryDirectory() + "macsignal-agent-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Integration.home = dir
        return dir
    }

    // MARK: Sessions → menu bar summary

    func testSummaryCountsAllAgents() {
        let sessions = AgentSessions()
        XCTAssertEqual(sessions.counts, [0, 0, 0])
        report(sessions, "a", "working", agent: "codex")
        report(sessions, "b", "done", agent: "icode")
        XCTAssertEqual(sessions.counts, [0, 1, 1])
        report(sessions, "c", "waiting")
        XCTAssertEqual(sessions.counts, [1, 1, 1])
        // Read waiting / done sessions stop counting; working ones always count.
        ["a", "b", "c"].forEach(sessions.markSeen)
        XCTAssertEqual(sessions.counts, [0, 1, 0])
        report(sessions, "c", "end")
        XCTAssertEqual(sessions.counts, [0, 1, 0])
    }

    func testWaitingIDsOnlyHoldUnreadWaitingSessions() {
        let sessions = AgentSessions()
        report(sessions, "a", "waiting")
        report(sessions, "b", "working")
        XCTAssertEqual(sessions.waitingIDs, ["a"])
        sessions.markSeen("a")
        XCTAssertEqual(sessions.waitingIDs, [])
        // Waiting again after a turn is a new wait.
        report(sessions, "a", "working")
        report(sessions, "a", "waiting")
        XCTAssertEqual(sessions.waitingIDs, ["a"])
    }

    // MARK: Hooks

    func testHookCommandsOfMovedAppsAreOurs() {
        for command in [
            "[ -x \"/Users/me/Downloads/MacSignal/build/MacSignal.app/Contents/MacOS/MacSignal\" ] || exit 0; \"/Users/me/Downloads/MacSignal/build/MacSignal.app/Contents/MacOS/MacSignal\" hook working codex",
            "\"/Applications/MacSignal.app/Contents/MacOS/MacSignal\" hook done",
        ] {
            XCTAssertTrue(Integration.isOurs(command), command)
        }
        for command in ["~/bin/notify.sh hook done", "echo MacSignal hook", "afplay done.aiff"] {
            XCTAssertFalse(Integration.isOurs(command), command)
        }
    }

    func testMovedAppHooksAreRewrittenOnceAndOtherHooksKept() throws {
        let home = try temporaryHome()
        let claude = Integration.all.first { $0.id == "claude" }!
        let old = "/Users/me/Downloads/MacSignal/build/MacSignal.app/Contents/MacOS/MacSignal"
        var hooks: [String: Any] = [:]
        for (event, state, matcher) in claude.events {
            var group: [String: Any] = ["hooks": [["type": "command",
                                                   "command": "[ -x \"\(old)\" ] || exit 0; \"\(old)\" hook \(state)"]]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = [group]
        }
        hooks["Stop"] = (hooks["Stop"] as! [[String: Any]]) + [["hooks": [["type": "command", "command": "afplay done.aiff"]]]]
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hooks": hooks, "model": "x"])
            .write(to: URL(fileURLWithPath: claude.hooksFile))

        XCTAssertTrue(claude.installed)
        XCTAssertFalse(claude.current)
        try claude.install()
        XCTAssertTrue(claude.current)
        XCTAssertEqual(claude.ourCommands.count, claude.events.count)
        XCTAssertFalse(claude.text.contains("Downloads/MacSignal"))
        XCTAssertTrue(claude.text.contains("afplay done.aiff"))
        XCTAssertTrue(claude.text.contains("\"model\""))
        // Installing again (re-checking the agent) does not add a second set.
        try claude.install()
        XCTAssertEqual(claude.ourCommands.count, claude.events.count)
        try claude.uninstall()
        XCTAssertFalse(claude.installed)
        XCTAssertTrue(claude.text.contains("afplay done.aiff"))
    }

    func testICodeBlockKeepsTheMarkerLinesVerbatim() throws {
        let home = try temporaryHome()
        let icode = Integration.all.first { $0.id == "icode" }!
        try FileManager.default.createDirectory(atPath: home + "/.chrys/hooks", withIntermediateDirectories: true)
        try "hooks: []\n".write(toFile: icode.hooksFile, atomically: true, encoding: .utf8)
        try icode.install()
        let lines = icode.text.components(separatedBy: "\n")
        // Scripts that rewrite hooks.yaml keep the hooks between exactly these two lines.
        XCTAssertTrue(lines.contains("# >>> MacSignal hooks (managed by MacSignal)"))
        XCTAssertTrue(lines.contains("# <<< MacSignal hooks"))
        XCTAssertTrue(icode.installed)
        XCTAssertTrue(icode.current)
        XCTAssertEqual(icode.ourCommands.count, icode.events.count)
        try icode.uninstall()
        XCTAssertFalse(icode.installed)
        XCTAssertEqual(icode.text, "hooks: []\n")
    }

    // MARK: Menu

    func testSessionSectionRowsAndOlderSubmenu() {
        let receiver = AgentReceiver()
        let content = AgentMenuContent(receiver: receiver)
        var titles = content.items(now: Date()).map(\.title)
        XCTAssertEqual(titles, ["Agent 会话", AgentMenuContent.empty, ""])

        // Two need attention, six read: at most five rows in all, the rest under 更早的.
        report(receiver.sessions, "w", "waiting")
        report(receiver.sessions, "k", "working")
        for i in 0..<6 {
            report(receiver.sessions, "r\(i)", "done")
            receiver.sessions.markSeen("r\(i)")
        }
        var items = content.items(now: Date())
        let rows = items.filter { $0.action == #selector(AgentMenuContent.openSession(_:)) }
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.prefix(2).compactMap { $0.representedObject as? String }, ["w", "k"])
        XCTAssertEqual(items.first { $0.submenu != nil }?.title, "更早的 3 个会话")
        XCTAssertEqual(items.first { $0.submenu != nil }?.submenu?.items.count, 3)
        XCTAssertTrue(items.contains { $0.title == AgentMenuContent.markAll })
        // Every row: status dot in the checkmark column, 「项目 · 任务」 then 「状态 · 时间」.
        XCTAssertTrue(rows.allSatisfy { $0.state == .on && $0.onStateImage != nil })
        XCTAssertTrue(rows[0].attributedTitle!.string.hasPrefix("p-w\t等待你确认 · "))

        // Sessions that need attention are never hidden, however many.
        for i in 0..<7 { report(receiver.sessions, "x\(i)", "working") }
        items = content.items(now: Date())
        XCTAssertEqual(items.filter { $0.action == #selector(AgentMenuContent.openSession(_:)) }.count, 9)
        XCTAssertEqual(items.first { $0.submenu != nil }?.title, "更早的 6 个会话")

        // Nothing unread: no 全部标为已读.
        receiver.sessions.entries.keys.forEach(receiver.sessions.markSeen)
        titles = content.items(now: Date()).map(\.title)
        XCTAssertFalse(titles.contains(AgentMenuContent.markAll))
    }

    func testEverySessionRowShowsItsAgentsIcon() {
        let receiver = AgentReceiver()
        report(receiver.sessions, "c", "working", agent: "claude")
        report(receiver.sessions, "x", "waiting", agent: "codex")
        report(receiver.sessions, "i", "done", agent: "icode")
        report(receiver.sessions, "i2", "working", agent: "icode")
        let rows = AgentMenuContent(receiver: receiver).items(now: Date())
            .filter { $0.action == #selector(AgentMenuContent.openSession(_:)) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.representedObject as! String, $0) })
        XCTAssertEqual(byID.count, 4)
        for row in rows {
            XCTAssertEqual(row.image?.size, NSSize(width: 16, height: 16))
            if #available(macOS 27, *) { XCTAssertEqual(row.preferredImageVisibility, .visible) }
        }
        // One icon per agent: sessions of the same agent look the same, different agents differ.
        XCTAssertTrue(byID["i"]!.image === byID["i2"]!.image)
        XCTAssertFalse(byID["i"]!.image === byID["c"]!.image)
        XCTAssertFalse(byID["c"]!.image === byID["x"]!.image)
        XCTAssertEqual(byID["x"]!.image?.accessibilityDescription, "Codex")
    }

    func testICodeIconIsTheWhiteMarkOnPurple() throws {
        let image = AgentIcons.image(for: "icode")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let colors = (0..<64).flatMap { y in (0..<64).map { rep.colorAt(x: $0, y: y)! } }
        // Rounded corners stay clear; the body is iCode's purple (#AF87FF) with a white mark on it.
        XCTAssertEqual(rep.colorAt(x: 1, y: 1)!.alphaComponent, 0)
        XCTAssertTrue(colors.contains { $0.alphaComponent == 1 && $0.redComponent > 0.6 && $0.greenComponent < 0.6 && $0.blueComponent > 0.95 })
        XCTAssertTrue(colors.contains { $0.redComponent > 0.98 && $0.greenComponent > 0.98 && $0.blueComponent > 0.98 })
    }

    func testAgentWithoutAnIconKeepsTheRowsAligned() {
        let blank = AgentIcons.image(for: "other")
        XCTAssertEqual(blank.size, NSSize(width: 16, height: 16))
        XCTAssertTrue(blank.representations.isEmpty)
    }

    func testReadSessionsGoQuietAfterThirtyMinutes() {
        let receiver = AgentReceiver()
        report(receiver.sessions, "r", "done")
        receiver.sessions.markSeen("r")
        let content = AgentMenuContent(receiver: receiver)
        let later = Date().addingTimeInterval(AgentMenuContent.quietAfter + 1)
        XCTAssertEqual(content.items(now: later).first { $0.submenu != nil }?.title, "更早的 1 个会话")
    }

    func testSettingsShowLogOnlyWithAnAgentHookedUp() {
        let delegate = AppDelegate()
        func headings(_ menu: NSMenu) -> [String] {
            menu.items.filter { ($0.view?.frame.height ?? 0) > 0 && !($0.view is MenuActionRow) }.map(\.title)
        }
        delegate.hookedAgents = []
        var menu = delegate.settingsMenu()
        XCTAssertEqual(headings(menu), ["Agent", "鼠标", "显示"])
        XCTAssertTrue(menu.items.contains { $0.title == "显示数字" })
        XCTAssertFalse(menu.items.contains { $0.title == "打开日志" })
        XCTAssertFalse(menu.items.contains { $0.title.contains("紧凑") })
        delegate.hookedAgents = ["claude"]
        menu = delegate.settingsMenu()
        XCTAssertEqual(headings(menu), ["Agent", "鼠标", "显示"])
        XCTAssertTrue(menu.items.contains { $0.title == "显示数字" })
        XCTAssertTrue(menu.items.contains { $0.title == "打开日志" })
    }

    /// A report on the socket reaches the sessions; one it does not know is ignored.
    func testReceiverAppliesSessionReportsAndQuotas() {
        let receiver = AgentReceiver()
        var changes = 0, quotas: [String] = []
        receiver.onSessionsChange = { changes += 1 }
        receiver.onQuota = { quotas.append($0) }
        receiver.handle(#"J:{"state":"working","session":"s1","agent":"claude","project":"p"}"#)
        XCTAssertEqual(receiver.sessions.counts, [0, 1, 0])
        XCTAssertEqual(changes, 1)
        receiver.handle(#"Q:{"agent":"codex"}"#)
        XCTAssertEqual(quotas, [#"{"agent":"codex"}"#])
        receiver.handle("I:3")
        XCTAssertEqual(changes, 1)
    }
}
