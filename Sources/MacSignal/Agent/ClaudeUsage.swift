import CFNetwork
import Foundation

/// Claude Code's quota, read from the service its /usage command reads, with the Claude Code login
/// in the keychain. Claude Code passes its quota to a statusLine command only in the terminal; the
/// Claude app never runs one, so without this the number stays where a terminal session left it.
/// The login is read the way Claude Code reads it, with the `security` command, which the keychain
/// item trusts from the start: no dialog, and Claude Code rewriting the item on renewal changes
/// nothing. MacSignal never writes the login: the Claude app passes its own login to the Claude Code
/// it runs and leaves this one to expire, so when it has expired MacSignal has Claude Code renew it
/// (see renewLogin).
final class ClaudeUsage {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let interval: TimeInterval = 5 * 60

    /// Called on the main thread with each quota read.
    var onQuota: ((AgentQuota) -> Void)?
    private var busy = false
    private var lastError: String?

    /// Reads the quota now unless a read is under way. Call on the main thread.
    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var login = Self.readLogin()
            if login == .expired, Self.renewLogin() { login = Self.readLogin() }
            DispatchQueue.main.async { self?.request(login) }
        }
    }

    private func request(_ login: Login) {
        switch login {
        case .none(let why):
            finish(error: why)
        case .expired:
            finish(error: "the Claude Code login has expired and Claude Code did not renew it")
        case .token(let token):
            var request = URLRequest(url: Self.url, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("MacSignal", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode
                let quota = status == 200 ? data.flatMap { Self.quota(from: $0, captured: Date().timeIntervalSince1970) } : nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let quota {
                        self.onQuota?(quota)
                        self.finish(error: nil)
                    } else {
                        self.finish(error: error.map { "Claude Code usage: \($0.localizedDescription)" }
                            ?? "Claude Code usage: HTTP \(status.map(String.init) ?? "?")\(status == 200 ? ", no quota in the reply" : "")")
                    }
                }
            }.resume()
        }
    }

    private func finish(error: String?) {
        busy = false
        // The same failure every 5 minutes is logged once.
        if let error, error != lastError { agentLog(error) }
        lastError = error
    }

    // MARK: Login

    enum Login: Equatable {
        case token(String)
        /// No login to use now (none, unreadable); tried again next time.
        case none(String)
        case expired
    }

    /// Where Claude Code's installers put the `claude` command (an app started from the Dock
    /// has no shell PATH).
    static let claudeCommands = ["~/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "~/.claude/local/claude"]

    /// Has Claude Code renew its expired login. Claude Code renews it before anything that needs it:
    /// first `claude mcp list`, which fetches the claude.ai connectors and uses no quota; when that did
    /// not renew it (no connectors, or Claude Code changed), a one-dot request to the smallest model,
    /// about 650 tokens at most once every eight hours, without the user's settings, hooks or a saved session.
    private static func renewLogin() -> Bool {
        guard let path = claudeCommands.map({ NSString(string: $0).expandingTildeInPath })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        let environment = proxyEnvironment(system: CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:],
                                           inherited: ProcessInfo.processInfo.environment)
        return renewLogin(run: { _ = run(path, $0, environment: environment) }, readLogin: readLogin)
    }

    static func renewLogin(defaults: UserDefaults = .standard, now: () -> Date = Date.init,
                           run: ([String]) -> Void, readLogin: () -> Login) -> Bool {
        for arguments in [["mcp", "list"],
                          ["-p", ".", "--model", "haiku", "--tools", "", "--system-prompt", "Reply with one dot.",
                           "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence"]] {
            if arguments[0] == "-p" {
                let key = "claudeLastModelRenewalAttempt"
                let attempt = now()
                if let last = defaults.object(forKey: key) as? Date, attempt.timeIntervalSince(last) < 8 * 3600 {
                    return false
                }
                defaults.set(attempt, forKey: key)
            }
            run(arguments)
            if case .token = readLogin() {
                agentLog("Claude Code renewed its login after `claude \(arguments[0] == "-p" ? "-p" : arguments.joined(separator: " "))`")
                return true
            }
        }
        return false
    }

    /// An app started from the Dock has no proxy variables, and Claude Code reads the proxy only from
    /// them (MacSignal's own requests follow the system settings): without them its renewal is
    /// blocked where Anthropic needs the proxy. Adds the system HTTP/HTTPS proxy unless already set.
    static func proxyEnvironment(system: [String: Any], inherited: [String: String]) -> [String: String] {
        var environment = inherited
        guard !inherited.keys.contains(where: { ["HTTPS_PROXY", "https_proxy"].contains($0) }) else { return environment }
        func proxy(_ kind: String) -> String? {
            guard (system["\(kind)Enable"] as? NSNumber)?.boolValue == true,
                  let host = system["\(kind)Proxy"] as? String, !host.isEmpty else { return nil }
            return "http://\(host)" + ((system["\(kind)Port"] as? NSNumber).map { ":\($0)" } ?? "")
        }
        guard let https = proxy("HTTPS") ?? proxy("HTTP") else { return environment }
        environment["HTTPS_PROXY"] = https
        environment["HTTP_PROXY"] = proxy("HTTP") ?? https
        if let exceptions = system["ExceptionsList"] as? [String], !exceptions.isEmpty {
            environment["NO_PROXY"] = exceptions.joined(separator: ",")
        }
        return environment
    }

    private static func readLogin() -> Login {
        guard let result = run("/usr/bin/security", ["find-generic-password", "-a", NSUserName(), "-w",
                                                     "-s", "Claude Code-credentials"]) else {
            return .none("reading the Claude Code login did not finish")
        }
        switch result.status {
        case 0: return login(fromCredentials: result.output)
        case 44: return .none("no Claude Code login in the keychain")
        default: return .none("reading the Claude Code login failed: security exited \(result.status)")
        }
    }

    /// Runs a command and returns its exit status and output; nil when it could not start or took
    /// over 30 seconds.
    private static func run(_ path: String, _ arguments: [String],
                            environment: [String: String]? = nil) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        // Away from any project, so no project MCP servers or settings come along.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        // Read while it runs: output larger than the pipe buffer would otherwise block it.
        var output = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            return nil
        }
        read.wait()
        return (process.terminationStatus, output)
    }

    /// The access token in Claude Code's stored login: {"claudeAiOauth": {"accessToken", "expiresAt"}},
    /// `expiresAt` in milliseconds.
    static func login(fromCredentials data: Data, now: Date = Date()) -> Login {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .none("the Claude Code login has no access token")
        }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           expires / 1000 <= now.timeIntervalSince1970 {
            return .expired
        }
        return .token(token)
    }

    // MARK: Reply

    /// {"five_hour": {"utilization": 16.0, "resets_at": "2026-11-12T15:30:00.123+00:00"}, "seven_day": …};
    /// a window whose values are null is skipped.
    static func quota(from data: Data, captured: Double) -> AgentQuota? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes -> AgentQuota.Window? in
            guard let window = object[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue,
                  let resets = (window["resets_at"] as? String).flatMap(parseTimestamp) else { return nil }
            return AgentQuota.Window(used: used, minutes: minutes, resets: resets.timeIntervalSince1970)
        }
        return windows.isEmpty ? nil : AgentQuota(agent: "claude", windows: windows, captured: captured)
    }
}
