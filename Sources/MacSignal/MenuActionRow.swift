import AppKit

/// Sizes shared by every row of the menu, so standard items and custom rows match.
enum MenuStyle {
    /// Standard items (NSMenu.font) and action rows.
    static let font = NSFont.menuFont(ofSize: 15)
    /// Section titles: smaller than the items and gray (the items below are in the label color).
    static let headingFont = NSFont.systemFont(ofSize: 13)
    /// Process and session rows.
    static let rowFont = NSFont.menuFont(ofSize: 13)
    /// Height of a standard item at `font`.
    static let itemHeight: CGFloat = 26
    /// Where standard items draw their checkmark and start their title.
    static let checkX: CGFloat = 12
    static let titleX: CGFloat = 31
    static let trailing: CGFloat = 16

    /// A menu (or submenu) in the menu's font.
    static func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = font
        return menu
    }

    /// Rows with views always start their title at `titleX`; standard items (设置, 退出 MacSignal,
    /// notes) start there only while some item is checked, so without this they sit left of the
    /// rows and move when 防止睡眠 is toggled. A checked item of no height keeps the column.
    static func columnKeeper() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 0))
        item.state = .on
        item.isEnabled = false
        return item
    }
}

/// Draws its menu item like a standard one (checkmark column, title, key equivalent, accent
/// highlight) but runs the item's action without closing the menu: standard items always close
/// it, which makes changing several settings tedious. Used for checkboxes, choices and light
/// controls, whose result shows in the menu; rows that take you somewhere else stay standard.
/// Everything shown is read from the item, so updating the item updates the row.
final class MenuActionRow: NSView {
    /// Runs after the item's action, to bring the open menu up to date.
    private let after: () -> Void

    private init(after: @escaping () -> Void) {
        self.after = after
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: MenuStyle.itemHeight))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Makes `item` keep the menu open when chosen; `after` runs once its action has.
    @discardableResult
    static func keepOpen(_ item: NSMenuItem, after: @escaping () -> Void) -> NSMenuItem {
        let row = MenuActionRow(after: after)
        item.view = row
        row.update()
        return item
    }

    private var item: NSMenuItem? { enclosingMenuItem }

    private var shortcut: String {
        guard let item, !item.keyEquivalent.isEmpty else { return "" }
        return "⌘" + item.keyEquivalent.uppercased()
    }

    /// Call after changing the item's title, state or enabled state.
    func update() {
        guard let item else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: MenuStyle.font]
        let titleWidth = (item.title as NSString).size(withAttributes: attributes).width
        let shortcutWidth = shortcut.isEmpty ? 0 : (shortcut as NSString).size(withAttributes: attributes).width + 24
        setFrameSize(NSSize(width: ceil(MenuStyle.titleX + titleWidth + shortcutWidth + MenuStyle.trailing),
                            height: MenuStyle.itemHeight))
        setAccessibilityLabel(item.title)
        setAccessibilityEnabled(item.isEnabled)
        setAccessibilityValue(item.state == .on ? L("Selected", "已选") : item.state == .mixed ? L("Pending", "等待中") : nil)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let highlighted = item.isEnabled && item.isHighlighted
        if highlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = !item.isEnabled ? .disabledControlTextColor
            : highlighted ? .selectedMenuItemTextColor : .labelColor
        let font = MenuStyle.font
        let baseline = (bounds.height - font.capHeight) / 2 + font.descender
        if item.state != .off,
           let mark = NSImage(systemSymbolName: item.state == .on ? "checkmark" : "minus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize - 3, weight: .semibold)) {
            let tinted = NSImage(size: mark.size, flipped: false) { rect in
                mark.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: MenuStyle.checkX, y: ((bounds.height - mark.size.height) / 2).rounded()),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        (item.title as NSString).draw(at: NSPoint(x: MenuStyle.titleX, y: baseline),
                                      withAttributes: [.font: font, .foregroundColor: color])
        if !shortcut.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: highlighted ? color : NSColor.tertiaryLabelColor]
            let width = (shortcut as NSString).size(withAttributes: attributes).width
            (shortcut as NSString).draw(at: NSPoint(x: bounds.maxX - MenuStyle.trailing - width, y: baseline),
                                        withAttributes: attributes)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform()
    }

    override func accessibilityPerformPress() -> Bool { perform() }

    @discardableResult
    private func perform() -> Bool {
        guard let item, item.isEnabled, let action = item.action else { return false }
        NSApp.sendAction(action, to: item.target, from: item)
        after()
        update()
        return true
    }

    /// Copies what a freshly built menu shows into the open one. Items stay the same objects
    /// (the highlight stays under the mouse); a menu whose items changed is refilled instead.
    static func sync(_ live: NSMenu, from fresh: NSMenu) {
        let same = live.items.count == fresh.items.count && zip(live.items, fresh.items).allSatisfy { a, b in
            a.isSeparatorItem == b.isSeparatorItem && a.action == b.action
                && (a.submenu == nil) == (b.submenu == nil) && type(of: a.view) == type(of: b.view)
                && a.representedObject as? NSObject == b.representedObject as? NSObject
                // Headings and notes are told apart by their text.
                && (a.action != nil || a.submenu != nil || a.title == b.title)
        }
        guard same else {
            let items = fresh.items
            fresh.removeAllItems()
            live.removeAllItems()
            items.forEach(live.addItem)
            return
        }
        for (a, b) in zip(live.items, fresh.items) {
            if a.title != b.title { a.title = b.title }
            if a.state != b.state { a.state = b.state }
            if a.isEnabled != b.isEnabled { a.isEnabled = b.isEnabled }
            if a.isHidden != b.isHidden { a.isHidden = b.isHidden }
            if a.image !== b.image { a.image = b.image }
            if a.tag != b.tag { a.tag = b.tag }
            if let a = a.submenu, let b = b.submenu { sync(a, from: b) }
            (a.view as? MenuActionRow)?.update()
        }
    }
}
