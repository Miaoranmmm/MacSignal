import AppKit
import MacSignalCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?
    let menu = MenuStyle.menu()
    private let queue = DispatchQueue(label: "MacSignal.sampling", qos: .utility)
    private let processMenu = ProcessMenuContent()
    private lazy var details = DetailMenuContent(processes: processMenu)
    private let sampler = SystemSampler()
    private let sleepPrevention = SleepPrevention()
    private let mouseTap = MouseEventTap()
    /// The user's saved choices. The tap may be inactive while access is missing.
    private var mouseOptions = Set(MouseOption.allCases.filter {
        UserDefaults.standard.bool(forKey: $0.defaultsKey)
    })
    private var mouseTapRetry: Timer?
    private var snapshot = MetricsSnapshot.empty
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var interval = RefreshInterval.validated(
        UserDefaults.standard.double(forKey: "refreshInterval"))
    /// 显示数字: percentages instead of bars for CPU, memory and AI quota.
    private var showNumbers = UserDefaults.standard.bool(forKey: "showNumbers")

    // Agents and the desk light.
    let receiver = AgentReceiver()
    private lazy var device = TrafficLightDevice(sessions: receiver.sessions)
    private lazy var agentMenu = AgentMenuContent(receiver: receiver)
    private let quota = UsageLimits()
    private let claudeUsage = ClaudeUsage()
    /// Agents with our hooks; any: the lamps, 「Agent 会话」 and 「红绿灯」 are shown.
    /// Set by refreshAgents (internal so tests can build the menu for either case).
    var hookedAgents: Set<String> {
        get { receiver.hookedAgents }
        set { receiver.hookedAgents = newValue }
    }
    var agentsHooked: Bool { !hookedAgents.isEmpty }
    private var menuOpen = false
    /// Reads Claude Code's quota every few minutes; stopped on quit.
    private var usageTimer: Timer?
    /// Waiting sessions already announced; a new one blinks the red lamp.
    private var knownWaiting: Set<String> = []
    private var blinkTimer: Timer?
    private var redDimmed = false
    /// The open menu's 防止睡眠 item and 设置 submenu, brought up to date by syncMenu.
    private weak var sleepItem: NSMenuItem?
    private weak var settingsSubmenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also applies when launching the SwiftPM executable without a bundle.
        NSApp.setActivationPolicy(.accessory)
        status = StatusController(target: self, action: #selector(showMenu(_:))) { [weak self] in self?.updateStatus() }
        device.onStatusChange = { [weak self] in
            self?.syncMenu()
            self?.updateStatus()
        }
        receiver.onSessionsChange = { [weak self] in
            self?.device.sessionsChanged()
            self?.sessionsChanged()
        }
        receiver.onSessionFinished = { [weak self] id in self?.device.sessionFinished(id) }
        receiver.onQuota = { [weak self] json in
            if self?.quota.apply(json) == true { self?.updateStatus() }
        }
        claudeUsage.onQuota = { [weak self] quota in
            if self?.quota.apply(quota) == true { self?.updateStatus() }
        }
        mouseTap.onInterrupted = { [weak self] in self?.reconcileMouseTap() }
        reconcileMouseTap()
        refreshHooks()
        refreshAgents()
        updateStatus()
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(willSleep),
                                  name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(didWake),
                                  name: NSWorkspace.didWakeNotification, object: nil)
        startSampling(rebaseline: true)
        refreshClaudeUsage()
        let timer = Timer(timeInterval: ClaudeUsage.interval, repeats: true) { [weak self] _ in self?.refreshClaudeUsage() }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        status?.tooltip?.dismiss()
        processMenu.stop()
        stopMouseTapRetry()
        mouseTap.stop()
        sleepPrevention.setActive(false)
        usageTimer?.invalidate()
        stopSampling()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Last, with nothing else scheduled: turn the desk light off instead of leaving the last
        // state lit, and give the command a moment to go out before the app exits.
        if agentsHooked, device.connectedName != nil {
            device.setActive(false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    // Double-clicking the app while it runs only sends a reopen event: show the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        status?.button?.performClick(nil)
        return false
    }

    // MARK: Menu

    func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false
        agentMenu.remove()
        // The details of what the menu bar shows, in its order; 「Agent 会话」 at the top.
        let r = readings
        let shown = StatusModule.shown(r)
        if shown.contains(.light) { agentMenu.add(to: menu) }
        details.add(shown, readings: r, to: menu, at: menu.numberOfItems)
        let sleepItem = NSMenuItem(title: L("Prevent Sleep", "防止睡眠"), action: #selector(toggleSleepPrevention), keyEquivalent: "")
        sleepItem.target = self
        sleepItem.state = sleepPrevention.isActive ? .on : .off
        menu.addItem(keepOpen(sleepItem))
        self.sleepItem = sleepItem
        let settings = NSMenuItem(title: L("Settings", "设置"), action: nil, keyEquivalent: "")
        settings.submenu = settingsMenu()
        settingsSubmenu = settings.submenu
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit MacSignal", "退出 MacSignal"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.addItem(MenuStyle.columnKeeper())
    }

    /// Chosen in the menu, `item` keeps it open and the menu shows the result.
    @discardableResult
    private func keepOpen(_ item: NSMenuItem) -> NSMenuItem {
        MenuActionRow.keepOpen(item) { [weak self] in self?.syncMenu() }
    }

    /// Brings the open menu up to date after a choice in it or a change behind it
    /// (the light connecting, sessions arriving).
    private func syncMenu() {
        guard menuOpen else { return }
        sleepItem?.state = sleepPrevention.isActive ? .on : .off
        (sleepItem?.view as? MenuActionRow)?.update()
        if let live = settingsSubmenu { MenuActionRow.sync(live, from: settingsMenu()) }
    }

    /// Closes the menu, then runs `work` (an alert must not appear over an open menu).
    private func closeMenu(then work: @escaping () -> Void) {
        menu.cancelTracking()
        DispatchQueue.main.async(execute: work)
    }

    /// 设置 ›: Agent, 红绿灯 (only with an agent hooked up), 鼠标, 显示.
    func settingsMenu() -> NSMenu {
        let settings = MenuStyle.menu()
        settings.addItem(ProcessMenuContent.heading(L("Agents", "Agent")))
        for agent in Integration.all {
            let detected = agent.detected
            let item = NSMenuItem(title: agent.name + (detected ? "" : L(" (not found on this Mac)", "（本机未检测到）")),
                                  action: #selector(toggleAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.state = agent.installed ? .on : .off
            item.isEnabled = detected || agent.installed
            settings.addItem(keepOpen(item))
        }
        let restart = NSMenuItem(title: L("Restart the agent to apply changes", "改完需重启对应的 agent 才生效"),
                                 action: nil, keyEquivalent: "")
        restart.isEnabled = false
        settings.addItem(restart)
        if agentsHooked, !receiver.sessions.entries.isEmpty {
            let clear = NSMenuItem(title: L("Clear Session List", "清空会话列表"), action: #selector(clearSessions), keyEquivalent: "")
            clear.target = self
            settings.addItem(keepOpen(clear))
        }
        settings.addItem(.separator())

        if agentsHooked {
            settings.addItem(ProcessMenuContent.heading(TrafficLightDevice.title))
            lightItems().forEach(settings.addItem)
            settings.addItem(.separator())
        }

        settings.addItem(ProcessMenuContent.heading(L("Mouse", "鼠标")))
        for item in Self.mouseOptionItems(enabled: mouseOptions, pending: pendingMouseTapReason(), target: self) {
            // The toggles keep the menu open; 「打开辅助功能设置…」 leaves it.
            settings.addItem(item.action == #selector(toggleMouseOption(_:)) ? keepOpen(item) : item)
        }
        settings.addItem(.separator())

        settings.addItem(ProcessMenuContent.heading(L("Display", "显示")))
        // What the menu bar item shows; a module whose condition is not met is not offered.
        let now = readings
        for module in StatusModule.allCases where module.isAvailable(now) {
            let item = NSMenuItem(title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = module.rawValue
            item.state = module.isChecked ? .on : .off
            settings.addItem(keepOpen(item))
        }
        settings.addItem(.separator())
        let numbers = NSMenuItem(title: L("Show Numbers", "显示数字"), action: #selector(toggleNumbers), keyEquivalent: "")
        numbers.target = self
        numbers.state = showNumbers ? .on : .off
        settings.addItem(keepOpen(numbers))
        let refresh = NSMenuItem(title: L("Refresh Interval", "刷新间隔"), action: nil, keyEquivalent: "")
        let submenu = MenuStyle.menu()
        for choice in RefreshInterval.choices {
            let label = choice == 0.5 ? L("0.5 seconds", "0.5 秒")
                : choice == 1 ? L("1 second", "1 秒") : L("\(Int(choice)) seconds", "\(Int(choice)) 秒")
            let item = NSMenuItem(title: label, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: choice)
            item.state = choice == interval ? .on : .off
            submenu.addItem(keepOpen(item))
        }
        refresh.submenu = submenu
        settings.addItem(refresh)
        if agentsHooked {
            settings.addItem(.separator())
            let log = NSMenuItem(title: L("Open Log", "打开日志"), action: #selector(openLog), keyEquivalent: "")
            log.target = self
            settings.addItem(log)
        }
        settings.addItem(MenuStyle.columnKeeper())
        return settings
    }

    /// 「Connected to …」, 「Disconnected」 (by the user) or 「Not connected」.
    private var lightConnection: String {
        device.connectedName.map { L("Connected to \($0)", "已连接 \($0)") }
            // 已断开 only after 断开连接 from a remembered light; never connected is 未连接.
            ?? (device.paused && device.savedDevice != nil ? L("Disconnected", "已断开") : L("Not connected", "未连接"))
    }

    /// 设置 › 桌面红绿灯. Without a light there is nothing to test or follow; 换一个 only matters
    /// once a light is remembered.
    private func lightItems() -> [NSMenuItem] {
        let name = device.connectedName
        let status = NSMenuItem(title: name != nil ? lightConnection
                                    : lightConnection + L(" · status in menu bar only", " · 状态只显示在菜单栏"),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        // A monochrome symbol, not a colored dot: those mean session states in this menu.
        status.image = Self.antenna[name != nil]
        let follow = NSMenuItem(title: L("Light Follows", "灯光跟随"), action: nil, keyEquivalent: "")
        follow.submenu = MenuStyle.menu()
        for (agent, title) in agentNames + [("none", L("None", "不跟随"))] {
            let item = NSMenuItem(title: title, action: #selector(setFollow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent
            item.state = agent == device.follow ? .on : .off
            follow.submenu?.addItem(keepOpen(item))
        }
        let test = NSMenuItem(title: L("Test Light", "测试灯光"), action: nil, keyEquivalent: "")
        test.submenu = MenuStyle.menu()
        for (title, mode) in [(L("Green On", "绿灯长亮"), 1), (L("Yellow On", "黄灯长亮"), 2), (L("Red On", "红灯长亮"), 3),
                              (L("All On", "三灯长亮"), 4), (L("Chase", "跑马灯"), 9), (L("All Off", "关灯"), 0)] {
            let item = NSMenuItem(title: title, action: #selector(testLight(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode
            test.submenu?.addItem(keepOpen(item))
        }
        let reconnect = NSMenuItem(title: device.paused ? L("Connect", "连接") : L("Reconnect", "重新连接"), action: #selector(reconnectLight),
                                   keyEquivalent: "r")
        let disconnect = NSMenuItem(title: L("Disconnect", "断开连接"), action: #selector(disconnectLight), keyEquivalent: "")
        let forget = NSMenuItem(title: L("Use a Different Light", "换一个红绿灯设备"), action: #selector(forgetLight), keyEquivalent: "")
        for item in [reconnect, disconnect, forget] {
            item.target = self
            keepOpen(item)
        }
        follow.isHidden = name == nil
        test.isHidden = name == nil
        disconnect.isHidden = name == nil
        forget.isHidden = name == nil && device.savedDevice == nil
        return [status, follow, test, reconnect, disconnect, forget]
    }

    private static let antenna: [Bool: NSImage] = [
        true: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)!,
        false: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash", accessibilityDescription: nil)!,
    ]

    @objc private func showMenu(_ sender: NSStatusBarButton) {
        status?.tooltip?.suspend()
        // The hooks may have been changed outside MacSignal.
        refreshAgents()
        rebuildMenu()
        processMenu.start(interval: interval)
        menuOpen = true
        // Session times tick while the menu is open (common modes include menu tracking).
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.agentMenu.refresh() }
        RunLoop.main.add(ticker, forMode: .common)
        defer {
            ticker.invalidate()
            menuOpen = false
            processMenu.stop()
            status?.tooltip?.resume()
        }
        let bounds = sender.bounds
        var x = bounds.midX
        if let window = sender.window {
            let cursor = sender.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(cursor) {
                x = cursor.x
            }
        }
        let y = sender.isFlipped ? bounds.maxY + 4 : bounds.minY - 4
        // popUp does not highlight the status item the way NSStatusItem.menu does.
        sender.highlight(true)
        defer { sender.highlight(false) }
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: sender)
    }

    // MARK: Agents

    /// Hooks written by MacSignal at another path run a stale command: rewrite them.
    private func refreshHooks() {
        for agent in Integration.all where agent.installed && !agent.current {
            do {
                try agent.install()
                agentLog("updated \(agent.id) hooks to \(Integration.binary)")
            } catch {
                agentLog("updating \(agent.id) hooks failed: \(error.localizedDescription)")
            }
        }
    }

    /// Shows or hides everything agent-related, and starts or stops the socket and the light with it.
    func refreshAgents() {
        let agents = Set(Integration.all.filter(\.installed).map(\.id))
        refreshStatusLine(claudeHooked: agents.contains("claude"))
        guard agents != hookedAgents else { return }
        let wasHooked = agentsHooked
        hookedAgents = agents
        // Also refreshes the desk light (receiver.onSessionsChange).
        guard agentsHooked != wasHooked else { return receiver.applySessions() }
        // The light starts after the socket and stops before it forgets the sessions.
        if agentsHooked {
            receiver.setActive(true)
            device.setActive(true)
        } else {
            device.setActive(false)
            receiver.setActive(false)
        }
    }

    /// Our statusLine reports quota from the terminal while 「AI 额度」 is checked and Claude Code
    /// is hooked up, and never replaces the user's own.
    private func refreshStatusLine(claudeHooked: Bool) {
        guard let claude = Integration.all.first(where: { $0.id == "claude" }) else { return }
        do {
            try claude.setStatusLine(StatusModule.quota.isChecked && claudeHooked)
        } catch {
            agentLog("updating the Claude Code statusLine failed: \(error.localizedDescription)")
        }
    }

    /// Reads Claude Code's quota while its cell can show: at launch, every 5 minutes, after waking
    /// and when 「AI 额度」 or Claude Code is checked (see ClaudeUsage).
    private func refreshClaudeUsage() {
        guard StatusModule.quota.isChecked, readings.quotaAgents.contains("claude") else { return }
        claudeUsage.refresh()
    }

    private func sessionsChanged() {
        let waiting = receiver.sessions.waitingIDs
        if !waiting.subtracting(knownWaiting).isEmpty { blinkRed() }
        knownWaiting = waiting
        updateStatus()
        if menuOpen { agentMenu.refresh() }
        syncMenu()
    }

    /// A new 「等待你确认」: the red lamp blinks three times, then stays lit.
    private func blinkRed() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        blinkTimer?.invalidate()
        var step = 0
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            step += 1
            self.redDimmed = step % 2 == 1
            if step >= 6 {
                timer.invalidate()
                self.blinkTimer = nil
            }
            self.updateStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
        redDimmed = true
        updateStatus()
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let agent = Integration.all.first(where: { $0.id == sender.representedObject as? String }) else { return }
        do {
            if agent.installed { try agent.uninstall() } else { try agent.install() }
            agentLog("\(agent.installed ? "installed" : "removed") \(agent.id) hooks in \(agent.hooksFile)")
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could Not Change the \(agent.name) Configuration", "修改 \(agent.name) 配置失败")
            alert.informativeText = error.localizedDescription
            closeMenu {
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        refreshAgents()
        if agent.id == "claude" { refreshClaudeUsage() }
    }

    @objc private func clearSessions() {
        receiver.sessions.entries.removeAll()
        receiver.applySessions()
    }

    @objc private func setFollow(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? String else { return }
        device.follow = agent
    }

    @objc private func testLight(_ sender: NSMenuItem) { device.setMode(sender.tag) }
    @objc private func reconnectLight() { device.reconnect() }
    @objc private func forgetLight() { device.reconnect(forget: true) }
    @objc private func disconnectLight() { device.disconnect() }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: agentLogPath)) }

    // MARK: Menu bar item

    @objc private func toggleSleepPrevention() {
        let enable = !sleepPrevention.isActive
        let result = sleepPrevention.setActive(enable)
        guard result == kIOReturnSuccess else {
            let alert = NSAlert()
            alert.messageText = enable ? L("Could Not Prevent Sleep", "无法防止睡眠") : L("Could Not Allow Sleep", "无法恢复睡眠")
            alert.informativeText = L("macOS returned error \(result).", "macOS 返回错误 \(result)。")
            closeMenu { alert.runModal() }
            return
        }
        updateStatus()
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let module = StatusModule(rawValue: sender.representedObject as? String ?? "") else { return }
        module.setChecked(!module.isChecked)
        if module == .quota {
            refreshStatusLine(claudeHooked: hookedAgents.contains("claude"))
            refreshClaudeUsage()
        }
        updateStatus()
    }

    @objc private func toggleNumbers() {
        showNumbers.toggle()
        UserDefaults.standard.set(showNumbers, forKey: "showNumbers")
        updateStatus()
    }

    /// What the menu bar modules read now.
    private var readings: Readings {
        var r = Readings(snapshot: snapshot)
        r.quotaAgents = ["codex", "claude"].filter { hookedAgents.contains($0) }
        r.quota = quota.byAgent
        r.lamps = agentsHooked ? receiver.sessions.counts.map { $0 > 0 } : nil
        r.redDimmed = redDimmed
        return r
    }

    private func updateStatus() {
        guard let status else { return }
        let active = sleepPrevention.isActive
        let r = readings
        let pending = pendingMouseTapReason()
        var lines = r.tooltipLines() + [L("Prevent Sleep: ", "防止睡眠：") + (active ? L("On", "开") : L("Off", "关"))]
        lines += MouseOption.allCases.filter { pending != nil && mouseOptions.contains($0) }
            .map { $0.title + L(": ", "：") + (pending?.tooltipText ?? "") }
        if agentsHooked {
            let counts = receiver.sessions.counts
            lines.append(L("Agents: \(counts[0]) waiting for you · \(counts[1]) working · \(counts[2]) done, unread",
                           "Agent：等待你确认 \(counts[0]) · 工作中 \(counts[1]) · 完成未读 \(counts[2])"))
            lines.append(TrafficLightDevice.title + L(": ", "：") + lightConnection)
        }
        lines.append(L("Click or right-click to open the menu", "点按或右键点按打开菜单"))
        status.update(cells: StatusModule.cells(r), preventingSleep: active, showNumbers: showNumbers,
                      tooltip: lines.joined(separator: "\n"))
        if menuOpen { syncDetails(r) }
    }

    /// The open menu follows the menu bar: sections come and go with the modules (checked in
    /// 设置 › 显示, an agent hooked up), rows follow the readings.
    private func syncDetails(_ r: Readings) {
        let shown = StatusModule.shown(r)
        if shown.contains(.light) != agentMenu.isShown {
            if shown.contains(.light) { agentMenu.add(to: menu, at: 0) } else { agentMenu.remove() }
        }
        guard details.modules == shown.filter({ $0 != .light }) else {
            let index = details.startIndex ?? sleepItem.flatMap { menu.items.firstIndex(of: $0) } ?? 0
            details.add(shown, readings: r, to: menu, at: index)
            processMenu.start(interval: interval)
            return
        }
        details.update(r)
    }

    @objc private func toggleMouseOption(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? MouseOption else { return }
        // Toggle the saved choice, not the tap state, so a pending choice can be turned off.
        if mouseOptions.contains(option) {
            setMouseOption(option, enabled: false)
            return
        }
        do {
            try mouseTap.start()
            setMouseOption(option, enabled: true)
        } catch MouseEventTap.StartError.permissionRequired {
            let alert = NSAlert()
            alert.messageText = L("Accessibility Access Required", "需要辅助功能权限")
            alert.informativeText = L("""
                Allow MacSignal in System Settings › Privacy & Security › Accessibility. “\(option.title)” turns on \
                once access is granted.

                If MacSignal is already in the list and turned on, remove it and add it again: a rebuilt version may \
                not match the earlier permission.
                """, """
                在「系统设置 › 隐私与安全性 › 辅助功能」里允许 MacSignal，获得权限后「\(option.title)」会自动打开。

                如果 MacSignal 已经在列表里并且已打开，把它移除后重新添加：重新构建的版本可能和之前的授权对不上。
                """)
            alert.addButton(withTitle: L("Open Settings", "打开设置"))
            alert.addButton(withTitle: L("Cancel", "取消"))
            closeMenu { [self] in
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                setMouseOption(option, enabled: true)
                openAccessibilitySettings()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could Not Turn On “\(option.title)”", "无法打开「\(option.title)」")
            alert.informativeText = L("macOS could not install the mouse event filter. Try again later.",
                                      "macOS 无法安装鼠标事件过滤器，请稍后再试。")
            closeMenu { alert.runModal() }
        }
    }

    /// Why a saved choice is on while the mouse event filter is not running.
    private func pendingMouseTapReason() -> MouseTapPending? {
        guard !mouseOptions.isEmpty, !mouseTap.isActive else { return nil }
        return AXIsProcessTrusted() ? .unavailable : .needsAccess
    }

    /// The toggles keep their short titles; why the filter is not running goes
    /// on its own line, once for all options, so the status never widens the menu.
    static func mouseOptionItems(enabled: Set<MouseOption>, pending: MouseTapPending?,
                                 target: AnyObject) -> [NSMenuItem] {
        var items = MouseOption.allCases.map { option in
            let toggle = NSMenuItem(title: option.title, action: #selector(toggleMouseOption(_:)),
                                    keyEquivalent: "")
            toggle.target = target
            toggle.representedObject = option
            // Mixed: enabled by the user, but not running yet.
            toggle.state = !enabled.contains(option) ? .off : pending != nil ? .mixed : .on
            return toggle
        }
        guard !enabled.isEmpty, let pending else { return items }
        let status = NSMenuItem(title: pending.statusText, action: nil, keyEquivalent: "")
        // Disabled for the muted color. No indentation: combined with the
        // checkmark column, any indentation level widens the menu.
        status.isEnabled = false
        items.append(status)
        if pending == .needsAccess {
            let grant = NSMenuItem(title: L("Open Accessibility Settings…", "打开辅助功能设置…"),
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = target
            items.append(grant)
        }
        return items
    }

    private func setMouseOption(_ option: MouseOption, enabled: Bool) {
        if enabled {
            mouseOptions.insert(option)
        } else {
            mouseOptions.remove(option)
        }
        UserDefaults.standard.set(enabled, forKey: option.defaultsKey)
        reconcileMouseTap()
    }

    /// Brings the tap in line with the saved choices. While a choice is on but
    /// the tap cannot run, retry periodically so granting access takes effect
    /// without reopening the menu or relaunching.
    private func reconcileMouseTap() {
        defer { updateStatus() }
        mouseTap.reversesScrolling = mouseOptions.contains(.classicScrolling)
        mouseTap.switchesDesktops = mouseOptions.contains(.desktopSwitching)
        guard !mouseOptions.isEmpty else {
            stopMouseTapRetry()
            mouseTap.stop()
            return
        }
        if !mouseTap.isActive {
            try? mouseTap.start()
        }
        if mouseTap.isActive {
            stopMouseTapRetry()
        } else if mouseTapRetry == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.reconcileMouseTap()
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            mouseTapRetry = timer
        }
    }

    private func stopMouseTapRetry() {
        mouseTapRetry?.invalidate()
        mouseTapRetry = nil
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        interval = RefreshInterval.validated(value.doubleValue)
        UserDefaults.standard.set(interval, forKey: "refreshInterval")
        // The open menu's process lists follow the new interval too.
        if menuOpen { processMenu.start(interval: interval) }
        // The existing baseline stays valid, so keep showing current readings.
        startSampling(rebaseline: false)
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func willSleep() { stopSampling() }
    @objc private func didWake() {
        startSampling(rebaseline: true)
        refreshClaudeUsage()
    }

    private func stopSampling() {
        generation += 1
        timer?.cancel()
        timer = nil
    }

    /// With `rebaseline`, counters are re-read immediately but not published,
    /// since a baseline alone has no rates; the first reading follows shortly.
    /// Otherwise the current baseline and on-screen readings are kept.
    private func startSampling(rebaseline: Bool) {
        stopSampling()
        let currentGeneration = generation
        let sampler = self.sampler
        if rebaseline {
            // Runs before the timer's first event on the same serial queue.
            queue.async {
                sampler.reset()
                _ = sampler.sample()
            }
        }
        let interval = self.interval
        let plan = RefreshInterval.initialSamplingPlan(interval: interval, rebaseline: rebaseline,
                                                       currentCPU: snapshot.cpu)
        let leeway = DispatchTimeInterval.milliseconds(Int(min(0.1, interval * 0.1) * 1000))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + plan.delay, repeating: interval, leeway: leeway)
        // Only read and written on the sampling queue.
        var quickRetries = plan.quickRetries
        // The handler retains the source until stopSampling cancels it.
        source.setEventHandler { [weak self] in
            let snapshot = sampler.sample()
            if quickRetries > 0, snapshot.cpu == nil {
                // CPU counters can stay frozen for about a second after the
                // baseline. Retry soon rather than leave CPU blank a full interval.
                quickRetries -= 1
                source.schedule(deadline: .now() + plan.delay, repeating: interval, leeway: leeway)
            } else {
                quickRetries = 0
            }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.snapshot = snapshot
                self.updateStatus()
            }
        }
        timer = source
        source.resume()
    }
}

/// Menu options that need the mouse event filter, in menu order.
enum MouseOption: CaseIterable {
    case classicScrolling, desktopSwitching

    var title: String {
        switch self {
        case .classicScrolling: return L("Classic Mouse Scrolling", "传统滚动")
        case .desktopSwitching: return L("Side Button Desktop Switching", "侧键切换桌面")
        }
    }

    var defaultsKey: String {
        switch self {
        case .classicScrolling: return "classicMouseScrolling"
        case .desktopSwitching: return "sideButtonDesktopSwitching"
        }
    }
}

/// Why a mouse option is selected but the mouse event filter is not running.
enum MouseTapPending {
    case needsAccess, unavailable

    var statusText: String {
        self == .needsAccess ? L("Needs Accessibility access", "需要辅助功能权限") : L("Unavailable, retrying", "暂不可用，正在重试")
    }

    var tooltipText: String {
        self == .needsAccess ? L("Waiting for Accessibility access", "等待辅助功能权限") : L("Unavailable, retrying", "暂不可用，正在重试")
    }
}
