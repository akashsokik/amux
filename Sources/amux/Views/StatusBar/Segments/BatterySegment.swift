import AppKit
import IOKit.ps

class BatterySegment: StatusBarSegment {
    let id = "battery"
    let label = "Battery"
    let icon = "battery.100"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 30.0

    private let valueLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        iconView.image = NSImage(
            systemSymbolName: "battery.100",
            accessibilityDescription: "Battery"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = Theme.tertiaryText
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        valueLabel.font = font
        valueLabel.textColor = Theme.tertiaryText
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false

        let stack = HoverableSegmentStack(views: [iconView, valueLabel])
        stack.segmentIcon = iconView
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        return stack
    }

    func update() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any],
              let capacity = desc[kIOPSCurrentCapacityKey] as? Int else {
            valueLabel.stringValue = "--"
            return
        }
        let charging = (desc[kIOPSIsChargingKey] as? Bool) == true

        // Update battery icon based on level
        let symbolName: String
        if charging {
            symbolName = "battery.100.bolt"
        } else if capacity > 75 {
            symbolName = "battery.100"
        } else if capacity > 50 {
            symbolName = "battery.75"
        } else if capacity > 25 {
            symbolName = "battery.50"
        } else {
            symbolName = "battery.25"
        }
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Battery"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = capacity <= 20 ? NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1.0) : Theme.tertiaryText

        valueLabel.stringValue = "\(capacity)%"
    }
}
