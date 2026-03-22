import AppKit

class UptimeSegment: StatusBarSegment {
    let id = "uptime"
    let label = "Session Uptime"
    let icon = "clock"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 60.0

    private let valueLabel = NSTextField(labelWithString: "")
    private let startDate = Date()

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        valueLabel.font = font
        valueLabel.textColor = Theme.quaternaryText
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        return valueLabel
    }

    func update() {
        let elapsed = Int(Date().timeIntervalSince(startDate))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        if hours > 0 {
            valueLabel.stringValue = "\(hours)h \(minutes)m"
        } else {
            valueLabel.stringValue = "\(minutes)m"
        }
    }
}
