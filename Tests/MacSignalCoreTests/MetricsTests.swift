import Darwin
import XCTest
@testable import MacSignalCore

final class MetricsTests: XCTestCase {
    func testRateUnitsAndRoundingBoundaries() {
        let cases: [(Double, String)] = [
            (0, "0 B/s"), (-1, "0 B/s"), (.nan, "0 B/s"), (.infinity, "0 B/s"),
            (512, "512 B/s"), (1000, "1 KB/s"), (25 * 1000, "25 KB/s"),
            (1.5 * pow(1000, 2), "1.5 MB/s"), (pow(1000, 3), "1.0 GB/s"),
            (12 * pow(1000, 3), "12 GB/s"), (pow(1000, 4), "1.0 TB/s"),
            (pow(1000, 5), "1.0 PB/s"), (pow(1000, 6), "1.0 EB/s"),
            (999.49, "999 B/s"), (999.5, "1 KB/s"),
            (999_499, "999 KB/s"), (999_500, "1.0 MB/s"),
            (9_950_000, "10 MB/s"), (1e100, "999 EB/s")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(RateFormatter.string(bytesPerSecond: input), expected, "rate=\(input)")
        }
        for unit in 0...6 {
            for value in [1.0, 9.94, 9.95, 99.9, 999.49, 999.5, 1000, 1023] {
                let text = RateFormatter.string(bytesPerSecond: value * pow(1000, Double(unit)))
                let number = text.split(separator: " ")[0]
                XCTAssertLessThanOrEqual(number.filter(\.isNumber).count, 3, text)
            }
        }
    }

    func testRatesUseActualElapsedTimeAnd64BitCounters() {
        let baseline: UInt64 = 1 << 40
        let old = ["en0": InterfaceCounters(received: baseline, sent: baseline)]
        let new = ["en0": InterfaceCounters(received: baseline + 6000, sent: baseline + 3000)]
        let rate = NetworkRates.between(previous: old, current: new, elapsed: 1.5)
        XCTAssertEqual(rate.download, 4000)
        XCTAssertEqual(rate.upload, 2000)
    }

    func testReconnectResetAndRemovalDoNotProduceSpikes() {
        let old = ["en0": InterfaceCounters(received: 1000, sent: 2000),
                   "en1": InterfaceCounters(received: 9000, sent: 9000)]
        let new = ["en0": InterfaceCounters(received: 50, sent: 2100),
                   "en2": InterfaceCounters(received: 999_999_999, sent: 999_999_999)]
        let rate = NetworkRates.between(previous: old, current: new, elapsed: 1)
        XCTAssertEqual(rate.download, 0)
        XCTAssertEqual(rate.upload, 100)
        XCTAssertEqual(NetworkRates.between(previous: old, current: new, elapsed: 0).download, 0)
    }

    func testSimultaneousPhysicalInterfacesAreSummed() {
        let old = ["en0": InterfaceCounters(received: 100, sent: 100),
                   "en1": InterfaceCounters(received: 100, sent: 100)]
        let new = ["en0": InterfaceCounters(received: 300, sent: 200),
                   "en1": InterfaceCounters(received: 400, sent: 200)]
        let rate = NetworkRates.between(previous: old, current: new, elapsed: 2)
        XCTAssertEqual(rate.download, 250)
        XCTAssertEqual(rate.upload, 100)
    }

    func testCPUUsesIntervalRatherThanLifetimeAverageAndHandlesWrap() {
        let old = CPUCounters(user: 1000, system: 1000, idle: 1000, nice: 0)
        let new = CPUCounters(user: 1010, system: 1010, idle: 1080, nice: 0)
        XCTAssertEqual(new.usage(since: old)!, 0.2, accuracy: 0.0001)
        XCTAssertNil(old.usage(since: old))
        let beforeWrap = CPUCounters(user: UInt32.max - 4, system: 0, idle: 100, nice: 0)
        let afterWrap = CPUCounters(user: 5, system: 0, idle: 110, nice: 0)
        XCTAssertEqual(afterWrap.usage(since: beforeWrap), 0.5)
    }

    func testUnsupportedSavedRefreshIntervalFallsBackToOneSecond() {
        XCTAssertEqual(RefreshInterval.validated(0), 1)
        XCTAssertEqual(RefreshInterval.validated(-1), 1)
        XCTAssertEqual(RefreshInterval.validated(.nan), 1)
        XCTAssertEqual(RefreshInterval.validated(0.5), 0.5)
        XCTAssertEqual(RefreshInterval.validated(10), 10)
    }

    func testMemoryUsageExcludesFileCacheWithoutDeductingSpeculativePagesTwice() throws {
        var info = vm_statistics64_data_t()
        // 2,000 anonymous + 400 regular file-cache pages in active/inactive,
        // plus 100 speculative file-cache pages outside those queues.
        info.active_count = 1200
        info.inactive_count = 1200
        info.speculative_count = 100
        info.external_page_count = 500
        info.purgeable_count = 100
        info.wire_count = 500
        info.compressor_page_count = 300
        info.total_uncompressed_pages_in_compressor = 3000
        for pageSize: vm_size_t in [4096, 16384] {
            let usage = try XCTUnwrap(SystemSampler.memoryUsage(
                statistics: info, pageSize: pageSize,
                physicalMemory: UInt64(pageSize) * 10_000))
            // (2,000 - 100 purgeable + 500 wired + 300 compressed) / 10,000.
            XCTAssertEqual(usage, 0.27, accuracy: 0.000001)
        }
    }

    func testSpeculativeFileCacheGrowthAndQueueMovementDoNotChangeMemoryUsage() throws {
        var info = vm_statistics64_data_t()
        info.active_count = 1200
        info.inactive_count = 1200
        info.speculative_count = 100
        info.external_page_count = 500
        info.purgeable_count = 100
        info.wire_count = 500
        info.compressor_page_count = 300
        let initial = try XCTUnwrap(SystemSampler.memoryUsage(
            statistics: info, pageSize: 16384, physicalMemory: 16384 * 100_000))

        // Adding reclaimable speculative cache must not reduce app usage.
        info.speculative_count += 10_000
        info.external_page_count += 10_000
        XCTAssertEqual(SystemSampler.memoryUsage(statistics: info, pageSize: 16384,
                                                physicalMemory: 16384 * 100_000), initial)

        // Moving cache into the active queue also leaves app usage unchanged.
        info.speculative_count -= 5000
        info.active_count += 5000
        XCTAssertEqual(SystemSampler.memoryUsage(statistics: info, pageSize: 16384,
                                                physicalMemory: 16384 * 100_000), initial)
    }

    func testLiveSamplerReturnsSystemMetrics() throws {
        let sampler = SystemSampler()
        let initial = sampler.sample()
        XCTAssertNil(initial.cpu)
        XCTAssertNil(initial.upload)
        let memory = try XCTUnwrap(initial.memory)
        XCTAssertTrue((0...1).contains(memory))
        // CPU tick counters can stay frozen for about a second.
        var next = sampler.sample()
        let deadline = Date().addingTimeInterval(3)
        while next.cpu == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            next = sampler.sample()
        }
        let cpu = try XCTUnwrap(next.cpu)
        XCTAssertTrue((0...1).contains(cpu))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(next.download), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(next.upload), 0)
        sampler.reset()
        XCTAssertNil(sampler.sample().upload)
    }

    func testRebaselineReportsSoonWhileKeptBaselineWaitsFullInterval() {
        let restarting = RefreshInterval.initialSamplingPlan(interval: 10, rebaseline: true, currentCPU: 0.5)
        XCTAssertEqual(restarting.delay, RefreshInterval.rebaselineDelay)
        XCTAssertEqual(restarting.quickRetries, RefreshInterval.rebaselineRetries)
        XCTAssertEqual(RefreshInterval.initialSamplingPlan(interval: 0.5, rebaseline: true, currentCPU: nil).delay, 0.5)
        let ready = RefreshInterval.initialSamplingPlan(interval: 10, rebaseline: false, currentCPU: 0)
        XCTAssertEqual(ready.delay, 10)
        XCTAssertEqual(ready.quickRetries, 0)
        for interval in RefreshInterval.choices {
            XCTAssertLessThanOrEqual(
                RefreshInterval.initialSamplingPlan(interval: interval, rebaseline: true, currentCPU: nil).delay, interval)
        }
    }

    func testIntervalChangeBeforeFirstCPUReadingKeepsQuickSampling() {
        for interval in RefreshInterval.choices {
            let plan = RefreshInterval.initialSamplingPlan(interval: interval, rebaseline: false, currentCPU: nil)
            XCTAssertEqual(plan.delay, RefreshInterval.rebaselineDelay)
            XCTAssertEqual(plan.quickRetries, RefreshInterval.rebaselineRetries)
        }
    }

    func testFrozenCPUCountersKeepBaselineAndLastReading() {
        func counters(busy: UInt32, idle: UInt32) -> CPUCounters {
            CPUCounters(user: busy, system: 0, idle: idle, nice: 0)
        }
        var tracker = CPUUsageTracker()
        XCTAssertNil(tracker.update(counters(busy: 100, idle: 100)))
        // No ticks yet after the baseline: still no reading, baseline kept.
        XCTAssertNil(tracker.update(counters(busy: 100, idle: 100)))
        XCTAssertEqual(tracker.update(counters(busy: 150, idle: 150)), 0.5)
        // Frozen counters repeat the last reading instead of going blank.
        XCTAssertEqual(tracker.update(counters(busy: 150, idle: 150)), 0.5)
        // The next reading spans the whole window since the last change.
        XCTAssertEqual(tracker.update(counters(busy: 240, idle: 160)), 0.9)
        // A failed read drops the baseline and reading.
        XCTAssertNil(tracker.update(nil))
        XCTAssertNil(tracker.update(counters(busy: 300, idle: 300)))
        tracker.reset()
        XCTAssertNil(tracker.update(counters(busy: 400, idle: 400)))
        XCTAssertNil(tracker.update(counters(busy: 400, idle: 400)))
    }
}
