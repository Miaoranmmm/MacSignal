import AppKit

/// The menu bar item: its image, tooltip and appearance. Redraws only when what it shows changed.
final class StatusController {
    private let item: NSStatusItem
    let tooltip: HoverTooltip?
    private var appearanceObservation: NSKeyValueObservation?
    private var drawn: Drawn?

    private struct Drawn: Equatable {
        var cells: [MenuBarRenderer.Cell]
        var preventingSleep: Bool
        var style: MenuBarRenderer.Style
    }

    var button: NSStatusBarButton? { item.button }

    /// The item calls `action` on `target` when clicked, and `appearanceChanged` when the menu bar
    /// switches between dark and light.
    init(target: AnyObject, action: Selector, appearanceChanged: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: MenuBarRenderer.width([]))
        tooltip = item.button.map { HoverTooltip(view: $0) }
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(L("MacSignal: network, CPU, memory, power, AI usage and agent status",
                                       "MacSignal：网速、CPU、内存、功耗、AI 额度和 agent 状态"))
        // The drawing follows the menu bar between dark and light.
        appearanceObservation = button.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async(execute: appearanceChanged)
        }
    }

    func update(cells: [MenuBarRenderer.Cell], preventingSleep: Bool, showNumbers: Bool, tooltip text: String) {
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let input = Drawn(cells: cells, preventingSleep: preventingSleep,
                          style: MenuBarRenderer.Style(showNumbers: showNumbers, dark: dark))
        if input != drawn {
            drawn = input
            let image = MenuBarRenderer.image(cells, preventingSleep: preventingSleep, style: input.style)
            if item.length != image.size.width { item.length = image.size.width }
            button.image = image
        }
        tooltip?.update(text)
        button.setAccessibilityValue(text)
    }
}
