import Foundation

public enum RateFormatter {
    /// Decimal network units; at most three digits in the numeric portion.
    public static func string(bytesPerSecond rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"]
        var value = rate
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        // Promote before rounding would produce a four-digit number.
        if value.rounded() >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        value = min(value, 999)
        let decimals = unit >= 2 && value < 9.95 ? 1 : 0
        return String(format: "%.*f %@", locale: Locale(identifier: "en_US_POSIX"),
                      decimals, value, units[unit])
    }
}

public struct CPUCounters {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public func usage(since previous: CPUCounters) -> Double? {
        // The kernel's 32-bit tick counters can wrap during long uptimes.
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system)
            + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        return total > 0 ? Double(busy) / Double(total) : nil
    }
}

/// The kernel's aggregate tick counters update in bursts and can stay frozen
/// for about a second. A sample with no new ticks keeps the older baseline
/// (so the next reading covers the longer window) and repeats the last usage,
/// instead of reporting no reading.
public struct CPUUsageTracker {
    private var baseline: CPUCounters?
    private var lastUsage: Double?

    public init() {}

    public mutating func update(_ counters: CPUCounters?) -> Double? {
        guard let counters else {
            reset()
            return nil
        }
        guard let baseline else {
            self.baseline = counters
            return nil
        }
        guard let usage = counters.usage(since: baseline) else { return lastUsage }
        self.baseline = counters
        lastUsage = usage
        return usage
    }

    public mutating func reset() {
        baseline = nil
        lastUsage = nil
    }
}

public struct InterfaceCounters {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

public struct NetworkRates {
    public let download: Double
    public let upload: Double

    public static func between(
        previous: [String: InterfaceCounters],
        current: [String: InterfaceCounters],
        elapsed: TimeInterval
    ) -> NetworkRates {
        guard elapsed.isFinite, elapsed > 0 else {
            return NetworkRates(download: 0, upload: 0)
        }
        var received = 0.0
        var sent = 0.0
        for (name, counters) in current {
            // A new/reconnected interface needs its own baseline. Do not treat
            // its lifetime byte counter as traffic from this sample interval.
            guard let old = previous[name] else { continue }
            if counters.received >= old.received {
                received += Double(counters.received - old.received)
            }
            if counters.sent >= old.sent {
                sent += Double(counters.sent - old.sent)
            }
        }
        return NetworkRates(download: received / elapsed, upload: sent / elapsed)
    }
}

public struct MetricsSnapshot: Equatable {
    public let cpu: Double?
    public let memory: Double?
    public let upload: Double?
    public let download: Double?
    public let interfaces: [String]
    /// Power draw and battery; nil on a Mac that does not report them.
    public let power: PowerReading?

    public init(cpu: Double?, memory: Double?, upload: Double?, download: Double?,
                interfaces: [String] = [], power: PowerReading? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.upload = upload
        self.download = download
        self.interfaces = interfaces
        self.power = power
    }

    public static let empty = MetricsSnapshot(cpu: nil, memory: nil, upload: nil, download: nil)
}

public enum RefreshInterval {
    public static let choices: [TimeInterval] = [0.5, 1, 2, 3, 5, 10]

    /// After a new baseline, the first reading follows this soon.
    public static let rebaselineDelay: TimeInterval = 0.5
    /// Aggregate CPU tick counters can stay frozen for about a second, so the
    /// first reading may lack CPU. Retry at `rebaselineDelay` this many times.
    public static let rebaselineRetries = 3

    public static func validated(_ value: TimeInterval) -> TimeInterval {
        choices.contains(value) ? value : 1
    }

    /// Keep warming up until CPU has a reading, even if an interval change
    /// preserves the existing baseline rather than creating a new one.
    public static func initialSamplingPlan(interval: TimeInterval, rebaseline: Bool,
                                           currentCPU: Double?) -> (delay: TimeInterval, quickRetries: Int) {
        let needsWarmup = rebaseline || currentCPU == nil
        return (needsWarmup ? min(rebaselineDelay, interval) : interval,
                needsWarmup ? rebaselineRetries : 0)
    }
}
