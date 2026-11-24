import Darwin
import XCTest
@testable import MacSignal

final class ProcessSamplerTests: XCTestCase {
    private func sample(_ pid: pid_t, start: UInt64 = 1, cpu: UInt64 = 0,
                        memory: UInt64 = 0, time: UInt64) -> ProcessSample {
        ProcessSample(pid: pid, startTime: start, cpuTime: cpu,
                      memoryBytes: memory, sampledAt: time)
    }

    func testCPUUsesIntervalAndNormalizesAcrossAllCores() {
        let previous: [pid_t: ProcessSample] = [
            1: sample(1, cpu: 9_000_000_000, time: 1_000_000_000),
            2: sample(2, cpu: 1_000_000, time: 1_000_000_000),
            3: sample(3, cpu: 0, time: 1_000_000_000),
            4: sample(4, cpu: 0, time: 1_000_000_000)
        ]
        let current: [pid_t: ProcessSample] = [
            1: sample(1, cpu: 9_100_000_000, time: 1_500_000_000),
            2: sample(2, cpu: 1_001_000_000, time: 1_500_000_000),
            3: sample(3, cpu: 200_000_000, time: 1_500_000_000),
            4: sample(4, cpu: 0, time: 1_500_000_000)
        ]
        let ranked = ProcessSampler.topCPU(previous: previous, current: current, processorCount: 4)
        XCTAssertEqual(ranked.map { $0.process.pid }, [2, 3, 1])
        XCTAssertEqual(ranked.map(\.percent), [50, 10, 5])
        let bounded = ProcessSampler.topCPU(previous: previous, current: current, processorCount: 1)
        XCTAssertEqual(bounded.first?.percent, 100)
    }

    func testPIDReuseNewProcessesAndInvalidCountersDoNotProduceCPUSpikes() {
        let previous: [pid_t: ProcessSample] = [
            1: sample(1, start: 1, cpu: 10, time: 100),
            2: sample(2, cpu: 50, time: 100),
            3: sample(3, cpu: 50, time: 100),
            4: sample(4, cpu: 50, time: 100)
        ]
        let current: [pid_t: ProcessSample] = [
            1: sample(1, start: 2, cpu: 9999, memory: 999, time: 200),
            2: sample(2, cpu: 100, time: 100),
            3: sample(3, cpu: 40, time: 200),
            5: sample(5, cpu: 9999, time: 200)
        ]
        XCTAssertTrue(ProcessSampler.topCPU(previous: previous, current: current).isEmpty)
        XCTAssertEqual(ProcessSampler.topMemory(current).first?.pid, 1)
    }

    func testMemoryRankingAndEqualUsageHaveDeterministicOrder() {
        let samples: [pid_t: ProcessSample] = [
            3: sample(3, memory: 200, time: 100),
            1: sample(1, memory: 100, time: 100),
            2: sample(2, memory: 200, time: 100),
            4: sample(4, memory: 50, time: 100)
        ]
        XCTAssertEqual(ProcessSampler.topMemory(samples).map(\.pid), [2, 3, 1])
        XCTAssertTrue(ProcessSampler.topMemory([:]).isEmpty)
        XCTAssertEqual(ProcessSampler.topMemory([1: samples[1]!]).count, 1)
        let cpu = ProcessSampler.topCPU(previous: samples, current: [
            3: sample(3, time: 200), 2: sample(2, time: 200)
        ])
        XCTAssertEqual(cpu.map { $0.process.pid }, [2, 3])
    }

    func testLiveCaptureContainsCurrentProcessAndName() throws {
        let before = mach_absolute_time()
        let samples = try XCTUnwrap(ProcessSampler.capture())
        let after = mach_absolute_time()
        let current = try XCTUnwrap(samples[getpid()])
        XCTAssertGreaterThan(current.memoryBytes, 0)
        XCTAssertGreaterThanOrEqual(current.sampledAt, before)
        XCTAssertLessThanOrEqual(current.sampledAt, after)
        XCTAssertFalse(ProcessSampler.name(for: getpid()).isEmpty)
    }
}
