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
    let transcript = agent == "codex"
        ? codexTranscript(session: session, given: payload["transcript_path"] as? String, search: state == "waiting") : nil
    // With Codex auto review a model answers the permission request, nobody is asked: still working.
    if let transcript, state == "waiting", codexReviewer(transcript: transcript) == "auto_review" {
        state = "working"
    }
    // Codex logs its quota with each model response; pass the latest on with every hook.
    if let transcript { sendQuota(codexQuota(transcript: transcript)) }
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

    var text: String { (try? String(contentsOfFile: hooksFile, encoding: .utf8)) ?? "" }

    /// Our hook commands now in the file (iCode: the lines of our hooks' argv).
    var ourCommands: [String] {
        if id == "icode" {
            return text.components(separatedBy: "\n").filter { $0.contains("argv") && $0.contains("hook") && $0.contains("icode") }
        }
        guard let data = FileManager.default.contents(atPath: hooksFile),
              let hooks = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { ($0 as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] } }
            .compactMap { $0["command"] as? String }.filter(Integration.isOurs)
    }

    var installed: Bool { id == "icode" ? text.contains("macsignal-") : !ourCommands.isEmpty }

    /// Installed, and every hook runs this copy of the app (false after the app moved or an update).
    var current: Bool {
        let cmds = ourCommands
        return installed && cmds.count == events.count
            && cmds.allSatisfy { $0.contains(Integration.binary) && (id == "icode" || $0.hasPrefix(Integration.guardPrefix)) }
    }

    func install() throws {
        try backup()
        switch id {
        case "icode": try writeYAML(add: true)
        default:
            try writeJSON(add: true)
            if id == "codex" { try enableCodexHooks() }
        }
    }

    func uninstall() throws {
        try backup()
        if id == "icode" { try writeYAML(add: false) } else { try writeJSON(add: false) }
    }

    /// Keeps the user's original file once, next to it.
    private func backup() throws {
        let fm = FileManager.default
        let bak = hooksFile + ".bak-macsignal"
        if fm.fileExists(atPath: hooksFile), !fm.fileExists(atPath: bak) {
            // The file's content, also when it is a symlink (copying the link would back up nothing).
            try fm.copyItem(atPath: URL(fileURLWithPath: hooksFile).resolvingSymlinksInPath().path, toPath: bak)
        }
    }

    /// settings.json / hooks.json: {"hooks": {Event: [{"matcher"?, "hooks": [{"type","command"}]}]}}.
    private func writeJSON(add: Bool) throws {
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksFile), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationError(L("\(hooksFile) is not a JSON object", "\(hooksFile) 不是 JSON 对象"))
            }
            root = obj
        }
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
        guard let data = FileManager.default.contents(atPath: hooksFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = root["statusLine"] else { return .none }
        let command = (line as? [String: Any])?["command"] as? String ?? ""
        guard Integration.isOurStatusLine(command) else { return .theirs }
        return .ours(current: command == Integration.statusLineCommand)
    }

    /// Claude Code only: puts our statusLine in (when there is none, or ours runs an old path) or
    /// takes it out (only while it is still ours). Touches no other setting.
    func setStatusLine(_ on: Bool) throws {
        let now = statusLine
        guard on ? (now == .none || now == .ours(current: false)) : now != .none && now != .theirs else { return }
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksFile), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationError(L("\(hooksFile) is not a JSON object", "\(hooksFile) 不是 JSON 对象"))
            }
            root = obj
        }
        try backup()
        root["statusLine"] = on ? ["type": "command", "command": Integration.statusLineCommand] : nil
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Integration.save(data + Data("\n".utf8), to: hooksFile)
    }

    /// Codex runs hooks.json only with `[features] hooks = true` in config.toml.
    private func enableCodexHooks() throws {
        let path = configDir + "/config.toml"
        var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        // The header may carry a comment: `[features] # …`.
        if let header = lines.firstIndex(where: { $0.range(of: #"^\s*\[features\]\s*(#.*)?$"#, options: .regularExpression) != nil }) {
            let end = lines[(header + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.endIndex
            if let i = lines[(header + 1)..<end].firstIndex(where: { $0.range(of: #"^\s*hooks\s*="#, options: .regularExpression) != nil }) {
                // Keeps a comment after the value.
                lines[i] = lines[i].replacingOccurrences(of: #"^\s*hooks\s*=\s*[^#]*"#, with: "hooks = true ",
                                                         options: .regularExpression).trimmingCharacters(in: .whitespaces)
            } else {
                lines.insert("hooks = true", at: header + 1)
            }
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", "[features]", "hooks = true", ""]
        }
        if !FileManager.default.fileExists(atPath: path + ".bak-macsignal"), FileManager.default.fileExists(atPath: path) {
            try FileManager.default.copyItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                                             toPath: path + ".bak-macsignal")
        }
        try Integration.save(Data(lines.joined(separator: "\n").utf8), to: path)
    }

    /// The marker lines around our entries, so scripts that rewrite hooks.yaml can keep them.
    static let yamlBegin = "# >>> MacSignal hooks (managed by MacSignal)"
    static let yamlEnd = "# <<< MacSignal hooks"

    /// iCode hooks.yaml: our entries sit between marker comments right under `hooks:`.
    private func writeYAML(add: Bool) throws {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let b = lines.firstIndex(of: Integration.yamlBegin), let e = lines[b...].firstIndex(of: Integration.yamlEnd) {
            lines.removeSubrange(b...e)
        }
        if add {
            // The key may carry a comment: `hooks: # …`.
            var top = lines.firstIndex(where: { $0.range(of: #"^hooks:\s*(\[\])?\s*(#.*)?$"#, options: .regularExpression) != nil })
            if let t = top, let empty = lines[t].range(of: "[]") { lines[t].removeSubrange(empty) }
            if top == nil {
                if lines.last == "" { lines.removeLast() }
                lines.append("hooks:")
                top = lines.count - 1
            }
            // Match the indentation of the existing list items.
            let next = lines[(top! + 1)...].first {
                let s = $0.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && !s.hasPrefix("#")
            }
            let pad = next.flatMap { l in l.range(of: #"^\s*-"#, options: .regularExpression).map { String(l[$0].dropLast()) } } ?? "  "
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
            lines.insert(contentsOf: block, at: top! + 1)
        } else if let t = lines.firstIndex(where: { $0.range(of: #"^hooks:\s*(#.*)?$"#, options: .regularExpression) != nil }) {
            // Adding turned `hooks: []` into `hooks:`; with our entries gone and none of the user's left,
            // a bare `hooks:` is null and iCode refuses the whole file, so put the empty list back.
            let next = lines[(t + 1)...].first {
                let s = $0.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && !s.hasPrefix("#")
            }
            if next?.range(of: #"^\s*-"#, options: .regularExpression) == nil {
                lines[t] = lines[t].replacingOccurrences(of: #"^hooks:\s*"#, with: "hooks: [] ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        if lines.last != "" { lines.append("") }
        try FileManager.default.createDirectory(atPath: (hooksFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Integration.save(Data(lines.joined(separator: "\n").utf8), to: hooksFile)
    }
}

struct IntegrationError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
