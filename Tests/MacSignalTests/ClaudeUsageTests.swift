import XCTest
@testable import MacSignal

/// Written from the plan (.plan/modules.md §4 「Claude Code 额度直接查」), not from the implementation.
final class ClaudeUsageTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testReplyGivesTheFiveHourAndWeeklyWindows() throws {
        let reply = json("""
        {"five_hour": {"utilization": 16.0, "resets_at": "2026-11-12T15:30:00.123456+00:00"},
         "seven_day": {"utilization": 80, "resets_at": "2026-11-13T09:00:00+00:00"},
         "seven_day_opus": null,
         "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1409, "utilization": 28.18}}
        """)
        let quota = try XCTUnwrap(ClaudeUsage.quota(from: reply, captured: 1_000))
        XCTAssertEqual(quota.agent, "claude")
        XCTAssertEqual(quota.captured, 1_000)
        XCTAssertEqual(quota.windows.map(\.used), [16, 80])
        XCTAssertEqual(quota.windows.map(\.minutes), [300, 10080])
        // Fractional seconds are kept as far as the date parser goes; only the second matters.
        XCTAssertEqual(quota.windows.map { $0.resets.rounded(.down) }, [1_794_497_400, 1_794_560_400])
    }

    func testWindowsWithoutValuesAreSkipped() {
        let partial = json("""
        {"five_hour": {"utilization": null, "resets_at": null},
         "seven_day": {"utilization": 3, "resets_at": "2026-11-13T09:00:00Z"}}
        """)
        XCTAssertEqual(ClaudeUsage.quota(from: partial, captured: 0)?.windows.map(\.minutes), [10080])
        XCTAssertNil(ClaudeUsage.quota(from: json(#"{"five_hour": null, "seven_day": null}"#), captured: 0))
        XCTAssertNil(ClaudeUsage.quota(from: json("<html>Unauthorized</html>"), captured: 0))
    }

    func testOnlyAnUnexpiredAccessTokenIsUsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func login(_ oauth: String) -> ClaudeUsage.Login {
            ClaudeUsage.login(fromCredentials: json(#"{"claudeAiOauth": \#(oauth)}"#), now: now)
        }
        XCTAssertEqual(login(#"{"accessToken": "tok", "refreshToken": "r", "expiresAt": 1800000060000}"#), .token("tok"))
        // Expired: never sent; Claude Code is asked to renew it (MacSignal never writes it itself).
        XCTAssertEqual(login(#"{"accessToken": "tok", "expiresAt": 1799999990000}"#), .expired)
        guard case .none = login(#"{"refreshToken": "r"}"#) else { return XCTFail("login without a token used") }
        guard case .none = ClaudeUsage.login(fromCredentials: json("not json"), now: now) else { return XCTFail() }
        // No expiry stored: used, and the service decides.
        XCTAssertEqual(login(#"{"accessToken": "tok"}"#), .token("tok"))
    }

    func testClaudeCodeIsGivenTheSystemProxy() {
        let system: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
                                     "ExceptionsList": ["localhost", "*.local"]]
        let env = ClaudeUsage.proxyEnvironment(system: system, inherited: ["HOME": "/Users/me"])
        XCTAssertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")
        XCTAssertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        XCTAssertEqual(env["NO_PROXY"], "localhost,*.local")
        XCTAssertEqual(env["HOME"], "/Users/me")
        // A proxy the user set themselves wins.
        let own = ClaudeUsage.proxyEnvironment(system: system, inherited: ["https_proxy": "http://mine:1"])
        XCTAssertNil(own["HTTPS_PROXY"])
        XCTAssertEqual(own["https_proxy"], "http://mine:1")
        // No system proxy: nothing added.
        XCTAssertEqual(ClaudeUsage.proxyEnvironment(system: ["HTTPSEnable": 0, "HTTPSProxy": "x"], inherited: [:]), [:])
        // Only an HTTP proxy: used for both.
        let http = ClaudeUsage.proxyEnvironment(system: ["HTTPEnable": 1, "HTTPProxy": "p", "HTTPPort": 8080], inherited: [:])
        XCTAssertEqual(http["HTTPS_PROXY"], "http://p:8080")
    }

    func testAReadQuotaFollowsTheNewestRule() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "macsignal-tests-\(UUID().uuidString)"))
        let limits = UsageLimits(defaults: defaults)
        let older = AgentQuota(agent: "claude", windows: [.init(used: 72, minutes: 10080, resets: 2e9)], captured: 100)
        let newer = AgentQuota(agent: "claude", windows: [.init(used: 80, minutes: 10080, resets: 2e9)], captured: 200)
        XCTAssertTrue(limits.apply(newer))
        // A statusLine report taken earlier does not replace what the app read later.
        XCTAssertFalse(limits.apply(older))
        XCTAssertEqual(limits.byAgent["claude"], newer)
        // Kept across launches.
        XCTAssertEqual(UsageLimits(defaults: defaults).byAgent["claude"], newer)
    }
}
