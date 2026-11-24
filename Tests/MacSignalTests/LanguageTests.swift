import AppKit
import XCTest
@testable import MacSignal
@testable import MacSignalCore

/// Written from the decision 「默认跟随系统」: MacSignal shows Chinese when the system prefers it and
/// English otherwise, everywhere it shows text.
final class LanguageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Language.current = .english
        StatusModule.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.defaultsKey) }
        agentLogPath = NSTemporaryDirectory() + "macsignal-tests.log"
    }

    override func tearDown() {
        StatusModule.allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.defaultsKey) }
        Language.current = Language.preferred(Locale.preferredLanguages)
        super.tearDown()
    }

    func testFollowsTheFirstPreferredLanguageItHas() {
        XCTAssertEqual(Language.preferred(["en-US", "en", "fr", "de", "zh-Hans"]), .english)
        XCTAssertEqual(Language.preferred(["zh-Hans-CN", "en"]), .chinese)
        XCTAssertEqual(Language.preferred(["zh-CN"]), .chinese)
        XCTAssertEqual(Language.preferred(["fr-FR", "zh-Hans", "en"]), .chinese)
        XCTAssertEqual(Language.preferred(["ja", "fr"]), .english)
        XCTAssertEqual(Language.preferred([]), .english)
    }

    private func hasChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    /// Every text a menu shows: titles, and the labels of rows drawn by views.
    private func texts(_ menu: NSMenu) -> [String] {
        func labels(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels)
        }
        return menu.items.flatMap { item in
            [item.title, item.attributedTitle?.string ?? "", item.toolTip ?? ""]
                + (item.view.map(labels) ?? []) + (item.submenu.map(texts) ?? [])
        }
    }

    private var readings: Readings {
        var r = Readings(snapshot: MetricsSnapshot(cpu: 0.24, memory: 0.67, upload: 4_000, download: 325_000,
                                                   power: PowerReading(watts: 11.4, level: 0.86, pluggedIn: false,
                                                                       charging: false, minutesLeft: 80)))
        r.powerAvailable = true
        r.quotaAgents = ["codex", "claude"]
        let now = Date().timeIntervalSince1970
        r.quota["codex"] = AgentQuota(agent: "codex", windows: [.init(used: 26, minutes: 10080, resets: now + 86_400)],
                                      captured: now - 120)
        return r
    }

    func testEnglishShowsNoChinese() {
        let delegate = AppDelegate()
        delegate.hookedAgents = ["claude", "codex"]
        StatusModule.allCases.forEach { $0.setChecked(true) }
        delegate.rebuildMenu()
        var shown = texts(delegate.menu) + texts(delegate.settingsMenu())
        for pending in [MouseTapPending.needsAccess, .unavailable] {
            let items = AppDelegate.mouseOptionItems(enabled: [.classicScrolling], pending: pending, target: delegate)
            shown += items.map(\.title) + [pending.tooltipText]
        }
        let r = readings
        shown += r.tooltipLines()
        for module in StatusModule.allCases {
            shown += [module.title, module.menuTitle]
            shown += DetailMenuContent.lines(module, r, now: Date()).flatMap { [$0.0, $0.1] }
        }
        shown += [PowerReading(watts: 20, level: 0.5, pluggedIn: true, charging: true, minutesLeft: 40),
                  PowerReading(watts: 5, level: 0.5, pluggedIn: true, charging: false, minutesLeft: nil)]
            .map(Readings.describe)
        shown += [AgentQuota.allReset, AgentMenuContent.empty, AgentMenuContent.markAll,
                  ProcessMenuContent.sampling, ProcessMenuContent.unavailable]
        XCTAssertFalse(shown.isEmpty)
        let chinese = shown.filter(hasChinese)
        XCTAssertEqual(chinese, [], "\(chinese)")
        XCTAssertTrue(shown.contains("Prevent Sleep"))
        XCTAssertTrue(shown.contains("Quit MacSignal"))
    }

    func testTheSameTextsInChinese() {
        Language.current = .chinese
        let delegate = AppDelegate()
        StatusModule.allCases.forEach { $0.setChecked(false) }
        delegate.rebuildMenu()
        XCTAssertEqual(delegate.menu.items.filter { !$0.isSeparatorItem && $0.view?.frame.height != 0 }.map(\.title),
                       ["防止睡眠", "设置", "退出 MacSignal"])
        Language.current = .english
        delegate.rebuildMenu()
        XCTAssertEqual(delegate.menu.items.filter { !$0.isSeparatorItem && $0.view?.frame.height != 0 }.map(\.title),
                       ["Prevent Sleep", "Settings", "Quit MacSignal"])
    }

    func testDurationsAndResetTimes() {
        XCTAssertEqual(durationText(minutes: 45), "45 min")
        XCTAssertEqual(durationText(minutes: 300), "5 hr")
        XCTAssertEqual(durationText(minutes: 80), "1 hr 20 min")
        // 2027-01-15 12:00 UTC: the 15th in every time zone from UTC-11 to UTC+11.
        let window = AgentQuota.Window(used: 26, minutes: 10080, resets: 1_800_014_400)
        XCTAssertTrue(window.resetTime.contains("Jan"), window.resetTime)
        XCTAssertEqual(window.span, "This week")
        Language.current = .chinese
        XCTAssertEqual(durationText(minutes: 80), "1 小时 20 分钟")
        XCTAssertTrue(window.resetTime.contains("1月15日"), window.resetTime)
        XCTAssertEqual(window.span, "本周")
    }
}
