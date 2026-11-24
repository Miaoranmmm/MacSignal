import CoreGraphics
import XCTest
@testable import MacSignal

final class SideButtonDesktopSwitchingTests: XCTestCase {
    private typealias Switching = SideButtonDesktopSwitching

    func testBackSwitchesLeftAndForwardSwitchesRightOnPress() {
        XCTAssertEqual(Switching.action(for: .otherMouseDown, button: 3), .switchDesktop(.left))
        XCTAssertEqual(Switching.action(for: .otherMouseDown, button: 4), .switchDesktop(.right))
    }

    func testReleaseAndDragOfSideButtonsAreSwallowedWithoutSwitching() {
        for button: Int64 in [3, 4] {
            XCTAssertEqual(Switching.action(for: .otherMouseUp, button: button), .swallow)
            XCTAssertEqual(Switching.action(for: .otherMouseDragged, button: button), .swallow)
        }
    }

    func testOtherButtonsPassUnchanged() {
        for button: Int64 in [0, 1, 2, 5, 6] {
            for type in [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged] {
                XCTAssertEqual(Switching.action(for: type, button: button), .pass, "\(button) \(type)")
            }
        }
    }

    func testKeyEventsMatchTheSystemDesktopShortcuts() {
        for (direction, key) in [(Switching.Direction.left, Int64(123)), (.right, 124)] {
            let events = Switching.keyEvents(for: direction)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            for event in events {
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), key)
                XCTAssertTrue(event.flags.contains(.maskControl))
                XCTAssertTrue(event.flags.contains(.maskSecondaryFn))
                XCTAssertFalse(event.flags.contains(.maskCommand))
                XCTAssertFalse(event.flags.contains(.maskAlternate))
                XCTAssertFalse(event.flags.contains(.maskShift))
            }
        }
    }
}
