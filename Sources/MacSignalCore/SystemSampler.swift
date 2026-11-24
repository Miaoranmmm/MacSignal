import Darwin
import Foundation

/// Accessed exclusively from the sampling queue, or synchronously by --diagnose.
public final class SystemSampler {
    private let host = mach_host_self()
    private var cpuTracker = CPUUsageTracker()
    private var previousNetwork: [String: InterfaceCounters]?
    private var previousTime: TimeInterval?
    private var pageSize: vm_size_t = 0

    public init() {
        host_page_size(host, &pageSize)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    public func reset() {
        cpuTracker.reset()
        previousNetwork = nil
        previousTime = nil
    }

    public func sample() -> MetricsSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let usage = cpuTracker.update(readCPU())
        let network = readNetwork()
        var rates: NetworkRates?
        if let network, let previousNetwork, let previousTime {
            rates = NetworkRates.between(previous: previousNetwork, current: network,
                                         elapsed: now - previousTime)
        }
        previousNetwork = network
        previousTime = now
        return MetricsSnapshot(cpu: usage, memory: readMemory(), upload: rates?.upload,
                               download: rates?.download, interfaces: network?.keys.sorted() ?? [],
                               power: PowerSampler.isAvailable ? PowerSampler.read() : nil)
    }

    private func readCPU() -> CPUCounters? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUCounters(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                           idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readMemory() -> Double? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Self.memoryUsage(statistics: info, pageSize: pageSize,
                                physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func memoryUsage(statistics info: vm_statistics64_data_t, pageSize: vm_size_t,
                            physicalMemory: UInt64) -> Double? {
        guard pageSize > 0, physicalMemory > 0 else { return nil }
        // App memory + wired + compressed. Reclaimable file cache and purgeable
        // pages are excluded; compressed pages use their actual physical size.
        // External pages include speculative file-cache pages, which are not in
        // active/inactive. Include them before subtracting external pages so
        // speculative cache is not deducted from app memory a second time.
        let app = max(0, Double(info.active_count) + Double(info.inactive_count)
                      + Double(info.speculative_count)
                      - Double(info.external_page_count) - Double(info.purgeable_count))
        let used = (app + Double(info.wire_count) + Double(info.compressor_page_count))
            * Double(pageSize)
        return min(1, max(0, used / Double(physicalMemory)))
    }

    private func readNetwork() -> [String: InterfaceCounters]? {
        // NET_RT_IFLIST2 provides 64-bit counters. getifaddrs' if_data byte
        // counters are 32-bit and can overflow in seconds on fast connections.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let result = buffer.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue } // Interfaces changed between calls.
                return nil
            }
            return buffer.withUnsafeBytes { bytes in
                var counters: [String: InterfaceCounters] = [:]
                var offset = 0
                while offset + 4 <= size {
                    let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    guard length >= 4, offset + length <= size else { break }
                    defer { offset += length }
                    guard bytes[offset + 3] == UInt8(RTM_IFINFO2),
                          length >= MemoryLayout<if_msghdr2>.size else { continue }
                    let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    guard info.ifm_flags & IFF_UP != 0,
                          info.ifm_flags & IFF_RUNNING != 0,
                          info.ifm_flags & IFF_LOOPBACK == 0,
                          info.ifm_data.ifi_type == UInt8(IFT_ETHER) else { continue }
                    var nameBytes = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    guard if_indextoname(UInt32(info.ifm_index), &nameBytes) != nil else { continue }
                    let name = String(cString: nameBytes)
                    // Physical Ethernet / Wi-Fi / USB / Thunderbolt adapters.
                    // Exclude utun, bridges, awdl, llw and other virtual links so
                    // VPN encapsulation does not count the same traffic twice.
                    guard name.hasPrefix("en"), name.dropFirst(2).allSatisfy(\.isNumber) else { continue }
                    counters[name] = InterfaceCounters(received: info.ifm_data.ifi_ibytes,
                                                       sent: info.ifm_data.ifi_obytes)
                }
                return counters
            }
        }
        return nil
    }
}
