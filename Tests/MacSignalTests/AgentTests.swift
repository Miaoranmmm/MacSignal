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
        let originalHome = Integration.home
        addTeardownBlock {
            Integration.home = originalHome
            try FileManager.default.removeItem(atPath: dir)
        }
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

    func testOldUnreadWaitsStayOnlyWhileTheirProcessRuns() throws {
        let sessions = AgentSessions()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try XCTUnwrap(processInfo(pid)).start
        report(sessions, "waiting", "waiting")
        report(sessions, "read-waiting", "waiting")
        report(sessions, "working", "working")
        report(sessions, "no-pid", "waiting")
        report(sessions, "reused-pid", "waiting")
        report(sessions, "old-done", "done")
        report(sessions, "unread-done", "done")
        sessions.markSeen("read-waiting")
        for id in ["waiting", "read-waiting", "working", "no-pid", "reused-pid"] {
            sessions.entries[id]?.updated = Date().addingTimeInterval(-3601)
        }
        for id in ["waiting", "read-waiting", "working", "reused-pid", "old-done", "unread-done"] {
            sessions.entries[id]?.pid = pid
            sessions.entries[id]?.start = start
        }
        sessions.entries["reused-pid"]?.start = start - 1
        sessions.entries["unread-done"]?.start = start - 1
        sessions.entries["old-done"]?.updated = Date().addingTimeInterval(-12 * 3600 - 1)
        sessions.prune()
        // An interrupted turn reports nothing more, so a quiet working session still expires.
        XCTAssertEqual(Set(sessions.entries.keys), ["waiting", "unread-done"])
        XCTAssertEqual(sessions.waitingIDs, ["waiting"])
        XCTAssertEqual(sessions.counts, [1, 0, 1])
    }

    // MARK: Hooks

    func testHookCommandsOfMovedAppsAreOurs() {
        for command in [
            "[ -x \"/Users/me/Downloads/MacSignal/build/MacSignal.app/Contents/MacOS/MacSignal\" ] || exit 0; \"/Users/me/Downloads/MacSignal/build/MacSignal.app/Contents/MacOS/MacSignal\" hook working codex",
            "\"/Applications/MacSignal.app/Contents/MacOS/MacSignal\" hook done",
            // The apps MacSignal replaces.
            "[ -x \"/Applications/MacStats.app/Contents/MacOS/MacStats\" ] || exit 0; \"/Applications/MacStats.app/Contents/MacOS/MacStats\" hook working",
            "[ -x \"/Applications/AITrafficLight.app/Contents/MacOS/AITrafficLight\" ] || exit 0; \"/Applications/AITrafficLight.app/Contents/MacOS/AITrafficLight\" hook working",
            "python3 /Users/me/MiniTrafficLight/trafficlight.py hook waiting",
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
        XCTAssertFalse(try claude.text.contains("Downloads/MacSignal"))
        XCTAssertTrue(try claude.text.contains("afplay done.aiff"))
        XCTAssertTrue(try claude.text.contains("\"model\""))
        // Installing again (re-checking the agent) does not add a second set.
        try claude.install()
        XCTAssertEqual(claude.ourCommands.count, claude.events.count)
        try claude.uninstall()
        XCTAssertFalse(claude.installed)
        XCTAssertTrue(try claude.text.contains("afplay done.aiff"))
    }

    func testICodeBlockKeepsTheMarkerLinesVerbatim() throws {
        let home = try temporaryHome()
        let icode = Integration.all.first { $0.id == "icode" }!
        try FileManager.default.createDirectory(atPath: home + "/.chrys/hooks", withIntermediateDirectories: true)
        try "hooks: []\n".write(toFile: icode.hooksFile, atomically: true, encoding: .utf8)
        try icode.install()
        let lines = try icode.text.components(separatedBy: "\n")
        // Scripts that rewrite hooks.yaml keep the hooks between exactly these two lines.
        XCTAssertTrue(lines.contains("# >>> MacSignal hooks (managed by MacSignal)"))
        XCTAssertTrue(lines.contains("# <<< MacSignal hooks"))
        XCTAssertTrue(icode.installed)
        XCTAssertTrue(icode.current)
        XCTAssertEqual(icode.ourCommands.count, icode.events.count)
        try icode.uninstall()
        XCTAssertFalse(icode.installed)
        XCTAssertEqual(try icode.text, "hooks: []\n")
    }

    func testICodeSpacedEmptyListIsAccepted() throws {
        let home = try temporaryHome()
        let icode = try XCTUnwrap(Integration.all.first { $0.id == "icode" })
        try FileManager.default.createDirectory(atPath: home + "/.chrys/hooks", withIntermediateDirectories: true)
        try "hooks: [ ]\n".write(toFile: icode.hooksFile, atomically: true, encoding: .utf8)
        try icode.install()
        XCTAssertTrue(icode.installed)
        try icode.uninstall()
        XCTAssertEqual(try icode.text, "hooks: []\n")
    }

    func testCodexRejectsUnreadableAndUnsupportedFeaturesWithoutChangingEitherFile() throws {
        _ = try temporaryHome()
        let codex = try XCTUnwrap(Integration.all.first { $0.id == "codex" })
        let config = URL(fileURLWithPath: codex.configDir + "/config.toml")
        let hooks = URL(fileURLWithPath: codex.hooksFile)
        let originalHooks = Data(#"{"hooks":{}}"#.utf8)
        try FileManager.default.createDirectory(atPath: codex.configDir, withIntermediateDirectories: true)
        try originalHooks.write(to: hooks)

        let originalConfig = Data("[features]\nhooks = false\n".utf8)
        try originalConfig.write(to: config)
        try Data("{".utf8).write(to: hooks)
        XCTAssertThrowsError(try codex.install())
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        try originalHooks.write(to: hooks)
        try FileManager.default.removeItem(at: config)

        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        XCTAssertThrowsError(try codex.install()) { XCTAssertTrue($0 is IntegrationError) }
        XCTAssertEqual(try Data(contentsOf: hooks), originalHooks)
        try FileManager.default.removeItem(at: config)

        let unsupported = [
            "features.hooks = true\n",
            "features = { hooks = true }\n",
            "[features.other]\nx = true\n",
            "[ \"features\" ]\nhooks = true\n",
            "[[features.other]]\nx = true\n",
        ]
        for (index, contents) in ([Data([0xff])] + unsupported.map { Data($0.utf8) }).enumerated() {
            try contents.write(to: config)
            XCTAssertThrowsError(try codex.install()) { error in
                XCTAssertTrue(error is IntegrationError)
                if index > 0 { XCTAssertTrue(error.localizedDescription.contains("features.hooks")) }
            }
            XCTAssertEqual(try Data(contentsOf: config), contents)
            XCTAssertEqual(try Data(contentsOf: hooks), originalHooks)
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.path + ".bak-macsignal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path + ".bak-macsignal"))
        }
    }

    func testCodexQuotedHooksKeyIsUpdatedNotDuplicated() throws {
        _ = try temporaryHome()
        let codex = try XCTUnwrap(Integration.all.first { $0.id == "codex" })
        let config = codex.configDir + "/config.toml"
        try FileManager.default.createDirectory(atPath: codex.configDir, withIntermediateDirectories: true)
        try "[features]\n\"hooks\" = false # mine\n".write(toFile: config, atomically: true, encoding: .utf8)
        try codex.install()
        XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), "[features]\nhooks = true # mine\n")
    }

    func testUnreadableHookFilesAndStatusLineSettingsAreNotReplaced() throws {
        _ = try temporaryHome()
        for id in ["claude", "icode"] {
            let agent = try XCTUnwrap(Integration.all.first { $0.id == id })
            let path = URL(fileURLWithPath: agent.hooksFile)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let sentinel = path.appendingPathComponent("user-config")
            let contents = Data("keep me".utf8)
            try contents.write(to: sentinel)
            XCTAssertThrowsError(try agent.install()) { XCTAssertTrue($0 is IntegrationError) }
            XCTAssertThrowsError(try agent.uninstall()) { XCTAssertTrue($0 is IntegrationError) }
            if id == "claude" {
                XCTAssertThrowsError(try agent.setStatusLine(true)) { XCTAssertTrue($0 is IntegrationError) }
                XCTAssertThrowsError(try agent.setStatusLine(false)) { XCTAssertTrue($0 is IntegrationError) }
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".bak-macsignal"))
        }
    }

    func testICodeRejectsUnrecognizedTopLevelHooksWithoutWriting() throws {
        _ = try temporaryHome()
        let icode = try XCTUnwrap(Integration.all.first { $0.id == "icode" })
        let path = URL(fileURLWithPath: icode.hooksFile)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        for config in [
            "hooks: [{id: mine, event: after_turn}]\n",
            "hooks: null\n",
            "hooks:\n  [{id: mine, event: after_turn}]\n",
            "\"hooks\": [{id: mine}]\n",
            "hooks:\n  before_turn: mine\n",
            "hooks:\n- id: a\nhooks: []\n",
            "{\"hooks\": []}\n",
            "hooks :\n",
        ] {
            let data = Data(config.utf8)
            try data.write(to: path)
            XCTAssertThrowsError(try icode.install()) { XCTAssertTrue($0 is IntegrationError) }
            XCTAssertEqual(try Data(contentsOf: path), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".bak-macsignal"))
        }
    }

    /// The block MacStats (and AITrafficLight) wrote is replaced by ours, with the user's hooks kept.
    func testICodeHooksFromMacStatsAreReplaced() throws {
        let home = try temporaryHome()
        let icode = Integration.all.first { $0.id == "icode" }!
        try FileManager.default.createDirectory(atPath: home + "/.chrys/hooks", withIntermediateDirectories: true)
        let old = "/Applications/MacStats.app/Contents/MacOS/MacStats"
        try """
        hooks:
        # >>> AITrafficLight hooks (managed by AITrafficLight.app)
          - id: "traffic-light-turn"
            event: "before_turn"
            run:
              type: "command"
              argv: ["\(old)", "hook", "working", "icode"]
        # <<< AITrafficLight hooks
          - id: "mine"
            event: "after_turn"
            run:
              type: "command"
              argv: ["say", "done"]

        """.write(toFile: icode.hooksFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(icode.installed)
        XCTAssertFalse(icode.current)
        try icode.install()
        XCTAssertFalse(try icode.text.contains("AITrafficLight"))
        XCTAssertFalse(try icode.text.contains(old))
        XCTAssertTrue(try icode.text.contains("# >>> MacSignal hooks (managed by MacSignal)"))
        XCTAssertTrue(try icode.text.contains("id: \"mine\""))
        XCTAssertTrue(icode.current)
    }

    func testClaudeStatusLineFromMacStatsIsOurs() {
        XCTAssertTrue(Integration.isOurStatusLine(
            "[ -x \"/Applications/MacStats.app/Contents/MacOS/MacStats\" ] || exit 0; \"/Applications/MacStats.app/Contents/MacOS/MacStats\" statusline"))
        XCTAssertFalse(Integration.isOurStatusLine("~/bin/my-statusline.sh"))
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
            if #available(macOS 27, *) {
                guard row.responds(to: NSSelectorFromString("preferredImageVisibility")) else {
                    return XCTFail("macOS 27 session row is missing its image visibility property")
                }
                XCTAssertEqual((row.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue, 1)
            }
        }
        // One icon per agent: sessions of the same agent look the same, different agents differ.
        XCTAssertTrue(byID["i"]!.image === byID["i2"]!.image)
        XCTAssertFalse(byID["i"]!.image === byID["c"]!.image)
        XCTAssertFalse(byID["c"]!.image === byID["x"]!.image)
        XCTAssertEqual(byID["x"]!.image?.accessibilityDescription, "Codex")
    }

    func testSessionClickFallsBackAndMarksReadOnlyAfterSuccessfulOpen() throws {
        let terminal = URL(fileURLWithPath: "/Terminal.app")
        for (agent, host, link) in [
            ("codex", "", "codex://threads/session"),
            ("claude", "local_example", "claude://code/continue?session=local_example"),
        ] {
            let receiver = AgentReceiver()
            report(receiver.sessions, "session", "waiting", agent: agent)
            receiver.sessions.entries["session"]?.host = host
            receiver.sessions.entries["session"]?.app = "com.apple.Terminal"
            let content = AgentMenuContent(receiver: receiver)
            let row = try XCTUnwrap(content.items(now: Date()).first { $0.representedObject as? String == "session" })
            var opened: URL?
            var finish: ((Bool) -> Void)?
            func click(handler: URL?, fallback: URL?) {
                opened = nil
                finish = nil
                content.openSession(row, applicationForURL: {
                    XCTAssertEqual($0.absoluteString, link)
                    return handler
                }, applicationForBundle: {
                    XCTAssertEqual($0, "com.apple.Terminal")
                    return fallback
                }) {
                    opened = $0
                    finish = $1
                }
            }
            click(handler: nil, fallback: nil)
            XCTAssertNil(opened)
            XCTAssertEqual(receiver.sessions.waitingIDs, ["session"])
            click(handler: nil, fallback: terminal)
            XCTAssertEqual(opened, terminal)
            try XCTUnwrap(finish)(false)
            XCTAssertEqual(receiver.sessions.waitingIDs, ["session"])
            click(handler: terminal, fallback: nil)
            XCTAssertEqual(opened?.absoluteString, link)
            try XCTUnwrap(finish)(false)
            XCTAssertEqual(receiver.sessions.waitingIDs, ["session"])
            click(handler: nil, fallback: terminal)
            XCTAssertEqual(opened, terminal)
            XCTAssertEqual(receiver.sessions.waitingIDs, ["session"])
            try XCTUnwrap(finish)(true)
            XCTAssertTrue(receiver.sessions.waitingIDs.isEmpty)
        }
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

    func testSettingsShowLightSectionOnlyWithAnAgentHookedUp() {
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
        XCTAssertEqual(headings(menu), ["Agent", "桌面红绿灯", "鼠标", "显示"])
        XCTAssertTrue(menu.items.contains { $0.title == "显示数字" })
        XCTAssertTrue(menu.items.contains { $0.title == "打开日志" })
        // Never connected: 连接, and nothing to follow, test or disconnect yet.
        let visible = menu.items.filter { !$0.isHidden }.map(\.title)
        XCTAssertTrue(visible.contains("连接"))
        XCTAssertFalse(visible.contains("灯光跟随"))
        XCTAssertFalse(visible.contains("断开连接"))
    }

    func testDisconnectingOneAgentClearsItsSessionsAndIgnoresLaterReports() throws {
        _ = try temporaryHome()
        let claude = try XCTUnwrap(Integration.all.first { $0.id == "claude" })
        let codex = try XCTUnwrap(Integration.all.first { $0.id == "codex" })
        try claude.install()
        try codex.install()
        let delegate = AppDelegate()
        delegate.hookedAgents = ["claude", "codex"]
        let receiver = delegate.receiver
        agentLogPath = NSTemporaryDirectory() + "macsignal-tests.log"
        receiver.handle(#"J:{"state":"waiting","session":"claude-session","agent":"claude"}"#)
        receiver.handle(#"J:{"state":"working","session":"codex-session","agent":"codex"}"#)
        XCTAssertEqual(receiver.sessions.counts, [1, 1, 0])
        try claude.uninstall()
        delegate.refreshAgents()
        XCTAssertEqual(delegate.hookedAgents, ["codex"])
        XCTAssertEqual(Set(receiver.sessions.entries.keys), ["codex-session"])
        var changes = 0
        receiver.onSessionsChange = { changes += 1 }
        receiver.handle(#"J:{"state":"waiting","session":"late","agent":"claude"}"#)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(receiver.sessions.counts, [0, 1, 0])
    }

    func testClaudeQuotaIsAvailableWithAUserStatusLine() throws {
        _ = try temporaryHome()
        let claude = try XCTUnwrap(Integration.all.first { $0.id == "claude" })
        try FileManager.default.createDirectory(atPath: claude.configDir, withIntermediateDirectories: true)
        let settings = URL(fileURLWithPath: claude.hooksFile)
        try Data(#"{"statusLine":{"type":"command","command":"~/bin/my-status.sh"}}"#.utf8).write(to: settings)
        try claude.install()
        let original = try Data(contentsOf: settings)
        let defaults = UserDefaults.standard
        let key = StatusModule.quota.defaultsKey
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        StatusModule.quota.setChecked(true)
        let delegate = AppDelegate()
        delegate.hookedAgents = ["claude"]
        delegate.refreshAgents()
        let menu = delegate.settingsMenu()
        let quota = try XCTUnwrap(menu.items.first { $0.title == StatusModule.quota.title })
        XCTAssertTrue(quota.isEnabled)
        XCTAssertEqual(quota.state, .on)
        XCTAssertFalse(menu.items.contains { $0.title.contains("未统计") })
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    /// A report on the socket reaches the sessions and a finish goes to the light; a report from an
    /// agent that isn't hooked up, or any other message, is ignored.
    func testReceiverAppliesSessionReportsAndQuotas() {
        let receiver = AgentReceiver()
        receiver.hookedAgents = ["claude"]
        var changes = 0, quotas: [String] = [], finished: [String] = []
        receiver.onSessionsChange = { changes += 1 }
        receiver.onQuota = { quotas.append($0) }
        receiver.onSessionFinished = { finished.append($0) }
        receiver.handle(#"J:{"state":"working","session":"s1","agent":"claude","project":"p"}"#)
        XCTAssertEqual(receiver.sessions.counts, [0, 1, 0])
        XCTAssertEqual(changes, 1)
        receiver.handle(#"J:{"state":"done","session":"s1","agent":"claude"}"#)
        XCTAssertEqual(finished, ["s1"])
        receiver.handle(#"Q:{"agent":"codex"}"#)
        XCTAssertEqual(quotas, [#"{"agent":"codex"}"#])
        // A repeated finish is not a new one.
        receiver.handle(#"J:{"state":"done","session":"s1","agent":"claude"}"#)
        XCTAssertEqual(finished, ["s1"])
        receiver.handle(#"J:{"state":"done","session":"s2","agent":"codex"}"#)
        receiver.handle("I:3")
        XCTAssertEqual(finished, ["s1"])
        XCTAssertEqual(changes, 3)
    }

    /// §3.1: without a remembered light a restart counts as 已断开; a remembered one reconnects.
    func testRestartWithoutRememberedLightStaysDisconnected() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "deviceID"), defaults.object(forKey: "devicePaused"))
        defer {
            defaults.set(saved.0, forKey: "deviceID")
            defaults.set(saved.1, forKey: "devicePaused")
        }
        // 连接 was chosen, but no light was found before quitting.
        defaults.removeObject(forKey: "deviceID")
        defaults.set(false, forKey: "devicePaused")
        XCTAssertTrue(TrafficLightDevice(sessions: AgentSessions()).paused)

        defaults.set("0F0F-LIGHT", forKey: "deviceID")
        defaults.set(false, forKey: "devicePaused")
        XCTAssertFalse(TrafficLightDevice(sessions: AgentSessions()).paused)
    }
}
