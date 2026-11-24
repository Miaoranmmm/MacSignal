// The hooks' socket: session states and quotas reported by the agents' hooks.
import Foundation

let socketPath = NSHomeDirectory() + "/.macsignal.sock"
/// Settable so tests don't write to the real log.
var agentLogPath = NSHomeDirectory() + "/Library/Logs/MacSignal.log"

func agentLog(_ s: String) {
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8)
    if !FileManager.default.fileExists(atPath: agentLogPath) {
        FileManager.default.createFile(atPath: agentLogPath, contents: nil)
    }
    guard let fh = FileHandle(forWritingAtPath: agentLogPath) else { return }
    fh.seekToEndOfFile()
    fh.write(line)
    fh.closeFile()
}

func makeSockaddr() -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        socketPath.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
    }
    return addr
}

/// Receives the hooks' reports on ~/.macsignal.sock while at least one agent is hooked up.
final class AgentReceiver {
    let sessions = AgentSessions()
    var hookedAgents: Set<String> = [] {
        didSet { sessions.entries = sessions.entries.filter { hookedAgents.contains($0.value.agent) } }
    }
    /// Called when the sessions change.
    var onSessionsChange: (() -> Void)?
    /// A "Q:" message's JSON (see AgentQuota).
    var onQuota: ((String) -> Void)?
    /// A session just finished (after onSessionsChange).
    var onSessionFinished: ((String) -> Void)?
    /// At least one agent is hooked up: listen for reports.
    private(set) var active = false
    private var socketSource: DispatchSourceRead?
    private var pruneTimer: Timer?

    /// Starts or stops listening with the agents; stopping also forgets the sessions.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            listen()
            // Also notices sessions whose agent exited (see AgentSessions.prune).
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.applySessions() }
            RunLoop.main.add(timer, forMode: .common)
            pruneTimer = timer
        } else {
            agentLog("no agent hooked up: no longer listening")
            socketSource?.cancel()
            socketSource = nil
            pruneTimer?.invalidate()
            pruneTimer = nil
            sessions.entries.removeAll()
        }
        onSessionsChange?()
    }

    private func listen() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        var addr = makeSockaddr()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { Darwin.bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), len) }) == 0 else {
            agentLog("bind \(socketPath) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                self?.handle(String(line))
            }
        }
        src.setCancelHandler {
            close(fd)
            unlink(socketPath)
        }
        src.resume()
        socketSource = src
        agentLog("listening on \(socketPath)")
    }

    /// One report: an agent's quota (`MacSignal hook` for Codex, `MacSignal statusline` for Claude
    /// Code), or a session's state.
    func handle(_ cmd: String) {
        if cmd.hasPrefix("Q:") {
            onQuota?(String(cmd.dropFirst(2)))
        } else if cmd.hasPrefix("J:") {
            let doneBefore = Set(sessions.entries.filter { $0.value.state == .done }.keys)
            guard sessions.apply(cmd, hookedAgents: hookedAgents) else { return }
            applySessions()
            for (id, e) in sessions.entries where e.state == .done && !doneBefore.contains(id) {
                onSessionFinished?(id)
            }
        }
    }

    func applySessions() {
        sessions.prune()
        onSessionsChange?()
    }
}
