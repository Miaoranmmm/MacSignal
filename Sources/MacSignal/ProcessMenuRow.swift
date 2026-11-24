import AppKit

final class ProcessMenuRow: NSView {
    static let width: CGFloat = 280
    static let height: CGFloat = 24
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private lazy var hoverTooltip = HoverTooltip(view: self)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        // As wide as the menu, which is as wide as its widest row.
        autoresizingMask = [.width]
        let font = MenuStyle.rowFont
        nameLabel.font = font
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = font
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        addSubview(nameLabel)
        addSubview(valueLabel)
        update(name: "—", value: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(name: String, value: String, pid: pid_t? = nil) {
        nameLabel.stringValue = name
        valueLabel.stringValue = value
        layoutLabels()
        hoverTooltip.update(pid.map { "\(name) (PID \($0))" })
    }

    /// The width that shows the name and value in full (at least the standard width).
    var fittingWidth: CGFloat {
        let name = ceil(nameLabel.cell?.cellSize.width ?? 0)
        let value = valueLabel.stringValue.isEmpty ? 0 : ceil(valueLabel.cell?.cellSize.width ?? 0) + 6
        return max(Self.width, MenuStyle.titleX - 2 + name + value + 16)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutLabels()
    }

    private func layoutLabels() {
        let nameX = bounds.minX + MenuStyle.titleX - 2
        let right = bounds.maxX - 16
        // NSTextField's intrinsic width excludes the cell's horizontal insets.
        // Use the actual cell size so right-aligned suffixes are not clipped.
        let fittingWidth = valueLabel.cell?.cellSize.width ?? valueLabel.intrinsicContentSize.width
        let valueWidth = valueLabel.stringValue.isEmpty ? 0 : ceil(fittingWidth)
        let valueX = right - min(valueWidth, max(0, right - nameX))
        let gap: CGFloat = valueWidth > 0 ? 6 : 0
        nameLabel.frame = NSRect(x: nameX, y: bounds.minY + 3,
                                 width: max(0, valueX - gap - nameX), height: 18)
        valueLabel.frame = NSRect(x: valueX, y: bounds.minY + 3,
                                  width: max(0, right - valueX), height: 18)
    }

    func setTooltipActive(_ active: Bool) {
        if active { hoverTooltip.resume() } else { hoverTooltip.suspend() }
    }
}
