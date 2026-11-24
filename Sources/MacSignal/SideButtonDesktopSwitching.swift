import AppKit

/// Press the back or forward side button to switch desktops, the same as
/// Control-Left Arrow / Control-Right Arrow. While on, the side buttons no
/// longer go back or forward in apps.
enum SideButtonDesktopSwitching {
    enum Direction: Equatable {
        case left, right
    }

    enum Action: Equatable {
        /// Deliver the event unchanged.
        case pass
        /// Swallow the event, so apps do not see the side button.
        case swallow
        /// Swallow the event and switch one desktop.
        case switchDesktop(Direction)
    }

    /// Back switches left and forward switches right. Quartz numbers mouse
    /// buttons from 0 (left button), so back is 3 and forward is 4.
    static func action(for type: CGEventType, button: Int64) -> Action {
        let direction: Direction
        switch button {
        case 3: direction = .left
        case 4: direction = .right
        default: return .pass
        }
        // Switch on press; the release and any drag in between are swallowed too.
        return type == .otherMouseDown ? .switchDesktop(direction) : .swallow
    }

    static func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch action(for: type, button: event.getIntegerValueField(.mouseEventButtonNumber)) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .switchDesktop(let direction):
            for key in keyEvents(for: direction) {
                key.post(tap: .cghidEventTap)
            }
            return nil
        }
    }

    /// Key down and up for the system shortcut that moves one desktop over.
    static func keyEvents(for direction: Direction) -> [CGEvent] {
        let key: CGKeyCode = direction == .left ? 123 : 124  // Left and Right Arrow
        return [true, false].compactMap { down in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            // Arrow keys carry the Fn flag; the shortcut is stored as Control+Fn+arrow.
            event?.flags = [.maskControl, .maskSecondaryFn]
            return event
        }
    }
}
