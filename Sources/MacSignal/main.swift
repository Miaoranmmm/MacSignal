import AppKit
import MacSignalCore

// `MacSignal hook <state> [agent]`: run by the agents' hooks; reports to the running app and exits.
// Checked first, so it neither opens the menu bar item nor stops at the single-instance check.
if CommandLine.arguments.dropFirst().first == "hook" {
    runHook(Array(CommandLine.arguments.dropFirst(2)))
}
// `MacSignal statusline`: Claude Code's statusLine command, for its quota (prints nothing).
if CommandLine.arguments.dropFirst().first == "statusline" {
    runStatusLine()
}

// Read-only diagnostics and a deterministic render for verification, without
// creating windows or registering a menu bar item.
if CommandLine.arguments.contains("--diagnose") {
    let sampler = SystemSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    var snapshot = sampler.sample()
    // CPU tick counters can stay frozen for about a second.
    for _ in 0..<10 where snapshot.cpu == nil {
        Thread.sleep(forTimeInterval: 0.2)
        snapshot = sampler.sample()
    }
    print(Readings(snapshot: snapshot).tooltipLines().joined(separator: "\n"))
    guard snapshot.cpu != nil, snapshot.memory != nil, snapshot.upload != nil else { exit(1) }
    exit(0)
}

// --render-preview <file> [--modules network,cpu,…] [--agents W,K,D] [--quota codex=26,claude=62] [--numbers]
// [--light] [--sleep]: draws the menu bar item with the same code. Modules default to the checked
// ones; session counts (waiting, working, unread done) hook up an agent and light the lamps.
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   index + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let arguments = CommandLine.arguments
    func value(_ flag: String) -> [String]? {
        arguments.firstIndex(of: flag).flatMap { i in i + 1 < arguments.count ? arguments[i + 1].components(separatedBy: ",") : nil }
    }
    var readings = Readings(snapshot: MetricsSnapshot(
        cpu: 0.24, memory: 0.67, upload: 4 * 1000, download: 25 * 1000,
        power: PowerReading(watts: 11.4, level: 0.86, pluggedIn: false, charging: false, minutesLeft: 300)))
    readings.powerAvailable = true
    readings.lamps = value("--agents").map { $0.map { (Int($0) ?? 0) > 0 } }
    for pair in value("--quota") ?? [] {
        let parts = pair.components(separatedBy: "=")
        guard parts.count == 2, let used = Double(parts[1]) else { continue }
        readings.quotaAgents.append(parts[0])
        readings.quota[parts[0]] = AgentQuota(agent: parts[0], windows: [.init(used: used, minutes: 10080,
                                              resets: Date().timeIntervalSince1970 + 86400)], captured: Date().timeIntervalSince1970)
    }
    let shown = value("--modules").map { names in StatusModule.allCases.filter { names.contains($0.rawValue) } }
        ?? StatusModule.allCases.filter(\.isChecked)
    let cells = shown.filter { $0.isAvailable(readings) }.flatMap { $0.cells(readings) }
    let dark = !arguments.contains("--light")
    let rendered = MenuBarRenderer.image(cells, preventingSleep: arguments.contains("--sleep"),
                                         style: MenuBarRenderer.Style(showNumbers: arguments.contains("--numbers"), dark: dark))
    let size = rendered.size
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                  pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedWhite: dark ? 0.12 : 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    rendered.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

// Opening another copy should not add duplicate monitoring items.
if let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}

let app = NSApplication.shared
// Retain the delegate for the lifetime of the application.
let delegate = AppDelegate()
app.delegate = delegate
app.run()
