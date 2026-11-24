import AppKit

/// Keeps metric refreshes from repeatedly rearming AppKit's tooltip window.
final class HoverTooltip: NSObject, NSViewToolTipOwner {
    private weak var target: NSView?
    private let containsPointer: (NSView) -> Bool
    private var text: String?
    private var tag: NSView.ToolTipTag?
    private var registeredBounds: NSRect?
    private var trackingArea: NSTrackingArea?
    private var suspended = false

    init(view: NSView, containsPointer: @escaping (NSView) -> Bool = HoverTooltip.pointerIsInside) {
        target = view
        self.containsPointer = containsPointer
        super.init()
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        trackingArea = tracking
        view.addTrackingArea(tracking)
    }

    func update(_ text: String?) {
        self.text = text
        reconcile()
    }

    func suspend() {
        suspended = true
        dismiss()
    }

    func resume() {
        suspended = false
        reconcile()
    }

    func dismiss() {
        if tag != nil {
            target?.removeAllToolTips()
            target?.toolTip = nil
            tag = nil
            registeredBounds = nil
        }
    }

    @objc(mouseEntered:) private func mouseEntered(_ event: NSEvent) { reconcile() }
    @objc(mouseExited:) private func mouseExited(_ event: NSEvent) { dismiss() }

    private func reconcile() {
        guard let target, !suspended, text != nil, containsPointer(target) else {
            dismiss()
            return
        }
        if tag == nil || registeredBounds != target.bounds {
            dismiss()
            registeredBounds = target.bounds
            tag = target.addToolTip(target.bounds, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        // Check the real screen position rather than trusting stale tracking
        // events left behind when a screenshot interrupts menu tracking.
        guard view === target, self.tag == tag, !suspended, containsPointer(view) else { return "" }
        return text ?? ""
    }

    private static func pointerIsInside(_ view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor, let window = view.window,
              window.isVisible, !window.isMiniaturized else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return view.visibleRect.contains(view.convert(point, from: nil))
    }

    deinit {
        dismiss()
        if let trackingArea { target?.removeTrackingArea(trackingArea) }
    }
}
