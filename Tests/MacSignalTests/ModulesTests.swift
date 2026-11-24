import AppKit
import XCTest
@testable import MacSignal
@testable import MacSignalCore

/// Written from the plan (.plan/modules.md), not from the implementation.
final class ModulesTests: XCTestCase {
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

    private func quota(_ agent: String, _ used: Double, resetsIn: Double = 3600, captured: Double = 1_800_000_000) -> AgentQuota {
        AgentQuota(agent: agent, windows: [.init(used: used, minutes: 300, resets: now.timeIntervalSince1970 + resetsIn)],
                   captured: captured)
    }

    /// Every module available: battery, two agents with quota, the light.
    private func everything(_ snapshot: MetricsSnapshot = .empty) -> Readings {
        var r = Readings(snapshot: snapshot)
        r.powerAvailable = true
        r.quotaAgents = ["codex", "claude"]
        r.quota = ["codex": quota("codex", 26), "claude": quota("claude", 62)]
        r.lamps = [false, true, false]
        return r
    }

    private func kinds(_ cells: [MenuBarRenderer.Cell]) -> [String] {
        cells.map {
            switch $0 {
            case let .reading(caption, _, _, _, _): return caption
            case .network: return "NET"
            case .lamps: return "LAMPS"
            }
        }
    }

    // MARK: Which modules show

    func testDefaultsAreTheEarlierModulesAndNewOnesStartOff() {
        XCTAssertEqual(StatusModule.allCases.filter(\.isChecked), [.network, .cpu, .memory, .light])
        XCTAssertEqual(kinds(StatusModule.cells(everything(), now: now)), ["NET", "CPU", "MEM", "LAMPS"])
    }

    func testOrderIsFixedWithTheLightLast() {
        StatusModule.allCases.forEach { $0.setChecked(true) }
        XCTAssertEqual(kinds(StatusModule.cells(everything(), now: now)),
                       ["NET", "CPU", "MEM", "PWR", "CODEX", "CLAUDE", "LAMPS"])
    }

    func testModulesWhoseConditionIsNotMetAreNeitherOfferedNorDrawnButStayChecked() {
        StatusModule.allCases.forEach { $0.setChecked(true) }
        let bare = Readings(snapshot: .empty, powerAvailable: false)
        XCTAssertEqual(StatusModule.allCases.filter { $0.isAvailable(bare) }, [.network, .cpu, .memory])
        XCTAssertEqual(kinds(StatusModule.cells(bare, now: now)), ["NET", "CPU", "MEM"])
        XCTAssertTrue(StatusModule.light.isChecked)
        XCTAssertTrue(StatusModule.quota.isChecked)
    }

    func testQuotaShowsOnlyHookedAgentsThatHaveReported() {
        StatusModule.quota.setChecked(true)
        var r = everything()
        r.quotaAgents = ["codex"]
        XCTAssertEqual(kinds(StatusModule.quota.cells(r, now: now)), ["CODEX"])
        r.quotaAgents = ["codex", "claude"]
        r.quota["claude"] = nil
        XCTAssertEqual(kinds(StatusModule.quota.cells(r, now: now)), ["CODEX"])
        XCTAssertTrue(StatusModule.quota.isAvailable(r))
        r.quotaAgents = []
        XCTAssertFalse(StatusModule.quota.isAvailable(r))
    }

    func testQuotaShowsTheMostUsedWindowAndADashOnceEveryWindowReset() {
        var q = quota("codex", 26)
        q.windows.append(.init(used: 71, minutes: 10080, resets: now.timeIntervalSince1970 + 86400))
        XCTAssertEqual(q.used(at: now), 0.71)
        q.windows[1].resets = now.timeIntervalSince1970 - 1
        XCTAssertEqual(q.used(at: now), 0.26)
        q.windows[0].resets = now.timeIntervalSince1970 - 1
        XCTAssertNil(q.used(at: now))
        // The cell stays, so nothing beside it moves.
        var r = everything()
        r.quota["codex"] = q
        guard case let .reading(_, value, fraction, _, _) = StatusModule.quota.cells(r, now: now)[0] else {
            return XCTFail("quota cell")
        }
        XCTAssertEqual(value, "—")
        XCTAssertNil(fraction)
        XCTAssertEqual(q.describe(now: now), "已重置，等待新数据")
    }

    // MARK: Drawing

    func testWidthDependsOnlyOnWhatIsShown() {
        StatusModule.allCases.forEach { $0.setChecked(true) }
        let busy = MetricsSnapshot(cpu: 1, memory: 1, upload: 999_000_000, download: 98_700_000,
                                   power: PowerReading(watts: 140, level: 1, pluggedIn: true, charging: false, minutesLeft: nil))
        let calm = MetricsSnapshot(cpu: 0.01, memory: 0.2, upload: 0, download: 4,
                                   power: PowerReading(watts: 3.2, level: 0.2, pluggedIn: false, charging: false, minutesLeft: 30))
        var widths: Set<CGFloat> = []
        for snapshot in [MetricsSnapshot.empty, busy, calm] {
            for used in [0.0, 100] {
                var r = everything(snapshot)
                r.quota = ["codex": quota("codex", used), "claude": quota("claude", used, resetsIn: -1)]
                r.lamps = used == 0 ? [false, false, false] : [true, true, true]
                // Nor does 防止睡眠: its bar has room kept on the left.
                for (numbers, sleep) in [(false, false), (true, false), (false, true), (true, true)] {
                    let cells = StatusModule.cells(r, now: now)
                    let image = MenuBarRenderer.image(cells, preventingSleep: sleep, style: .init(showNumbers: numbers))
                    XCTAssertEqual(image.size.width, MenuBarRenderer.width(cells))
                    widths.insert(image.size.width)
                }
            }
        }
        XCTAssertEqual(widths.count, 1)
    }

    func testDefaultWidthStaysNarrow() {
        var r = everything()
        r.lamps = [false, false, false]
        // Default modules with an agent hooked up: 142 pt in the plan (main: 116, 176 with numbers).
        XCTAssertLessThanOrEqual(MenuBarRenderer.width(StatusModule.cells(r, now: now)), 142)
    }

    /// Renders at `scale` and returns the pixel at (x, y) in points from the bottom left.
    private func pixel(_ image: NSImage, _ x: CGFloat, _ y: CGFloat, scale: CGFloat = 2) -> NSColor {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh - 1 - Int(y * scale))!
    }

    func testEachLampIsLitByItsOwnSessionsAndTheRedOneBlinks() {
        // The light alone: housing from x 1, lamps at x 5, y 16 / 10.5 / 5.
        func alphas(_ lit: [Bool], dimmed: Bool = false) -> [CGFloat] {
            let image = MenuBarRenderer.image([.lamps(lit: lit, redDimmed: dimmed)])
            // The housing is the last 8 pt before the 1 pt margin.
            let center = image.size.width - 1 - 4
            return [16, 10.5, 5].map { (pixel(image, center, $0).alphaComponent * 100).rounded() / 100 }
        }
        XCTAssertEqual(alphas([true, true, true]), [1, 1, 1])
        XCTAssertEqual(alphas([false, true, false]), alphas([false, true, false]))
        let some = alphas([false, true, false])
        XCTAssertEqual(some[1], 1)
        XCTAssertLessThan(some[0], 0.5)
        XCTAssertLessThan(some[2], 0.5)
        XCTAssertLessThan(alphas([true, false, false], dimmed: true)[0], 0.5)
    }

    func testNothingToShowDrawsTheIcon() {
        let image = MenuBarRenderer.image([])
        // 18 pt for the icon, after the room kept for the 防止睡眠 bar.
        XCTAssertEqual(image.size.width, 22)
        let opaque = stride(from: 6.0, to: 20, by: 1).flatMap { x in
            stride(from: 4.0, to: 18, by: 1).map { y in pixel(image, x, y).alphaComponent }
        }.filter { $0 > 0.5 }
        XCTAssertGreaterThan(opaque.count, 10)
    }

    func testNumbersSwapBarsForPercentagesOnlyForScaledReadings() {
        let cell = MenuBarRenderer.Cell.percent("CPU", 1)
        // A full bar fills the bottom row's middle; with numbers that spot is between digits or text.
        // The cell runs from 5 pt (after the 防止睡眠 room) to 1 pt before the end.
        let bar = pixel(MenuBarRenderer.image([cell]), 2 + MenuBarRenderer.width([cell]) / 2, 6.5)
        XCTAssertGreaterThan(bar.alphaComponent, 0.9)
        XCTAssertEqual(MenuBarRenderer.percent(0.244), "24%")
        XCTAssertEqual(MenuBarRenderer.percent(1.2), "100%")
        XCTAssertEqual(MenuBarRenderer.percent(nil), "—")
        guard case let .reading(_, value, fraction, scaled, _) = StatusModule.power.cells(
            Readings(snapshot: MetricsSnapshot(cpu: nil, memory: nil, upload: nil, download: nil,
                                               power: PowerReading(watts: 6.84, level: nil, pluggedIn: true,
                                                                   charging: false, minutesLeft: nil))))[0] else {
            return XCTFail("power cell")
        }
        XCTAssertEqual(value, "6.8W")
        XCTAssertNil(fraction)
        XCTAssertFalse(scaled)
        XCTAssertEqual(StatusModule.watts(11.4), "11W")
    }

    func testDrawingFollowsTheMenuBarAppearance() {
        let cell = MenuBarRenderer.Cell.percent("CPU", 1)
        let x = 2 + MenuBarRenderer.width([cell]) / 2
        XCTAssertGreaterThan(pixel(MenuBarRenderer.image([cell], style: .init(dark: true)), x, 6.5).redComponent, 0.9)
        XCTAssertLessThan(pixel(MenuBarRenderer.image([cell], style: .init(dark: false)), x, 6.5).redComponent, 0.1)
        XCTAssertNotEqual(MenuBarRenderer.lampColors(dark: true), MenuBarRenderer.lampColors(dark: false))
    }

    // MARK: Power

    func testPowerReadsBatteryStatesAndHidesUnknownTimes() {
        func source(_ state: String, charging: Bool, toEmpty: Int = -1, toFull: Int = -1) -> [[String: Any]] {
            [["Type": "InternalBattery", "Current Capacity": 86, "Max Capacity": 100, "Power Source State": state,
              "Is Charging": charging, "Time to Empty": toEmpty, "Time to Full Charge": toFull]]
        }
        let battery = PowerSampler.reading(milliwatts: 11378, sources: source("Battery Power", charging: false, toEmpty: 300))
        XCTAssertEqual(battery.watts, 11.378, accuracy: 0.001)
        XCTAssertEqual(battery.level, 0.86)
        XCTAssertFalse(battery.pluggedIn)
        XCTAssertEqual(battery.minutesLeft, 300)
        XCTAssertEqual(Readings.describe(battery), "整机 11.4 W · 电量 86%，使用电池，还可使用 5 小时")
        let charging = PowerSampler.reading(milliwatts: 20000, sources: source("AC Power", charging: true, toFull: 40))
        XCTAssertEqual(Readings.describe(charging), "整机 20.0 W · 电量 86%，正在充电，还需 40 分钟充满")
        // Plugged in but full or held back: no time; macOS still estimating (-1): no time either.
        let full = PowerSampler.reading(milliwatts: 9000, sources: source("AC Power", charging: false, toEmpty: 65535))
        XCTAssertEqual(Readings.describe(full), "整机 9.0 W · 电量 86%，已接电源，未充电")
        XCTAssertNil(PowerSampler.reading(milliwatts: 9000, sources: source("Battery Power", charging: false)).minutesLeft)
    }

    // MARK: Quota

    func testCodexAndClaudeQuotaParse() throws {
        let codex = try XCTUnwrap(AgentQuota.codex([
            "primary": ["used_percent": 26.0, "window_minutes": 10080, "resets_at": 1_800_100_000],
            "secondary": NSNull()], captured: 1_800_000_000))
        XCTAssertEqual(codex.windows, [.init(used: 26, minutes: 10080, resets: 1_800_100_000)])
        XCTAssertNil(AgentQuota.codex(["primary": NSNull()], captured: 0))
        let claude = try XCTUnwrap(AgentQuota.claude([
            "five_hour": ["used_percentage": 62, "resets_at": 1_800_010_000],
            "seven_day": ["used_percentage": 30, "resets_at": 1_800_500_000]], captured: 1_800_000_000))
        XCTAssertEqual(claude.used(at: now), 0.62)
        XCTAssertEqual(claude.windows.map(\.minutes), [300, 10080])
    }

    func testANewerReportWinsAndQuotaIsKeptAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "macsignal-tests-\(UUID().uuidString)"))
        let limits = UsageLimits(defaults: defaults)
        func json(_ q: AgentQuota) -> String { String(decoding: try! JSONEncoder().encode(q), as: UTF8.self) }
        XCTAssertTrue(limits.apply(json(quota("codex", 30, captured: 200))))
        XCTAssertFalse(limits.apply(json(quota("codex", 10, captured: 100))))
        XCTAssertEqual(limits.byAgent["codex"]?.windows.first?.used, 30)
        XCTAssertFalse(limits.apply("not json"))
        XCTAssertFalse(limits.apply(json(quota("someone", 10))))
        XCTAssertEqual(UsageLimits(defaults: defaults).byAgent["codex"]?.windows.first?.used, 30)
    }

    func testCodexQuotaIsTheLatestInTheLogEvenFarBackAndPastBrokenLines() throws {
        let path = NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        func event(_ used: Double, _ time: String) -> String {
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":300,"resets_at":1800100000},"secondary":null}}}"#
        }
        let filler = #"{"type":"response_item","payload":{"output":""# + String(repeating: "x", count: 3 << 20) + #""}}"#
        let lines = [event(10, "2027-01-15T08:00:00.000Z"), event(26, "2027-01-15T08:00:01.500Z"), filler,
                     #"{"payload":{"rate_limits":null}}"#, #"{"timestamp":"2027-01-15T08:00:09Z","payload":{"rate_limits":{"prim"#]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let q = try XCTUnwrap(codexQuota(transcript: path))
        XCTAssertEqual(q.windows.first?.used, 26)
        // The event's own time (2027-01-15T08:00:01.5Z), so reports from several sessions compare.
        XCTAssertEqual(q.captured, 1_800_000_001.5, accuracy: 0.001)
    }

    func testLastLineFindsLinesAcrossChunkBoundaries() throws {
        let path = NSTemporaryDirectory() + "lines-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A wanted line straddling the 1 MB chunk edge, counted from the end.
        let tail = String(repeating: "y", count: (1 << 20) - 10)
        try ("first\nWANTED-" + String(repeating: "w", count: 40) + "\n" + tail).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(lastLine(of: path) { $0.hasPrefix("WANTED-") }?.count, 47)
        XCTAssertEqual(lastLine(of: path) { $0 == "first" }, "first")
        XCTAssertNil(lastLine(of: path) { $0 == "missing" })
    }

    // MARK: Claude Code statusLine

    private func claudeSettings(_ json: String) throws -> Integration {
        let home = NSTemporaryDirectory() + "macsignal-modules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        Integration.home = home
        try json.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        return try XCTUnwrap(Integration.all.first { $0.id == "claude" })
    }

    private func settings(_ claude: Integration) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: claude.hooksFile))) as? [String: Any])
    }

    func testStatusLineGoesInOnlyWhereThereIsNoneAndComesOutOnlyIfOurs() throws {
        let claude = try claudeSettings(#"{"model": "opus", "hooks": {"Stop": []}}"#)
        XCTAssertEqual(claude.statusLine, .none)
        try claude.setStatusLine(true)
        let line = try XCTUnwrap(try settings(claude)["statusLine"] as? [String: String])
        XCTAssertEqual(line["type"], "command")
        XCTAssertTrue(line["command"]!.contains("statusline"))
        XCTAssertTrue(line["command"]!.hasPrefix("[ -x "))
        XCTAssertEqual(claude.statusLine, .ours(current: true))
        XCTAssertEqual(try settings(claude)["model"] as? String, "opus")
        try claude.setStatusLine(false)
        XCTAssertNil(try settings(claude)["statusLine"])
        XCTAssertEqual(try settings(claude)["model"] as? String, "opus")
        XCTAssertNotNil(try settings(claude)["hooks"])

        let theirs = try claudeSettings(#"{"statusLine": {"type": "command", "command": "~/bin/line.sh"}}"#)
        XCTAssertEqual(theirs.statusLine, .theirs)
        try theirs.setStatusLine(true)
        try theirs.setStatusLine(false)
        XCTAssertEqual((try settings(theirs)["statusLine"] as? [String: String])?["command"], "~/bin/line.sh")
    }

    func testStatusLineOfAMovedAppIsRewritten() throws {
        let claude = try claudeSettings(#"{"statusLine": {"type": "command", "command": "[ -x \"/Old/MacSignal.app/Contents/MacOS/MacSignal\" ] || exit 0; \"/Old/MacSignal.app/Contents/MacOS/MacSignal\" statusline"}}"#)
        XCTAssertEqual(claude.statusLine, .ours(current: false))
        try claude.setStatusLine(true)
        XCTAssertEqual(claude.statusLine, .ours(current: true))
    }

    func testConfigWritesFollowSymlinks() throws {
        let claude = try claudeSettings("{}")
        let real = Integration.home + "/dotfiles-settings.json"
        try FileManager.default.moveItem(atPath: claude.hooksFile, toPath: real)
        try FileManager.default.createSymbolicLink(atPath: claude.hooksFile, withDestinationPath: real)
        try claude.setStatusLine(true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: claude.hooksFile), real)
        XCTAssertTrue(try String(contentsOfFile: real, encoding: .utf8).contains("statusline"))
        // The backup keeps the content from before, not a second link to the changed file.
        let bak = claude.hooksFile + ".bak-macsignal"
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: bak))
        XCTAssertEqual(try String(contentsOfFile: bak, encoding: .utf8), "{}")
    }

    // MARK: Config headers with comments

    func testCodexFeaturesHeaderWithACommentIsNotDuplicated() throws {
        let home = NSTemporaryDirectory() + "macsignal-modules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        Integration.home = home
        try "[features] # 功能开关\nweb = true\n".write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        try Integration.all.first { $0.id == "codex" }!.install()
        let text = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[features]").count, 2)
        XCTAssertTrue(text.contains("hooks = true"))
    }

    func testCodexHooksValueKeepsItsComment() throws {
        let home = NSTemporaryDirectory() + "macsignal-modules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        Integration.home = home
        try "[features]\nhooks = false # 先关着\n".write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        try Integration.all.first { $0.id == "codex" }!.install()
        let text = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        XCTAssertTrue(text.contains("hooks = true # 先关着"), text)
        XCTAssertFalse(text.contains("hooks = false"))
    }

    func testICodeEntriesMatchAListIndentedPastAComment() throws {
        let home = NSTemporaryDirectory() + "macsignal-modules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.chrys/hooks", withIntermediateDirectories: true)
        Integration.home = home
        let file = home + "/.chrys/hooks/hooks.yaml"
        try "hooks:\n    # 我的 hook\n    - id: \"mine\"\n      event: \"after_turn\"\n".write(toFile: file, atomically: true, encoding: .utf8)
        try Integration.all.first { $0.id == "icode" }!.install()
        let items = try String(contentsOfFile: file, encoding: .utf8).components(separatedBy: "\n").filter { $0.contains("- id:") }
        // One list, one indentation: four spaces like the user's own entry.
        XCTAssertGreaterThan(items.count, 1)
        XCTAssertTrue(items.allSatisfy { $0.hasPrefix("    - id:") }, "\(items)")
    }

    func testICodeHooksKeyWithACommentIsNotDuplicated() throws {
        let home = NSTemporaryDirectory() + "macsignal-modules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.chrys/hooks", withIntermediateDirectories: true)
        Integration.home = home
        let file = home + "/.chrys/hooks/hooks.yaml"
        try "hooks: # 自定义 hook\n  - id: \"mine\"\n    event: \"after_turn\"\n".write(toFile: file, atomically: true, encoding: .utf8)
        let icode = Integration.all.first { $0.id == "icode" }!
        try icode.install()
        var text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\nhooks:").count + (text.hasPrefix("hooks:") ? 1 : 0), 2)
        XCTAssertTrue(text.contains("id: \"mine\""))
        try icode.uninstall()
        text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("hooks: # 自定义 hook"))
        XCTAssertTrue(text.contains("id: \"mine\""))
    }
}
