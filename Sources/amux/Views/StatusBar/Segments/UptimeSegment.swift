import AppKit

class UptimeSegment: StatusBarSegment {
    let id = "uptime"
    let label = "Session Uptime"
    let icon = "clock"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 30.0

    private let valueLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let startDate = Date()

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        iconView.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "Uptime"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = dim
        iconView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        valueLabel.font = font
        valueLabel.textColor = dim
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false

        iconView.alphaValue = 0.5

        let stack = HoverableSegmentStack(views: [iconView, valueLabel])
        stack.segmentIcon = iconView
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        return stack
    }

    func update() {
        let elapsed = Int(Date().timeIntervalSince(startDate))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            valueLabel.stringValue = "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            valueLabel.stringValue = "\(minutes)m"
        } else {
            valueLabel.stringValue = "\(seconds)s"
        }
    }
}
