import AppKit
import MacSignalCore

/// Draws the menu bar item from cells. Every cell has two rows on shared lines: a small caption on
/// top and the reading below (network: upload on top, download below); the traffic light is a
/// vertical housing across both. Only the lamps have color. A cell is as wide as its widest
/// possible reading, so readings never move the icons beside it.
enum MenuBarRenderer {
    enum Cell: Equatable {
        /// Caption over a value. `scaled` readings (0–100) show a bar instead without 显示数字;
        /// `widest` is the longest value it can show.
        case reading(caption: String, value: String, fraction: Double?, scaled: Bool, widest: String)
        /// ↑ upload over ↓ download, bytes per second.
        case network(up: Double?, down: Double?)
        /// Red, yellow, green from the top; each lit by its own sessions.
        case lamps(lit: [Bool], redDimmed: Bool)
    }

    struct Style: Equatable {
        var showNumbers = false
        /// The menu bar is dark (white drawing) or light (black drawing).
        var dark = true
    }

    static let height: CGFloat = 22
    private static let top: CGFloat = 16, bottom: CGFloat = 6
    private static let gap: CGFloat = 7
    private static let captionFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let captionKern: CGFloat = 0.3
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let uploadFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    private static let unitFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let lampDiameter: CGFloat = 5
    private static let housing = NSSize(width: 8, height: 19)
    /// Room on the left for the 防止睡眠 bar, kept when it is off so turning it on moves nothing.
    private static let sleepLead: CGFloat = 5
    /// The width of the app's icon, drawn when nothing else is shown.
    private static let iconWidth: CGFloat = 18

    /// Lamp colors for a dark and a light menu bar: red, yellow, green (the system colors).
    static func lampColors(dark: Bool) -> [NSColor] {
        (dark ? [0xFF453A, 0xFFD60A, 0x30D158] : [0xFF3B30, 0xFFCC00, 0x34C759]).map(color)
    }

    static func width(_ cells: [Cell]) -> CGFloat {
        guard !cells.isEmpty else { return sleepLead - 1 + iconWidth }
        let widths = cells.map(cellWidth)
        return ceil(sleepLead + widths.reduce(0, +) + gap * CGFloat(widths.count - 1) + 1)
    }

    private static func cellWidth(_ cell: Cell) -> CGFloat {
        switch cell {
        case let .reading(caption, _, _, _, widest):
            return max(textWidth(widest, valueFont), textWidth(caption, captionFont, kern: captionKern)) + 2
        case .network:
            return 6 + textWidth("999", valueFont) + 0.5 + unitWidth
        case .lamps:
            return housing.width
        }
    }

    private static var unitWidth: CGFloat { "BKMGTPE".map { textWidth(String($0), unitFont) }.max()! }

    static func image(_ cells: [Cell], preventingSleep: Bool = false, style: Style = Style()) -> NSImage {
        let size = NSSize(width: width(cells), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The same image can be drawn on displays with different backing scales.
            let scale = hypot(context.ctm.a, context.ctm.b)
            draw(cells, preventingSleep: preventingSleep, style: style, standardResolution: scale < 1.5)
            return true
        }
        // A template image would lose the lamp colors; the colors follow the menu bar instead.
        image.isTemplate = false
        return image
    }

    private static func draw(_ cells: [Cell], preventingSleep: Bool, style: Style, standardResolution: Bool) {
        let ink = style.dark ? NSColor.white : NSColor.black
        if preventingSleep {
            color(0xFFB020).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
        }
        guard !cells.isEmpty else {
            drawIcon(ink)
            return
        }
        var x = sleepLead
        for cell in cells {
            let w = cellWidth(cell)
            switch cell {
            case let .reading(caption, value, fraction, scaled, _):
                drawText(caption, x: x, width: w, centerY: top, font: captionFont, color: ink.withAlphaComponent(0.55),
                         alignment: .center, kern: captionKern)
                if scaled, !style.showNumbers {
                    drawGauge(fraction, in: NSRect(x: x + 1.5, y: bottom - 2, width: w - 3, height: 4),
                              color: ink, pixelAligned: standardResolution)
                } else {
                    drawText(value, x: x, width: w, centerY: bottom, font: valueFont, color: ink, alignment: .center)
                }
            case let .network(up, down):
                let dim = ink.withAlphaComponent(0.55)
                drawArrow(down: false, x: x, centerY: top, width: 4, height: 5.5, line: 1, color: dim)
                let (upNumber, upUnit) = shortRate(up)
                drawText(upNumber + upUnit, x: x + 6, width: w - 6, centerY: top, font: uploadFont, color: dim,
                         alignment: .right)
                drawArrow(down: true, x: x, centerY: bottom, width: 4.5, height: 6.5, line: 1.1,
                          color: ink.withAlphaComponent(0.85))
                let (number, unit) = shortRate(down)
                drawText(unit, x: x + w - unitWidth, width: unitWidth, centerY: bottom, font: unitFont,
                         color: ink.withAlphaComponent(0.85))
                drawText(number, x: x + 6, width: w - 6 - unitWidth - 0.5, centerY: bottom, font: valueFont,
                         color: ink, alignment: .right)
            case let .lamps(lit, redDimmed):
                ink.withAlphaComponent(style.dark ? 0.15 : 0.10).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 1.5, width: housing.width, height: housing.height),
                             xRadius: 4, yRadius: 4).fill()
                let colors = lampColors(dark: style.dark)
                for i in 0..<3 {
                    let on = i < lit.count && lit[i] && !(i == 0 && redDimmed)
                    colors[i].withAlphaComponent(on ? 1 : 0.22).setFill()
                    let center = NSPoint(x: x + housing.width / 2, y: 16 - CGFloat(i) * 5.5)
                    NSBezierPath(ovalIn: NSRect(x: center.x - lampDiameter / 2, y: center.y - lampDiameter / 2,
                                                width: lampDiameter, height: lampDiameter)).fill()
                }
            }
            x += w + gap
        }
    }

    /// Nothing to show: the app's icon, so the menu can still be opened.
    private static func drawIcon(_ ink: NSColor) {
        // gauge.with.dots.needle.50percent is new in macOS 14.
        guard let symbol = (NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "MacSignal")
                            ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "MacSignal"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(at: NSPoint(x: (sleepLead - 1 + (iconWidth - symbol.size.width) / 2).rounded(),
                                y: ((height - symbol.size.height) / 2).rounded()),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// 325 KB/s → ("325", "K"); "—" before the first reading.
    static func shortRate(_ value: Double?) -> (String, String) {
        guard let value else { return ("—", "") }
        let parts = RateFormatter.string(bytesPerSecond: value).split(separator: " ", maxSplits: 1)
        return (String(parts[0]), parts.count > 1 ? String(parts[1].prefix(1)) : "")
    }

    /// "24%"; "—" without a reading.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    private static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static func textWidth(_ text: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font, .kern: kern]).width
    }

    /// Draws text with its cap height centered on `centerY`, aligned within [x, x + width]. The
    /// baseline sits on a whole point, so the text is as sharp on a 1x display as on a 2x one.
    private static func drawText(_ text: String, x: CGFloat, width: CGFloat, centerY: CGFloat, font: NSFont,
                                 color: NSColor, alignment: NSTextAlignment = .left, kern: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let textWidth = (text as NSString).size(withAttributes: attributes).width
        let left = alignment == .right ? x + width - textWidth : alignment == .center ? x + (width - textWidth) / 2 : x
        let baseline = (centerY - font.capHeight / 2).rounded()
        (text as NSString).draw(at: NSPoint(x: left, y: baseline + font.descender), withAttributes: attributes)
    }

    private static func drawArrow(down: Bool, x: CGFloat, centerY: CGFloat, width w: CGFloat, height h: CGFloat,
                                  line: CGFloat, color: NSColor) {
        let cx = x + w / 2, top = centerY + h / 2, bottom = centerY - h / 2
        let tip = down ? bottom : top
        let wing = down ? bottom + w / 2 : top - w / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx, y: top))
        path.line(to: NSPoint(x: cx, y: bottom))
        path.move(to: NSPoint(x: x + 0.4, y: wing))
        path.line(to: NSPoint(x: cx, y: tip))
        path.line(to: NSPoint(x: x + w - 0.4, y: wing))
        path.lineWidth = line
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// A rounded track, filled from the left; an empty track without a reading.
    private static func drawGauge(_ value: Double?, in track: NSRect, color: NSColor, pixelAligned: Bool) {
        // On a 1x display the track and the end of the fill sit on pixel edges.
        let rect = pixelAligned ? NSRect(x: track.minX.rounded(), y: track.minY.rounded(),
                                         width: track.width.rounded(), height: track.height.rounded()) : track
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color.withAlphaComponent(0.25).setFill()
        shape.fill()
        guard let value, value.isFinite, value > 0 else { return }
        var width = rect.width * min(1, value)
        if pixelAligned { width = max(1, width.rounded()) }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        color.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
