import AppKit
import XCTest
@testable import MacSignal
@testable import MacSignalCore

/// Written from the decision 「菜单跟状态栏一致」: the menu lists the details of the modules the
/// menu bar shows, in its order, 「Agent 会话」 first; the open menu follows 设置 › 显示.
final class MenuDetailsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The texts below are the Chinese ones; LanguageTests covers English.
        Language.current = .chinese
        StatusModule.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.defaultsKey) }
        agentLogPath = NSTemporaryDirectory() + "macsignal-tests.log"
    }

    override func tearDown() {
        StatusModule.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.defaultsKey) }
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func readings() -> Readings {
        var r = Readings(snapshot: MetricsSnapshot(
            cpu: 0.24, memory: 0.67, upload: 4_000, download: 325_000,
            power: PowerReading(watts: 11.4, level: 0.86, pluggedIn: false, charging: false, minutesLeft: 300)))
        r.powerAvailable = true
        r.quotaAgents = ["codex", "claude"]
        r.quota = ["codex": AgentQuota(agent: "codex", windows: [.init(used: 26, minutes: 10080, resets: now.timeIntervalSince1970 + 86400)],
                                       captured: now.timeIntervalSince1970)]
        r.lamps = [false, true, false]
        return r
    }

    private func headings(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { item in
            guard let view = item.view, !(view is ProcessMenuRow), !(view is MenuActionRow) else { return nil }
            return (view.subviews.first as? NSTextField)?.stringValue
        }
    }

    /// (name, value) of every reading or process row, in order.
    private func rows(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { item in
            (item.view as? ProcessMenuRow).map { row in
                row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }.joined(separator: " | ")
            }
        }
    }

    func testSectionsFollowTheMenuBarModulesInOrder() {
        for module in StatusModule.allCases { module.setChecked(true) }
        StatusModule.cpu.setChecked(false)
        let menu = NSMenu()
        let content = DetailMenuContent(processes: ProcessMenuContent(capture: { nil }))
        content.add(StatusModule.shown(readings()), readings: readings(), to: menu, at: 0, now: now)
        // The light's section is 「Agent 会话」, which is not part of these.
        XCTAssertEqual(headings(menu), ["网速", "内存占用", "功耗", "AI 额度"])
        let shown = rows(menu)
        XCTAssertEqual(Array(shown.prefix(2)), ["上传 | 4 KB/s", "下载 | 325 KB/s"])
        XCTAssertTrue(shown.contains("整机 | 11.4 W"))
        XCTAssertTrue(shown.contains("电量 | 86%，使用电池"))
        XCTAssertTrue(shown.contains("还可使用 | 5 小时"))
        // Codex reported once; Claude Code has not yet.
        XCTAssertTrue(shown.contains { $0.hasPrefix("Codex · 本周 | 26% · ") && $0.hasSuffix(" 重置") })
        XCTAssertTrue(shown.contains("Claude Code | 使用后显示"))

        StatusModule.allCases.forEach { $0.setChecked(false) }
        content.add(StatusModule.shown(readings()), readings: readings(), to: menu, at: 0, now: now)
        XCTAssertEqual(menu.numberOfItems, 0)
    }

    func testOpenMenuRowsFollowTheReadings() {
        StatusModule.allCases.forEach { $0.setChecked(false) }
        StatusModule.quota.setChecked(true)
        StatusModule.power.setChecked(true)
        let menu = NSMenu()
        let tail = NSMenuItem(title: "防止睡眠", action: nil, keyEquivalent: "")
        menu.addItem(tail)
        let content = DetailMenuContent(processes: ProcessMenuContent(capture: { nil }))
        var r = readings()
        content.add(StatusModule.shown(r), readings: r, to: menu, at: 0, now: now)

        // Claude's first report adds a row under AI 额度; the rest of the menu stays in place.
        r.quota["claude"] = AgentQuota(agent: "claude", windows: [
            .init(used: 12, minutes: 300, resets: now.timeIntervalSince1970 + 3600),
            .init(used: 62, minutes: 10080, resets: now.timeIntervalSince1970 + 86400)], captured: now.timeIntervalSince1970)
        r.snapshot = MetricsSnapshot(cpu: 0.24, memory: 0.67, upload: 4_000, download: 325_000,
                                     power: PowerReading(watts: 20, level: 0.86, pluggedIn: true, charging: true, minutesLeft: 40))
        content.update(r, now: now)
        let shown = rows(menu)
        XCTAssertTrue(shown.contains("电量 | 86%，正在充电"))
        XCTAssertTrue(shown.contains("充满还需 | 40 分钟"))
        XCTAssertEqual(shown.filter { $0.hasPrefix("Claude Code · ") }.count, 2)
        XCTAssertFalse(shown.contains("Claude Code | 使用后显示"))
        XCTAssertEqual(headings(menu), ["功耗", "AI 额度"])
        XCTAssertEqual(menu.items.last, tail)
        let quotaHeading = menu.items.firstIndex { ($0.view?.subviews.first as? NSTextField)?.stringValue == "AI 额度" }!
        XCTAssertTrue(menu.items[quotaHeading + 1 ..< quotaHeading + 4].allSatisfy { $0.view is ProcessMenuRow })
        XCTAssertTrue(menu.items[quotaHeading + 4].isSeparatorItem)

        // Every window past its reset: one row saying so.
        content.update(r, now: now.addingTimeInterval(2 * 86400))
        XCTAssertTrue(rows(menu).contains("Claude Code | \(AgentQuota.allReset)"))
        XCTAssertTrue(rows(menu).contains("Codex | \(AgentQuota.allReset)"))
    }

    func testAgentSessionsOnlyWithTheLight() {
        let delegate = AppDelegate()
        delegate.hookedAgents = ["codex"]
        StatusModule.light.setChecked(true)
        delegate.rebuildMenu()
        XCTAssertEqual(headings(delegate.menu).first, "Agent 会话")
        StatusModule.light.setChecked(false)
        delegate.rebuildMenu()
        XCTAssertFalse(headings(delegate.menu).contains("Agent 会话"))
        // Nothing checked: only 防止睡眠, 设置 and 退出.
        StatusModule.allCases.forEach { $0.setChecked(false) }
        delegate.rebuildMenu()
        XCTAssertEqual(headings(delegate.menu), [])
        XCTAssertEqual(delegate.menu.items.filter { !$0.isSeparatorItem && $0.view?.frame.height != 0 }.map(\.title),
                       ["防止睡眠", "设置", "退出 MacSignal"])
    }

    /// 设置 and 退出 start where the rows with views do, with 防止睡眠 on or off: NSMenu keeps the
    /// checkmark column only while some item is checked.
    func testMenusAlwaysHaveACheckedItem() {
        let delegate = AppDelegate()
        StatusModule.allCases.forEach { $0.setChecked(false) }
        delegate.hookedAgents = []
        delegate.rebuildMenu()
        for menu in [delegate.menu, delegate.settingsMenu()] {
            let checked = menu.items.filter { $0.state == .on }
            XCTAssertFalse(checked.isEmpty)
            // Not something the user sees or picks.
            XCTAssertTrue(checked.contains { $0.view?.frame.height == 0 && !$0.isEnabled })
        }
    }
}
