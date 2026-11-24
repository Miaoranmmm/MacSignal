import AppKit
import ApplicationServices

/// Owns the mouse event filter on the main run loop, shared by Classic Mouse
/// Scrolling and Side Button Desktop Switching. No system preference is changed.
final class MouseEventTap {
    enum StartError: Error {
        case permissionRequired
        case unavailable
    }

    let scrolling = MouseScrolling()
    var reversesScrolling = false
    var switchesDesktops = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Called on the main thread when macOS disables the tap and it cannot be
    /// re-enabled, for example after Accessibility access is revoked.
    var onInterrupted: (() -> Void)?

    var isActive: Bool {
        tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    func start() throws {
        guard AXIsProcessTrusted() else { throw StartError.permissionRequired }
        if isActive { return }
        stop()
        let mask = [CGEventType.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MouseEventTap>.fromOpaque(info).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if AXIsProcessTrusted(), let tap = owner.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                // Re-enabling can fail even with access. Check afterwards, outside
                // the tap callback, so the handler may restart the tap.
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, !owner.isActive else { return }
                    owner.onInterrupted?()
                }
            case .scrollWheel where owner.reversesScrolling:
                owner.scrolling.process(event)
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                // `where` would apply only to the last pattern, so check here.
                if owner.switchesDesktops {
                    return SideButtonDesktopSwitching.handle(type, event: event)
                }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw StartError.unavailable
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        scrolling.reset()
    }

    deinit { stop() }
}
