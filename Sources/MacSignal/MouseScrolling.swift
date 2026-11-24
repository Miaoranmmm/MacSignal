import AppKit
import IOKit
import Darwin

/// Classic vertical scrolling for mouse wheels, applied to scroll events from
/// `MouseEventTap`. Trackpad events pass through unchanged.
final class MouseScrolling {
    enum Device {
        case mouse
        case trackpad
    }

    private let hid = ScrollHIDBridge()
    private var devices = SenderDeviceCache()

    func reset() {
        devices.removeAll()
    }

    func process(_ event: CGEvent) {
        guard let native = NSEvent(cgEvent: event) else { return }
        let hidEvent = hid.copyEvent?(event)?.takeRetainedValue()
        var device: Device?
        if let hidEvent, let senderID = hid.senderID {
            device = devices.device(for: senderID(hidEvent),
                                    now: ProcessInfo.processInfo.systemUptime,
                                    resolve: Self.device(for:))
        }
        // A discrete wheel is identifiable even without the optional HID bridge.
        // Continuous sources remain untouched when their device is unidentified.
        if device == nil, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
           event.getIntegerValueField(.eventSourceUnixProcessID) == 0 {
            device = .mouse
        }
        guard let device, Self.shouldReverse(device: device, natural: native.isDirectionInvertedFromDevice)
        else { return }
        let scrollY: UInt32 = (6 << 16) | 1
        let originalHIDValue = hidEvent.flatMap { value in hid.readFloat.map { $0(value, scrollY) } }
        Self.reverseVertical(event)
        if let hidEvent, let originalHIDValue, let write = hid.writeFloat {
            write(hidEvent, scrollY, -originalHIDValue)
        }
    }

    static func shouldReverse(device: Device, natural: Bool) -> Bool {
        switch device {
        case .mouse: return natural
        case .trackpad: return false
        }
    }

    static func reverseVertical(_ event: CGEvent) {
        // Read every representation before changing any field. Some setters
        // cause Quartz to derive the other delta representations again.
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines == .min ? .max : -lines)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: points == .min ? .max : -points)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
    }

    private static func device(for sender: UInt64) -> Device? {
        guard sender != 0 else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        for _ in 0..<4 {
            let acceleration = IORegistryEntryCreateCFProperty(
                entry, "HIDScrollAccelerationType" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if acceleration == "HIDTrackpadScrollAcceleration"
                || IOObjectConformsTo(entry, "AppleMultitouchTrackpadHIDEventDriver") != 0 {
                return .trackpad
            }
            if acceleration == "HIDMouseScrollAcceleration"
                || IOObjectConformsTo(entry, "AppleMultitouchMouseHIDEventDriver") != 0 {
                return .mouse
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            else { break }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }
}

/// Remembers which device sent scroll events, so the IORegistry is not walked
/// for every event inside the tap. Unidentified senders are retried after a
/// delay, because a newly attached device may not be fully registered yet.
struct SenderDeviceCache {
    /// Total senders remembered, identified or not.
    static let capacity = 64
    static let unidentifiedRetryDelay: TimeInterval = 5

    private enum Entry {
        case identified(MouseScrolling.Device)
        case unidentified(retryAt: TimeInterval)
    }

    private var entries: [UInt64: Entry] = [:]

    var count: Int { entries.count }

    mutating func device(for sender: UInt64, now: TimeInterval,
                         resolve: (UInt64) -> MouseScrolling.Device?) -> MouseScrolling.Device? {
        switch entries[sender] {
        case .identified(let device)?:
            return device
        case .unidentified(let retryAt)? where now < retryAt:
            return nil
        default:
            break
        }
        let device = resolve(sender)
        // Senders rarely change; clearing everything is simpler than LRU and
        // costs at most one lookup per active sender.
        if entries[sender] == nil, entries.count >= Self.capacity { entries.removeAll() }
        entries[sender] = device.map(Entry.identified)
            ?? .unidentified(retryAt: now + Self.unidentifiedRetryDelay)
        return device
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// These optional system symbols expose the scroll event's actual HID sender.
/// They are not public SDK API. Resolve dynamically so missing symbols do not
/// prevent launch, and fall back to discrete wheel events when unavailable.
private struct ScrollHIDBridge {
    typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    typealias SenderID = @convention(c) (CFTypeRef) -> UInt64
    typealias ReadFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    typealias WriteFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void

    let copyEvent: CopyEvent?
    let senderID: SenderID?
    let readFloat: ReadFloat?
    let writeFloat: WriteFloat?

    init() {
        let scope = UnsafeMutableRawPointer(bitPattern: -2)
        copyEvent = dlsym(scope, "CGEventCopyIOHIDEvent").map { unsafeBitCast($0, to: CopyEvent.self) }
        senderID = dlsym(scope, "IOHIDEventGetSenderID").map { unsafeBitCast($0, to: SenderID.self) }
        readFloat = dlsym(scope, "IOHIDEventGetFloatValue").map { unsafeBitCast($0, to: ReadFloat.self) }
        writeFloat = dlsym(scope, "IOHIDEventSetFloatValue").map { unsafeBitCast($0, to: WriteFloat.self) }
    }
}
