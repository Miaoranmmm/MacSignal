import AppKit
import MacSignalCore

/// Samples process rankings only while a menu opening is active.
final class ProcessMenuContent {
    static var sampling: String { L("Sampling…", "采样中…") }
    static var unavailable: String { L("Unavailable", "不可用") }
    private let queue = DispatchQueue(label: "MacSignal.processes", qos: .utility)
    private let capture: () -> [pid_t: ProcessSample]?
    private var cpuRows: [ProcessMenuRow] = []
    private var memoryRows: [ProcessMenuRow] = []
    private var work: DispatchWorkItem?
    private var generation = 0

    init(capture: @escaping () -> [pid_t: ProcessSample]? = ProcessSampler.capture) {
        self.capture = capture
    }

    /// 「CPU 占用」 and 「内存占用」, each a heading, three rows and a separator. A section not asked
    /// for is left out and not sampled.
    func sections(cpu: Bool, memory: Bool) -> [NSMenuItem] {
        cpuRows = cpu ? Self.rows() : []
        memoryRows = memory ? Self.rows() : []
        return [(StatusModule.cpu.menuTitle, cpuRows), (StatusModule.memory.menuTitle, memoryRows)].flatMap { title, rows in
            rows.isEmpty ? [] : [Self.heading(title)] + rows.map(Self.item) + [.separator()]
        }
    }

    var isEmpty: Bool { cpuRows.isEmpty && memoryRows.isEmpty }

    /// A section title. A custom view keeps the normal label color even though this
    /// informational menu item is disabled and cannot be selected. Every section of the
    /// menu and of 设置 uses it (macOS 14's section headers would drop macOS 13).
    static func heading(_ title: String) -> NSMenuItem {
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let headingView = NSView(frame: NSRect(x: 0, y: 0, width: ProcessMenuRow.width, height: ProcessMenuRow.height))
        let label = NSTextField(labelWithString: title)
        // An NSTextField draws its text 2 pt in from its frame: line up with the item titles.
        label.frame = NSRect(x: MenuStyle.titleX - 2, y: 3, width: ProcessMenuRow.width - MenuStyle.titleX - 14, height: 19)
        label.font = MenuStyle.headingFont
        label.textColor = .secondaryLabelColor
        headingView.addSubview(label)
        heading.view = headingView
        heading.isEnabled = false
        return heading
    }

    private static func rows() -> [ProcessMenuRow] {
        (0..<3).map { index in
            let row = ProcessMenuRow()
            if index == 0 { row.update(name: sampling, value: "") }
            return row
        }
    }

    /// A disabled item showing `row`.
    static func item(_ row: ProcessMenuRow) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = row
        return item
    }

    func start(interval: TimeInterval = 1) {
        stop()
        guard !isEmpty else { return }
        for row in cpuRows + memoryRows { row.setTooltipActive(true) }
        scheduleSample(previous: nil, delay: 0,
                       interval: RefreshInterval.validated(interval), request: generation)
    }

    private func scheduleSample(previous: [pid_t: ProcessSample]?, delay: TimeInterval,
                                interval: TimeInterval, request: Int) {
        let capture = self.capture
        let task = DispatchWorkItem { [weak self] in
            let current = capture()
            let cpu = current.flatMap { sample in
                previous.map { ProcessSampler.topCPU(previous: $0, current: sample) }
            }
            // Menus track in their own run-loop mode. Main-queue work alone can
            // be delayed until after the menu closes.
            RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
                guard let self, self.generation == request else { return }
                if let current {
                    self.updateMemoryRows(current)
                    if let cpu {
                        self.updateCPURows(cpu)
                    } else {
                        self.reset(self.cpuRows, message: Self.sampling)
                    }
                } else {
                    self.reset(self.cpuRows, message: Self.unavailable)
                    self.reset(self.memoryRows, message: Self.unavailable)
                }
                let nextDelay = previous == nil && current != nil ? min(0.4, interval) : interval
                self.scheduleSample(previous: current, delay: nextDelay,
                                    interval: interval, request: request)
            }
        }
        work = task
        queue.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func reset(_ rows: [ProcessMenuRow], message: String) {
        for (index, row) in rows.enumerated() {
            row.update(name: index == 0 ? message : "—", value: "")
        }
    }

    private func updateCPURows(_ cpu: [ProcessCPUUsage]) {
        for (index, row) in cpuRows.enumerated() {
            guard index < cpu.count else {
                row.update(name: index == 0 ? Self.unavailable : "—", value: "")
                continue
            }
            let usage = cpu[index]
            row.update(name: ProcessDisplayName.name(for: usage.process.pid),
                       value: String(format: "%.1f%%", usage.percent),
                       pid: usage.process.pid)
        }
    }

    private func updateMemoryRows(_ samples: [pid_t: ProcessSample]) {
        let top = ProcessSampler.topMemory(samples)
        for (index, row) in memoryRows.enumerated() {
            guard index < top.count else {
                row.update(name: index == 0 ? Self.unavailable : "—", value: "")
                continue
            }
            let process = top[index]
            row.update(name: ProcessDisplayName.name(for: process.pid),
                       value: ByteCountFormatter.string(fromByteCount: Int64(clamping: process.memoryBytes),
                                                        countStyle: .memory),
                       pid: process.pid)
        }
    }

    func stop() {
        generation += 1
        work?.cancel()
        work = nil
        for row in cpuRows + memoryRows { row.setTooltipActive(false) }
    }

    deinit { work?.cancel() }
}
