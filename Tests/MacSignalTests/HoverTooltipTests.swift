import AppKit
import XCTest
@testable import MacSignal

final class HoverTooltipTests: XCTestCase {
    private final class TooltipView: NSView {
        var registrations = 0
        var removals = 0
        var lastTag: NSView.ToolTipTag = 0

        override func addToolTip(_ rect: NSRect, owner: Any,
                                 userData: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
            registrations += 1
            lastTag += 1
            return lastTag
        }

        override func removeAllToolTips() { removals += 1 }
    }

    private func tooltipText(_ tooltip: HoverTooltip, view: TooltipView) -> String {
        tooltip.view(view, stringForToolTip: view.lastTag, point: .zero, userData: nil)
    }

    func testMetricRefreshUpdatesContentWithoutRearmingTooltip() {
        let view = TooltipView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let tooltip = HoverTooltip(view: view, containsPointer: { _ in true })
        tooltip.update("First reading")
        for index in 0..<20 { tooltip.update("Reading \(index)") }
        XCTAssertEqual(view.registrations, 1)
        XCTAssertEqual(view.removals, 0)
        XCTAssertEqual(tooltipText(tooltip, view: view), "Reading 19")

        view.setFrameSize(NSSize(width: 80, height: 22))
        tooltip.update("After layout change")
        XCTAssertEqual(view.registrations, 2)
        XCTAssertEqual(view.removals, 1)
    }

    func testLostMouseExitCannotReopenTooltipOutsideView() {
        var inside = true
        let view = TooltipView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let tooltip = HoverTooltip(view: view, containsPointer: { _ in inside })
        tooltip.update("Reading")
        inside = false
        // Simulate screenshot capture swallowing mouseExited before AppKit
        // requests a tooltip at an unrelated cursor location.
        XCTAssertEqual(tooltipText(tooltip, view: view), "")
        for _ in 0..<20 { tooltip.update("Updated reading") }
        XCTAssertEqual(view.registrations, 1)
        XCTAssertEqual(view.removals, 1)
    }

    func testMenuTrackingAndCloseDismissTooltipUntilValidHover() {
        var inside = true
        let view = TooltipView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let tooltip = HoverTooltip(view: view, containsPointer: { _ in inside })
        tooltip.update("Reading")
        tooltip.suspend()
        tooltip.update("During menu tracking")
        XCTAssertEqual(tooltipText(tooltip, view: view), "")
        XCTAssertEqual(view.registrations, 1)
        inside = false
        tooltip.resume()
        XCTAssertEqual(view.registrations, 1)
        inside = true
        tooltip.update("New hover")
        XCTAssertEqual(tooltipText(tooltip, view: view), "New hover")
        XCTAssertEqual(view.registrations, 2)
        tooltip.dismiss()
        XCTAssertEqual(tooltipText(tooltip, view: view), "")
    }
}
