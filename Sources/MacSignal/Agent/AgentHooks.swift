// Agent side: the `hook` subcommand the agents run, and installing those hooks into
// Claude Code / Codex / iCode config files.
import AppKit

/// Agents that report sessions, as (id used by the hooks, display name).
let agentNames: [(id: String, name: String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("icode", "iCode")]

/// `MacSignal hook <working|waiting|notify|done|end> [agent]`: reports this session's state to the
/// running app as "J:" + JSON (state, session, host, app, agent, project, title, pid, start; see Sessions.Report).
/// Never fails the agent: unknown input or a stopped app just does nothing.
func runHook(_ args: [String]) -> Never {
    guard var state = args.first, ["working", "waiting", "notify", "done", "end"].contains(state) else { exit(0) }
    let agent = args.dropFirst().first ?? "claude"
    let env = ProcessInfo.processInfo.environment
    // iCode passes the event as a file; Claude Code and Codex pipe it on stdin.
    var data: Data?
    if let file = env["CHRYS_HOOK_PAYLOAD_FILE"] {
        data = FileManager.default.contents(atPath: file)
    } else if isatty(0) == 0 {
        data = FileHandle.standardInput.readDataToEndOfFile()
    }
    let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    if state == "notify" {
        // idle_prompt fires ~60 s after a finished turn; that session is done, not waiting on you.
        if ["idle_prompt", "auth_success"].contains(payload["notification_type"] as? String) { exit(0) }
        state = "waiting"
    }
    let session = (payload["session_id"] as? String) ?? (payload["thread_id"] as? String) ?? "unknown"
    // Searching the sessions folder by id is slow, so only when the reviewer has to be known.
    let transcript = agent == "codex" && (state == "waiting" || state == "done")
        ? codexTranscript(session: session, given: payload["transcript_path"] as? String, search: state == "waiting") : nil
    // With Codex auto review a model answers the permission request, nobody is asked: still working.
    if let transcript, state == "waiting", codexReviewer(transcript: transcript) == "auto_review" {
        state = "working"
    }
    sendQuota(codexHookQuota(state: state, transcript: transcript))
    let cwd = (payload["cwd"] as? String) ?? ""
    let project = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
    // Where the session lives, so the menu can jump to it.
    let host = agent == "claude" ? env["CLAUDE_CODE_HOST_SESSION_ID"] ?? "" : ""
    let app = env["__CFBundleIdentifier"] ?? ""
    // The task: the prompt that starts the turn (Claude Code / Codex UserPromptSubmit, iCode before_turn).
    let prompt = (payload["prompt"] as? String) ?? (payload["user_text"] as? String) ?? ""
    let firstLine = prompt.split(whereSeparator: \.isNewline).first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) } ?? ""
    // Agents inject their own turns (<task-notification>, <command-message>...): keep the last real task.
    let title = firstLine.hasPrefix("<") ? "" : firstLine
    // The agent process, so the app can drop the session once it's gone (crash, closed window).
    let agentProc = agentProcess()
    let report: [String: Any] = ["state": state, "session": session, "host": host, "app": app, "agent": agent,
                                 "project": project, "title": title, "pid": agentProc?.pid ?? 0, "start": agentProc?.start ?? 0]
    guard let json = try? JSONSerialization.data(withJSONObject: report) else { exit(0) }
    sendToApp("J:" + String(decoding: json, as: UTF8.self))
    exit(0)
}

/// Read the latest quota from the transcript once the turn finishes.
func codexHookQuota(state: String, transcript: String?, read: (String) -> AgentQuota? = codexQuota(transcript:)) -> AgentQuota? {
    guard state == "done", let transcript else { return nil }
    return read(transcript)
}

/// One datagram to the running app; nothing happens when it is not running.
func sendToApp(_ message: String) {
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = makeSockaddr()
    _ = message.withCString { s in
        withUnsafePointer(to: &addr) {
            sendto(fd, s, strlen(s), 0, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                   socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// (parent pid, command name, start time in µs) of a process, nil when it doesn't exist.
func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String, start: Int)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let t = info.kp_proc.p_un.__p_starttime
    return (info.kp_eproc.e_ppid, name, t.tv_sec * 1_000_000 + Int(t.tv_usec))
}

/// The agent that ran this hook: the nearest ancestor that isn't a shell wrapping the command.
func agentProcess() -> (pid: pid_t, start: Int)? {
    var pid = getppid()
    for _ in 0..<4 {
        guard let p = processInfo(pid) else { return nil }
        if !["sh", "bash", "zsh", "dash", "fish", "env"].contains(p.name) { return (pid, p.start) }
        pid = p.ppid
    }
    return nil
}

/// A Codex session's log (~/.codex/sessions/YYYY/MM/DD/rollout-...-<session>.jsonl): the hook's
/// transcript_path, or with `search` found by the session id.
func codexTranscript(session: String, given: String?, search: Bool) -> String? {
    if let given, FileManager.default.fileExists(atPath: given) { return given }
    guard search else { return nil }
    let root = Integration.home + "/.codex/sessions"
    let suffix = "\(session).jsonl"
    return (FileManager.default.enumerator(atPath: root)?.allObjects as? [String])?
        .first { $0.hasSuffix(suffix) }.map { root + "/" + $0 }
}

/// Who answers this Codex session's permission requests ("user" or "auto_review"): the latest
/// approvals_reviewer in its log (the setting is repeated per turn).
func codexReviewer(transcript: String) -> String? {
    let pattern = #""approvals_reviewer":"[a-z_]+""#
    guard let line = lastLine(of: transcript, where: { $0.range(of: pattern, options: .regularExpression) != nil }),
          let r = line.range(of: pattern, options: [.regularExpression, .backwards]) else { return nil }
    return line[r].split(separator: "\"").last.map(String.init)
}

/// One agent's hook config: detecting it, and adding / removing our hooks.
struct Integration {
    let id: String
    let name: String

    static let all = agentNames.map { Integration(id: $0.id, name: $0.name) }
    /// Settable so tests can point the config files at a temporary folder.
    static var home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    /// This app's binary, which the hooks run (so other Macs need no python or repo checkout).
    static var binary: String { Bundle.main.executablePath ?? "/Applications/MacSignal.app/Contents/MacOS/MacSignal" }

    /// Hook state per agent event. Claude Code and Codex share the hooks.json format.
    var events: [(event: String, state: String, matcher: String?)] {
        switch id {
        case "claude":
            // A permission dialog: PermissionRequest right away, Notification (permission_prompt) ~6 s later.
            return [("UserPromptSubmit", "working", nil), ("PreToolUse", "waiting", "AskUserQuestion"),
                    ("PermissionRequest", "waiting", nil),
                    ("PostToolUse", "working", nil), ("Notification", "notify", nil),
                    ("Stop", "done", nil), ("SessionEnd", "end", nil)]
        case "codex":
            return [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                    ("PermissionRequest", "waiting", nil), ("Stop", "done", nil), ("SessionEnd", "end", nil)]
        default:  // iCode; the matcher is a tool name
            return [("before_turn", "working", nil), ("after_tool_call", "working", nil),
                    ("approval_resolved", "working", nil), ("approval_requested", "waiting", nil),
                    ("before_tool_call", "waiting", "ask_user"), ("after_turn", "done", nil),
                    ("session_end", "end", nil)]
        }
    }

    var configDir: String { Integration.home + ["claude": "/.claude", "codex": "/.codex", "icode": "/.chrys"][id]! }
    var hooksFile: String {
        configDir + ["claude": "/settings.json", "codex": "/hooks.json", "icode": "/hooks/hooks.yaml"][id]!
    }

    /// The agent is set up for this user (its config folder exists, or its app is installed).
    var detected: Bool {
        let apps = ["claude": "com.anthropic.claudefordesktop", "codex": "com.openai.codex"]
        return FileManager.default.fileExists(atPath: configDir)
            || apps[id].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
    }

    /// A hook command is ours: MacSignal at any path (the app may have moved).
    static func isOurs(_ command: String) -> Bool {
        command.contains("MacSignal\" hook") || command.contains("\"\(binary)\" hook")
    }

    /// Exits quietly when the app is gone (deleted without turning the agent off first), so the agent
    /// reports no hook errors. iCode needs no guard: its hooks have on_error ignore.
    static var guardPrefix: String { "[ -x \"\(binary)\" ] || exit 0; " }

    func command(_ state: String) -> String {
        Integration.guardPrefix + "\"\(Integration.binary)\" hook \(state)" + (id == "claude" ? "" : " \(id)")
    }

    var text: String { get throws { try Integration.readText(hooksFile) } }

    /// Our hook commands now in the file (iCode: the lines of our hooks' argv).
    var ourCommands: [String] {
        if id == "icode" {
            return (try? text.components(separatedBy: "\n"))?.filter {
                $0.contains("argv") && $0.contains("hook") && $0.contains("icode")
            } ?? []
        }
        guard let data = FileManager.default.contents(atPath: hooksFile),
              let hooks = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { ($0 as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] } }
            .compactMap { $0["command"] as? String }.filter(Integration.isOurs)
    }

    var installed: Bool { id == "icode" ? (try? text.contains("macsignal-")) == true : !ourCommands.isEmpty }

    /// Installed, and every hook runs this copy of the app (false after the app moved or an update).
    var current: Bool {
        let cmds = ourCommands
        return installed && cmds.count == events.count
            && cmds.allSatisfy { $0.contains(Integration.binary) && (id == "icode" || $0.hasPrefix(Integration.guardPrefix)) }
    }

    func install() throws {
        switch id {
        case "icode": try writeYAML(add: true)
        case "codex":
            let path = configDir + "/config.toml"
            // Both files must read before either is written; config.toml first, so if it can't be
            // written hooks.json stays as it was.
            _ = try readJSON()
            let config = try codexConfigEnablingHooks(at: path)
            try backup(path)
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try Integration.save(config, to: path)
            try writeJSON(add: true)
        default: try writeJSON(add: true)
        }
    }

    func uninstall() throws {
        if id == "icode" { try writeYAML(add: false) } else { try writeJSON(add: false) }
    }

    /// Keeps the user's original file once, next to it.
    private func backup(_ path: String) throws {
        let fm = FileManager.default
        let bak = path + ".bak-macsignal"
        if fm.fileExists(atPath: path), !fm.fileExists(atPath: bak) {
            // The file's content, also when it is a symlink (copying the link would back up nothing).
            try fm.copyItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, toPath: bak)
        }
    }

    private static func readConfig(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            if let error = error as? CocoaError,
               error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil {
                return Data()
            }
            throw IntegrationError(L("Could not read \(path): \(error.localizedDescription)",
                                     "无法读取 \(path)：\(error.localizedDescription)"))
        }
    }

    private static func readText(_ path: String) throws -> String {
        guard let text = String(data: try readConfig(path), encoding: .utf8) else {
            throw IntegrationError(L("\(path) is not UTF-8", "\(path) 不是 UTF-8"))
        }
        return text
    }

    private func readJSON() throws -> [String: Any] {
        let data = try Integration.readConfig(hooksFile)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError(L("\(hooksFile) is not a JSON object", "\(hooksFile) 不是 JSON 对象"))
        }
        return root
    }

    /// settings.json / hooks.json: {"hooks": {Event: [{"matcher"?, "hooks": [{"type","command"}]}]}}.
    private func writeJSON(add: Bool) throws {
        var root = try readJSON()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Drop our earlier entries (any version), keep everything else as it was.
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                var g = group
                let list = (g["hooks"] as? [[String: Any]] ?? []).filter { !Integration.isOurs($0["command"] as? String ?? "") }
                if list.isEmpty, !(g["hooks"] as? [Any] ?? []).isEmpty { return nil }
                g["hooks"] = list
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        if add {
            for (event, state, matcher) in events {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command(state)]]]
                if let matcher { group["matcher"] = matcher }
                hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
            }
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try backup(hooksFile)
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Integration.save(data + Data("\n".utf8), to: hooksFile)
    }

    /// Writes a config file atomically. A symlink (dotfiles) is followed and kept: the atomic
    /// write would otherwise replace the link with a plain file.
    static func save(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path).resolvingSymlinksInPath(), options: .atomic)
    }

    // MARK: Claude Code statusLine (for its quota)

    /// Who owns `statusLine` in ~/.claude/settings.json.
    enum StatusLine: Equatable {
        case none, ours(current: Bool), theirs
    }

    /// MacSignal at any path (the app may have moved), like `isOurs`.
    static func isOurStatusLine(_ command: String) -> Bool {
        command.contains("MacSignal\" statusline") || command.contains("\"\(binary)\" statusline")
    }

    static var statusLineCommand: String { guardPrefix + "\"\(binary)\" statusline" }

    /// Claude Code only: whether the user's settings have a statusLine, and whose.
    var statusLine: StatusLine {
        Integration.statusLine(in: (try? readJSON()) ?? [:])
    }

    private static func statusLine(in root: [String: Any]) -> StatusLine {
        guard let line = root["statusLine"] else { return .none }
        let command = (line as? [String: Any])?["command"] as? String ?? ""
        guard Integration.isOurStatusLine(command) else { return .theirs }
        return .ours(current: command == Integration.statusLineCommand)
    }

    /// Claude Code only: puts our statusLine in (when there is none, or ours runs an old path) or
    /// takes it out (only while it is still ours). Touches no other setting.
    func setStatusLine(_ on: Bool) throws {
        var root = try readJSON()
        let now = Integration.statusLine(in: root)
        guard on ? (now == .none || now == .ours(current: false)) : now != .none && now != .theirs else { return }
        try backup(hooksFile)
        root["statusLine"] = on ? ["type": "command", "command": Integration.statusLineCommand] : nil
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Integration.save(data + Data("\n".utf8), to: hooksFile)
    }

    /// Codex runs hooks.json only with `[features] hooks = true` in config.toml.
    private func codexConfigEnablingHooks(at path: String) throws -> Data {
        var lines = try Integration.readText(path).components(separatedBy: "\n")
        // The header may carry a comment: `[features] # …`.
        if let header = lines.firstIndex(where: { $0.range(of: #"^\s*\[features\]\s*(#.*)?$"#, options: .regularExpression) != nil }) {
            let end = lines[(header + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.endIndex
            if let i = lines[(header + 1)..<end].firstIndex(where: { $0.range(of: #"^\s*["']?hooks["']?\s*="#, options: .regularExpression) != nil }) {
                // Keeps a comment after the value.
                lines[i] = lines[i].replacingOccurrences(of: #"^\s*["']?hooks["']?\s*=\s*[^#]*"#, with: "hooks = true ",
                                                         options: .regularExpression).trimmingCharacters(in: .whitespaces)
            } else {
                lines.insert("hooks = true", at: header + 1)
            }
        } else {
            let featureKey = #"(?:features|"features"|'features')"#
            let featureTable = #"^\s*\[\[?\s*\#(featureKey)\s*(?:\.|\])"#
            let featureAssignment = #"^\s*\#(featureKey)\s*(?:\.|=)"#
            let root = lines.prefix { $0.range(of: #"^\s*\[.+\]\s*(#.*)?$"#, options: .regularExpression) == nil }
            if lines.contains(where: { $0.range(of: featureTable, options: .regularExpression) != nil })
                || root.contains(where: { $0.range(of: featureAssignment, options: .regularExpression) != nil }) {
                throw IntegrationError(L("Enable features.hooks manually in \(path) by setting hooks = true under [features].",
                                         "请在 \(path) 的 [features] 表中设置 hooks = true，手动启用 features.hooks。"))
            }
            if lines.last == "" { lines.removeLast() }
            lines += ["", "[features]", "hooks = true", ""]
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The marker lines around our entries, so scripts that rewrite hooks.yaml can keep them.
    static let yamlBegin = "# >>> MacSignal hooks (managed by MacSignal)"
    static let yamlEnd = "# <<< MacSignal hooks"

    /// iCode hooks.yaml: our entries sit between marker comments right under `hooks:`.
    private func writeYAML(add: Bool) throws {
        var lines = try text.components(separatedBy: "\n")
        if let b = lines.firstIndex(of: Integration.yamlBegin), let e = lines[b...].firstIndex(of: Integration.yamlEnd) {
            lines.removeSubrange(b...e)
        }
        func isContent(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        let top = lines.firstIndex { $0.range(of: #"^hooks:\s*(\[\s*\])?\s*(#.*)?$"#, options: .regularExpression) != nil }
        let next = top.flatMap { lines[($0 + 1)...].first(where: isContent) }
        let listItem = next?.range(of: #"^[ \t]*-(?=[ \t]|$)"#, options: .regularExpression)
        // Another top-level `hooks` key (a flow list, `null`, a quoted key, a second one), a flow-style
        // file, or `hooks:` followed by something other than list items: adding ours would break it.
        let otherKey = lines.indices.contains {
            $0 != top && lines[$0].range(of: #"^["']?hooks["']?[ \t]*:"#, options: .regularExpression) != nil
        }
        let flowRoot = lines.contains { $0.hasPrefix("{") || $0.hasPrefix("[") }
        if otherKey || flowRoot || (listItem == nil && next?.first.map({ $0 == " " || $0 == "\t" }) == true) {
            throw IntegrationError(L("Could not edit the hooks list in \(hooksFile). Use a block list or hooks: [].",
                                     "无法编辑 \(hooksFile) 中的 hooks 列表。请使用块列表或 hooks: []。"))
        }
        if add {
            let header: Int
            if let top {
                header = top
                lines[top] = lines[top].replacingOccurrences(of: #"^hooks:[ \t]*\[\s*\]"#, with: "hooks:", options: .regularExpression)
            } else {
                if lines.last == "" { lines.removeLast() }
                lines.append("hooks:")
                header = lines.count - 1
            }
            // Match the indentation of the existing list items.
            let pad = next.flatMap { line in listItem.map { String(line[$0].dropLast()) } } ?? "  "
            var block = [Integration.yamlBegin]
            let names = ["before_turn": "turn", "after_tool_call": "tool", "approval_resolved": "approved",
                         "approval_requested": "approval", "before_tool_call": "ask-user", "after_turn": "done", "session_end": "end"]
            for (event, state, tool) in events {
                block += ["\(pad)- id: \"macsignal-\(names[event]!)\"",
                          "\(pad)  event: \"\(event)\"",
                          "\(pad)  run:",
                          "\(pad)    type: \"command\"",
                          "\(pad)    argv: [\"\(Integration.binary)\", \"hook\", \"\(state)\", \"icode\"]",
                          "\(pad)  execution:",
                          "\(pad)    on_error: \"ignore\"",
                          "\(pad)    timeout_seconds: 5"]
                if let tool { block += ["\(pad)  match:", "\(pad)    tool_name: \"\(tool)\""] }
            }
            block.append(Integration.yamlEnd)
            lines.insert(contentsOf: block, at: header + 1)
        } else if let top, listItem == nil,
                  lines[top].range(of: #"^hooks:\s*(#.*)?$"#, options: .regularExpression) != nil {
            // Adding turned `hooks: []` into `hooks:`; with our entries gone and none of the user's left,
            // a bare `hooks:` is null and iCode refuses the whole file, so put the empty list back.
            lines[top] = lines[top].replacingOccurrences(of: #"^hooks:\s*"#, with: "hooks: [] ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        if lines.last != "" { lines.append("") }
        try backup(hooksFile)
        try FileManager.default.createDirectory(atPath: (hooksFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Integration.save(Data(lines.joined(separator: "\n").utf8), to: hooksFile)
    }
}

struct IntegrationError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
