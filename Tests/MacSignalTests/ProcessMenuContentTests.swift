import AppKit
import XCTest
@testable import MacSignal

final class ProcessMenuContentTests: XCTestCase {
    private final class CountingSampler {
        private let lock = NSLock()
        private var captures = 0
        let failFirst: Bool

        init(failFirst: Bool = false) { self.failFirst = failFirst }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return captures
        }

        func capture() -> [pid_t: ProcessSample]? {
            lock.lock()
            captures += 1
            let sequence = UInt64(captures)
            lock.unlock()
            if failFirst && sequence == 1 { return nil }
            let pid = getpid()
            return [pid: ProcessSample(pid: pid, startTime: 1, cpuTime: sequence * 100,
                                       memoryBytes: sequence * 1_048_576,
                                       sampledAt: sequence * 1_000)]
        }
    }

    private func names(in menu: NSMenu) -> [String] {
        menu.items.compactMap { item in
            ((item.view as? ProcessMenuRow)?.subviews.first as? NSTextField)?.stringValue
        }
    }

    private func values(in menu: NSMenu) -> [String] {
        menu.items.compactMap {
            (($0.view as? ProcessMenuRow)?.subviews.last as? NSTextField)?.stringValue
        }
    }

    private func track(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            // NSMenu uses this mode instead of the default run-loop mode.
            if !RunLoop.main.run(mode: .eventTracking,
                                 before: Date(timeIntervalSinceNow: 0.01)) {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    func testRankingsUpdateWhileMenuIsTracking() {
        XCTAssertTrue(Thread.isMainThread)
        let menu = NSMenu()
        let content = ProcessMenuContent()
        content.sections(cpu: true, memory: true).forEach(menu.addItem)
        content.start()
        defer { content.stop() }

        track { !self.names(in: menu).contains(ProcessMenuContent.sampling) }

        let rows = names(in: menu)
        XCTAssertEqual(rows.count, 6)
        XCTAssertFalse(rows.contains(ProcessMenuContent.sampling))
        XCTAssertFalse(rows.contains(ProcessMenuContent.unavailable))
        XCTAssertFalse(rows.contains("—"))
        let values = values(in: menu)
        XCTAssertTrue(values.prefix(3).allSatisfy { $0.hasSuffix("%") })
        XCTAssertTrue(values.suffix(3).allSatisfy { !$0.isEmpty })
    }

    func testClosingThenReopeningDiscardsStaleResults() {
        XCTAssertTrue(Thread.isMainThread)
        let menu = NSMenu()
        let content = ProcessMenuContent()
        content.sections(cpu: true, memory: true).forEach(menu.addItem)
        content.start()
        track { self.names(in: menu)[3] != ProcessMenuContent.sampling }
        content.stop()
        let closedSnapshot = names(in: menu)
        track(until: { false }, timeout: 0.5)
        XCTAssertEqual(names(in: menu), closedSnapshot)
        XCTAssertEqual(names(in: menu).first, ProcessMenuContent.sampling)

        menu.removeAllItems()
        content.sections(cpu: true, memory: true).forEach(menu.addItem)
        content.start()
        defer { content.stop() }
        track { !self.names(in: menu).contains(ProcessMenuContent.sampling) }
        XCTAssertFalse(names(in: menu).contains(ProcessMenuContent.sampling))
        XCTAssertFalse(names(in: menu).contains(ProcessMenuContent.unavailable))
    }

    func testRepeatedUpdatesFollowMenuLifetimeWithoutBackgroundScanning() {
        let sampler = CountingSampler()
        let menu = NSMenu()
        let content = ProcessMenuContent(capture: sampler.capture)
        content.sections(cpu: true, memory: true).forEach(menu.addItem)
        track(until: { false }, timeout: 0.1)
        XCTAssertEqual(sampler.count, 0)

        content.start(interval: 0.5)
        defer { content.stop() }
        track { self.values(in: menu)[0].hasSuffix("%") }
        let firstMemory = values(in: menu)[3]
        track { self.values(in: menu)[3] != firstMemory }
        XCTAssertGreaterThanOrEqual(sampler.count, 3)
        XCTAssertNotEqual(values(in: menu)[3], firstMemory)

        content.stop()
        let countWhenClosed = sampler.count
        let valuesWhenClosed = values(in: menu)
        track(until: { false }, timeout: 0.65)
        XCTAssertEqual(sampler.count, countWhenClosed)
        XCTAssertEqual(values(in: menu), valuesWhenClosed)
    }

    func testCaptureFailureRecoversWhileMenuStaysOpen() {
        let sampler = CountingSampler(failFirst: true)
        let menu = NSMenu()
        let content = ProcessMenuContent(capture: sampler.capture)
        content.sections(cpu: true, memory: true).forEach(menu.addItem)
        content.start(interval: 0.5)
        defer { content.stop() }
        track { self.names(in: menu)[0] == ProcessMenuContent.unavailable }
        XCTAssertEqual(names(in: menu)[3], ProcessMenuContent.unavailable)
        track { self.values(in: menu)[0].hasSuffix("%") }
        XCTAssertGreaterThanOrEqual(sampler.count, 3)
        XCTAssertTrue(values(in: menu)[0].hasSuffix("%"))
        XCTAssertFalse(names(in: menu).contains(ProcessMenuContent.unavailable))
    }
}
