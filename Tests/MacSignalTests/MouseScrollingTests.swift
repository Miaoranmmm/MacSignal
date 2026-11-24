import AppKit
import CoreGraphics
import XCTest
@testable import MacSignal

final class MouseScrollingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The texts below are the Chinese ones; LanguageTests covers English.
        Language.current = .chinese
    }

    func testOnlyMouseScrollingIsAdjustedForEitherSystemSetting() {
        XCTAssertTrue(MouseScrolling.shouldReverse(device: .mouse, natural: true))
        XCTAssertFalse(MouseScrolling.shouldReverse(device: .mouse, natural: false))
        XCTAssertFalse(MouseScrolling.shouldReverse(device: .trackpad, natural: true))
        XCTAssertFalse(MouseScrolling.shouldReverse(device: .trackpad, natural: false))
    }

    func testVerticalDeltasReverseWithoutChangingHorizontalOrMomentum() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 2, wheel1: 4, wheel2: 7, wheel3: 0))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.5)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let horizontalPoints = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        MouseScrolling.reverseVertical(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -lines)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -points)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -fixed)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), horizontal)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), horizontalPoints)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 2)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 1)
    }

    func testIdentifiedSendersAreResolvedOnce() {
        var cache = SenderDeviceCache()
        var lookups = 0
        let resolve: (UInt64) -> MouseScrolling.Device? = { _ in lookups += 1; return .mouse }
        XCTAssertEqual(cache.device(for: 7, now: 0, resolve: resolve), .mouse)
        XCTAssertEqual(cache.device(for: 7, now: 100, resolve: resolve), .mouse)
        XCTAssertEqual(lookups, 1)
    }

    func testUnidentifiedSendersAreRetriedOnlyAfterDelay() {
        var cache = SenderDeviceCache()
        var lookups = 0
        var result: MouseScrolling.Device?
        let resolve: (UInt64) -> MouseScrolling.Device? = { _ in lookups += 1; return result }
        let delay = SenderDeviceCache.unidentifiedRetryDelay
        XCTAssertNil(cache.device(for: 9, now: 10, resolve: resolve))
        // Every scroll event inside the window reuses the negative result.
        for step in 1...50 {
            XCTAssertNil(cache.device(for: 9, now: 10 + delay * Double(step) / 51, resolve: resolve))
        }
        XCTAssertEqual(lookups, 1)
        // A device that finishes registering later is still identified.
        result = .trackpad
        XCTAssertEqual(cache.device(for: 9, now: 10 + delay, resolve: resolve), .trackpad)
        XCTAssertEqual(cache.device(for: 9, now: 10 + delay * 3, resolve: resolve), .trackpad)
        XCTAssertEqual(lookups, 2)
    }

    func testIdentifiedAndUnidentifiedSendersShareOneCapacity() {
        var cache = SenderDeviceCache()
        var lookups = 0
        let resolve: (UInt64) -> MouseScrolling.Device? = { sender in
            lookups += 1
            return sender.isMultiple(of: 2) ? .mouse : nil
        }
        let capacity = UInt64(SenderDeviceCache.capacity)
        for sender in 0..<capacity {
            _ = cache.device(for: sender, now: 0, resolve: resolve)
        }
        XCTAssertEqual(cache.count, SenderDeviceCache.capacity)
        // At capacity, every sender is still answered from the cache.
        for sender in 0..<capacity {
            _ = cache.device(for: sender, now: 1, resolve: resolve)
        }
        XCTAssertEqual(lookups, SenderDeviceCache.capacity)
        // Refreshing an expired unidentified entry does not evict others.
        _ = cache.device(for: 1, now: 1 + SenderDeviceCache.unidentifiedRetryDelay, resolve: resolve)
        XCTAssertEqual(cache.count, SenderDeviceCache.capacity)
        _ = cache.device(for: 0, now: 1, resolve: resolve)
        XCTAssertEqual(lookups, SenderDeviceCache.capacity + 1)
        // A new sender beyond capacity evicts the earlier ones.
        _ = cache.device(for: capacity, now: 1, resolve: resolve)
        XCTAssertLessThanOrEqual(cache.count, SenderDeviceCache.capacity)
        _ = cache.device(for: 0, now: 1, resolve: resolve)
        XCTAssertEqual(lookups, SenderDeviceCache.capacity + 3)
        for sender in capacity..<capacity * 4 {
            _ = cache.device(for: sender, now: 2, resolve: resolve)
            XCTAssertLessThanOrEqual(cache.count, SenderDeviceCache.capacity)
        }
    }

    func testPendingStatusDoesNotWidenMenu() {
        let target = NSObject()
        func width(enabled: Set<MouseOption>, pending: MouseTapPending?) -> CGFloat {
            let menu = NSMenu()
            let row = NSMenuItem()
            row.view = ProcessMenuRow()
            menu.addItem(row)
            for item in AppDelegate.mouseOptionItems(enabled: enabled, pending: pending, target: target) {
                menu.addItem(item)
            }
            return menu.size.width
        }
        let baseline = width(enabled: [], pending: nil)
        XCTAssertEqual(baseline, ProcessMenuRow.width, accuracy: 1)
        for pending in [MouseTapPending.needsAccess, .unavailable] {
            XCTAssertEqual(width(enabled: Set(MouseOption.allCases), pending: pending), baseline, "\(pending)")
        }
    }

    func testPendingOptionsShowMixedStateAndOneSeparateStatus() {
        let target = NSObject()
        let titles = ["传统滚动", "侧键切换桌面"]
        let running = AppDelegate.mouseOptionItems(enabled: [.classicScrolling], pending: nil, target: target)
        XCTAssertEqual(running.map(\.title), titles)
        XCTAssertEqual(running.map(\.state), [.on, .off])
        let off = AppDelegate.mouseOptionItems(enabled: [], pending: .needsAccess, target: target)
        XCTAssertEqual(off.map(\.state), [.off, .off])
        let waiting = AppDelegate.mouseOptionItems(enabled: Set(MouseOption.allCases), pending: .needsAccess,
                                                   target: target)
        XCTAssertEqual(waiting.map(\.title), titles + ["需要辅助功能权限", "打开辅助功能设置…"])
        XCTAssertEqual(waiting.prefix(2).map(\.state), [.mixed, .mixed])
        XCTAssertFalse(waiting[2].isEnabled)
        let switchingOnly = AppDelegate.mouseOptionItems(enabled: [.desktopSwitching], pending: .unavailable,
                                                         target: target)
        XCTAssertEqual(switchingOnly.map(\.title), titles + ["暂不可用，正在重试"])
        XCTAssertEqual(switchingOnly.prefix(2).map(\.state), [.off, .mixed])
    }

    func testOptionsKeepTheirSavedSettingsKeys() {
        // The scrolling key predates the second option; renaming it would reset the choice.
        XCTAssertEqual(MouseOption.classicScrolling.defaultsKey, "classicMouseScrolling")
        XCTAssertEqual(MouseOption.desktopSwitching.defaultsKey, "sideButtonDesktopSwitching")
    }
}
