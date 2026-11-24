// The desk light (Mini Traffic Light over Bluetooth): shows the followed agent's sessions.
// Moved from AITrafficLight's Daemon; runs only while at least one agent is hooked up.
import AppKit
import CoreBluetooth

private let writeUUID = CBUUID(string: "FF01")

/// Shows the followed agent's sessions on the desk light.
/// Device match: advertised name containing TRAFFICLIGHT_BLE_NAME (default "CursorLight") with characteristic 0xFF01.
final class TrafficLightDevice: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// The settings section; the menu bar lamps are 「显示 › 红绿灯」.
    static var title: String { L("Desk Traffic Light", "桌面红绿灯") }
    private let sessions: AgentSessions
    /// Called when the connection changes.
    var onStatusChange: (() -> Void)?
    /// At least one agent is hooked up: use the light.
    private(set) var active = false
    /// Name of the connected light, nil while not connected.
    private(set) var connectedName: String?

    /// Created on first use, so Bluetooth access is only requested by people who use the light.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    /// Lights being connected to: probing a candidate, or reconnecting after the link dropped.
    private var connecting: [UUID: CBPeripheral] = [:]
    private let nameFilter = ProcessInfo.processInfo.environment["TRAFFICLIGHT_BLE_NAME"] ?? "CursorLight"
    /// Last steady mode, restored after a reconnect.
    private var lastIdle: String?
    /// Mode last sent on behalf of the sessions; nil after a manual command took over the light.
    private var sessionMode: Int?
    /// Bumped per green flash so only the latest one restores the steady mode.
    private var flashGeneration = 0

    /// Which agent's sessions drive the light: an id from agentNames, or "none".
    var follow: String {
        get { UserDefaults.standard.string(forKey: "followAgent") ?? "claude" }
        set {
            UserDefaults.standard.set(newValue, forKey: "followAgent")
            sessionMode = nil
            sessionsChanged()
        }
    }

    /// The light this Mac connected to before (CoreBluetooth id), nil to take the first one found.
    private(set) var savedDevice: String? {
        get { UserDefaults.standard.string(forKey: "deviceID") }
        set { UserDefaults.standard.set(newValue, forKey: "deviceID") }
    }

    /// Not looking for a light: 断开连接 was chosen, or 连接 never was (also after a restart).
    private(set) var paused: Bool {
        get { UserDefaults.standard.object(forKey: "devicePaused") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "devicePaused") }
    }

    private var wantsLight: Bool { active && !paused }

    init(sessions: AgentSessions) {
        self.sessions = sessions
        super.init()
        // 连接 found no light before quitting: a restart waits for 连接 again instead of scanning.
        if savedDevice == nil { paused = true }
    }

    /// Starts or stops with the agents: turning the last agent off also turns the light off and
    /// lets go of it (it stays remembered, so turning an agent on again reconnects).
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            startScan()
        } else {
            agentLog("no agent hooked up: releasing the light")
            releaseLight(off: true)
            sessionMode = nil
            lastIdle = nil
        }
        onStatusChange?()
    }

    /// The sessions changed: show the followed agent's state.
    func sessionsChanged() {
        let mode = sessions.mode(for: follow)
        if active, mode != sessionMode {
            sessionMode = mode
            send("C:")
            send("I:\(mode)")
        }
    }

    /// A session finished. Steady green only shows once nothing else is running; otherwise flash
    /// so the finish is noticed.
    func sessionFinished(_ id: String) {
        if sessions.entries[id]?.agent == follow, sessions.mode(for: follow) != AgentSessions.State.done.mode {
            flashDone()
        }
    }

    /// A light command from 测试灯光.
    private func command(_ cmd: String) {
        if cmd.hasPrefix("I:") { sessionMode = nil }
        send(cmd)
    }

    /// A session finished: flash green 5 times, then go back to the steady mode
    /// (yellow / red for other sessions, or off).
    private func flashDone() {
        let (on, off, times) = (400, 300, 5)
        send("F:G:\(on):\(off):\(times)")
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds((on + off) * times + 200)) { [weak self] in
            guard let self, generation == self.flashGeneration else { return }
            self.send("C:")
            if let idle = self.lastIdle { self.send(idle) }
        }
    }

    /// 测试灯光: a manual mode; the sessions take the light back on their next change.
    func setMode(_ mode: Int) {
        command("C:")
        command("I:\(mode)")
    }

    private func send(_ cmd: String) {
        if cmd.hasPrefix("I:") { lastIdle = cmd }
        // Without the device only the menu bar shows the state; on connect it gets lastIdle.
        if let p = peripheral, let ch = characteristic, p.state == .connected {
            write(cmd, p, ch)
        }
    }

    private func write(_ cmd: String, _ p: CBPeripheral, _ ch: CBCharacteristic) {
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(cmd.utf8), for: ch, type: type)
        agentLog("-> \(cmd)")
    }

    /// 断开连接: turns the light off and leaves it alone (also after a restart) until 连接.
    func disconnect() {
        agentLog("manual disconnect")
        paused = true
        releaseLight(off: true)
        onStatusChange?()
    }

    /// 连接 / 重新连接: drops the current connection and searches again; `forget` also accepts a
    /// different light (换一个红绿灯设备).
    func reconnect(forget: Bool = false) {
        agentLog("manual reconnect\(forget ? ", forgetting \(savedDevice ?? "-")" : "")")
        paused = false
        if forget { savedDevice = nil }
        releaseLight(off: false)
        onStatusChange?()
        startScan()
    }

    /// Stops scanning and drops every connection, optionally turning the light off first.
    private func releaseLight(off: Bool) {
        central?.stopScan()
        for p in connecting.values { central?.cancelPeripheralConnection(p) }
        connecting.removeAll()
        guard let p = peripheral else { return }
        if off, let ch = characteristic, p.state == .connected {
            write("C:", p, ch)
            write("I:0", p, ch)
        }
        peripheral = nil
        characteristic = nil
        connectedName = nil
        // Give the off command a moment to go out before dropping the link.
        DispatchQueue.main.asyncAfter(deadline: .now() + (off ? 0.3 : 0)) { [weak self] in
            self?.central?.cancelPeripheralConnection(p)
        }
    }

    private func startScan() {
        guard wantsLight, peripheral == nil else { return }
        guard let central else {
            // The state callback scans once Bluetooth is ready.
            central = CBCentralManager(delegate: self, queue: nil)
            return
        }
        guard central.state == .poweredOn else { return }
        agentLog("scanning")
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        agentLog("bluetooth state \(c.state.rawValue)")
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard wantsLight, peripheral == nil, connecting[p.identifier] == nil else { return }
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.localizedCaseInsensitiveContains(nameFilter) else { return }
        // Once paired, stick to that light so a colleague's one nearby isn't picked up.
        if let saved = savedDevice, saved != p.identifier.uuidString { return }
        agentLog("probing \(name) \(p.identifier) rssi=\(rssi)")
        connecting[p.identifier] = p
        p.delegate = self
        c.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.peripheral !== p, self.connecting[p.identifier] === p else { return }
            self.connecting[p.identifier] = nil
            c.cancelPeripheralConnection(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics([writeUUID], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard wantsLight, peripheral == nil, connecting[p.identifier] != nil,
              let ch = s.characteristics?.first(where: { $0.uuid == writeUUID }) else {
            if !wantsLight { central?.cancelPeripheralConnection(p) }
            return
        }
        connecting[p.identifier] = nil
        peripheral = p
        characteristic = ch
        connectedName = p.name ?? "?"
        savedDevice = p.identifier.uuidString
        central?.stopScan()
        agentLog("connected \(p.name ?? "?") \(p.identifier) service=\(s.uuid) props=0x\(String(ch.properties.rawValue, radix: 16))")
        onStatusChange?()
        write("C:", p, ch)
        if let idle = lastIdle { write(idle, p, ch) }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { agentLog("write failed: \(error.localizedDescription)") }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        agentLog("disconnect \(p.identifier) \(error?.localizedDescription ?? "")")
        connecting[p.identifier] = nil
        guard p === peripheral else { return }
        peripheral = nil
        characteristic = nil
        connectedName = nil
        onStatusChange?()
        // Reconnect directly; CoreBluetooth waits until the device is back.
        connecting[p.identifier] = p
        c.connect(p, options: nil)
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connecting[p.identifier] = nil
    }
}
