import Darwin
import Foundation

struct ProcessSample {
    let pid: pid_t
    let startTime: UInt64
    let cpuTime: UInt64
    let memoryBytes: UInt64
    let sampledAt: UInt64
}

struct ProcessCPUUsage {
    let process: ProcessSample
    let percent: Double
}

enum ProcessSampler {
    /// Captured on the utility queue only while the menu is open.
    static func capture() -> [pid_t: ProcessSample]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var capacity = Int(estimate) + 32
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count >= 0 else { return nil }
            if Int(count) >= capacity {
                capacity *= 2
                continue
            }
            var samples: [pid_t: ProcessSample] = [:]
            for pid in pids.prefix(Int(count)) where pid > 0 {
                var info = rusage_info_v2()
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                    }
                }
                // Protected processes and processes that exit during capture are skipped.
                guard result == 0, info.ri_proc_exit_abstime == 0 else { continue }
                let total = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
                guard !total.overflow else { continue }
                samples[pid] = ProcessSample(
                    pid: pid, startTime: info.ri_proc_start_abstime,
                    cpuTime: total.partialValue, memoryBytes: info.ri_phys_footprint,
                    sampledAt: mach_absolute_time())
            }
            return samples
        }
        return nil
    }

    static func topCPU(previous: [pid_t: ProcessSample],
                       current: [pid_t: ProcessSample],
                       processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> [ProcessCPUUsage] {
        let cores = Double(max(1, processorCount))
        return current.values.compactMap { sample -> ProcessCPUUsage? in
            guard let old = previous[sample.pid], old.startTime == sample.startTime,
                  sample.sampledAt > old.sampledAt, sample.cpuTime >= old.cpuTime
            else { return nil }
            let elapsed = Double(sample.sampledAt - old.sampledAt)
            let used = Double(sample.cpuTime - old.cpuTime)
            // Both values use Mach absolute-time ticks. Normalize across all
            // logical CPUs so 100% represents the whole machine's capacity.
            return ProcessCPUUsage(process: sample, percent: min(100, used / elapsed / cores * 100))
        }.sorted {
            $0.percent == $1.percent ? $0.process.pid < $1.process.pid : $0.percent > $1.percent
        }.prefix(3).map { $0 }
    }

    static func topMemory(_ samples: [pid_t: ProcessSample]) -> [ProcessSample] {
        samples.values.sorted {
            $0.memoryBytes == $1.memoryBytes ? $0.pid < $1.pid : $0.memoryBytes > $1.memoryBytes
        }.prefix(3).map { $0 }
    }

    static func executableURL(for pid: pid_t) -> URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func name(for pid: pid_t) -> String {
        if let url = executableURL(for: pid) { return url.lastPathComponent }
        var name = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &name, UInt32(name.count)) > 0 {
            return String(cString: name)
        }
        return "Process \(pid)"
    }
}
