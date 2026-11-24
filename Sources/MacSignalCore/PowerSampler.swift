import Foundation
import IOKit
import IOKit.ps

/// Whole-machine power draw and the battery, on Macs that report them. No admin rights needed.
public struct PowerReading: Equatable {
    /// What the whole Mac draws, in watts.
    public var watts: Double
    /// Battery charge 0–1; nil without a battery.
    public var level: Double?
    public var pluggedIn: Bool
    public var charging: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is still estimating.
    public var minutesLeft: Int?

    public init(watts: Double, level: Double?, pluggedIn: Bool, charging: Bool, minutesLeft: Int?) {
        self.watts = watts
        self.level = level
        self.pluggedIn = pluggedIn
        self.charging = charging
        self.minutesLeft = minutesLeft
    }
}

public enum PowerSampler {
    /// The Mac reports its power draw; checked once, it does not change while running.
    public static let isAvailable = systemLoad() != nil

    public static func read() -> PowerReading? {
        guard let milliwatts = systemLoad() else { return nil }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let sources = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return reading(milliwatts: milliwatts, sources: sources)
    }

    /// Builds a reading from the power draw and the IOPowerSources descriptions.
    public static func reading(milliwatts: Int, sources: [[String: Any]]) -> PowerReading {
        let battery = sources.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        let current = battery?[kIOPSCurrentCapacityKey] as? Int
        let max = battery?[kIOPSMaxCapacityKey] as? Int
        let level = current.flatMap { c in max.flatMap { $0 > 0 ? min(1, Double(c) / Double($0)) : nil } }
        let pluggedIn = battery.map { $0[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue } ?? true
        let charging = battery?[kIOPSIsChargingKey] as? Bool ?? false
        // -1 while estimating; the registry's 65535 never gets here.
        let minutes = battery?[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        let known = minutes.flatMap { $0 > 0 && $0 < 24 * 60 ? $0 : nil }
        return PowerReading(watts: Double(milliwatts) / 1000, level: level, pluggedIn: pluggedIn, charging: charging,
                            minutesLeft: pluggedIn && !charging ? nil : known)
    }

    /// System load in milliwatts from the battery's power telemetry; nil when not reported.
    private static func systemLoad() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)
        guard let telemetry = property?.takeRetainedValue() as? [String: Any],
              let load = telemetry["SystemLoad"] as? Int, load > 0 else { return nil }
        return load
    }
}
