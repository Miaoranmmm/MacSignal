import AppKit

/// The icon in front of each session in the menu, telling apart sessions of different agents in
/// the same project: Claude Code and Codex show their app's icon, iCode the 「iC」 of its startup
/// logo. An agent whose app isn't installed gets a blank one, which keeps the rows aligned.
enum AgentIcons {
    static let size = NSSize(width: 16, height: 16)

    /// The apps whose icons stand for their agents.
    private static let apps = ["claude": "com.anthropic.claudefordesktop", "codex": "com.openai.codex"]
    private static var cache: [String: NSImage] = [:]

    static func image(for agent: String) -> NSImage {
        if let image = cache[agent] { return image }
        let image = agent == "icode" ? icode() : appIcon(apps[agent]) ?? NSImage(size: size)
        image.accessibilityDescription = agentNames.first { $0.id == agent }?.name ?? agent
        cache[agent] = image
        return image
    }

    private static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = size
        return icon
    }

    /// The 「iC」 of iCode's startup logo (src/chrys/app/tui/util/logo.py), one cell per half block.
    private static let mark = [
        "...#...####.",
        "...########.",
        "....######..",
        ".##..##.....",
        ".....##.....",
        ".##..##.....",
        ".##..##.....",
        ".##..##.....",
        ".##..##.....",
        ".##..######.",
        "###...######",
    ]

    /// The mark in white on iCode's primary purple, in the shape and footprint of an app icon in a
    /// menu (a rounded square 14 points wide).
    private static func icode() -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            let body = rect.insetBy(dx: rect.width / 16, dy: rect.height / 16)
            NSColor(srgbRed: 0xAF / 255, green: 0x87 / 255, blue: 0xFF / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).fill()
            let cell = body.width * 0.66 / 12
            let x0 = body.midX - cell * 6, y0 = body.midY - cell * 5.5
            // One path, so neighboring cells join without seams.
            let path = NSBezierPath()
            for (y, row) in mark.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    path.appendRect(NSRect(x: x0 + CGFloat(x) * cell, y: y0 + CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            NSColor.white.setFill()
            path.fill()
            return true
        }
    }
}
