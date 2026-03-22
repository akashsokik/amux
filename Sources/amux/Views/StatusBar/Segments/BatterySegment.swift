import AppKit
import IOKit.ps

class BatterySegment: StatusBarSegment {
    let id = "battery"
    let label = "Battery"
    let icon = "battery.100"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 30.0

    private let valueLabel = NSTextField(labelWithString: "")

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
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any],
              let capacity = desc[kIOPSCurrentCapacityKey] as? Int else {
            valueLabel.stringValue = "BAT --"
            return
        }
        let charging = (desc[kIOPSIsChargingKey] as? Bool) == true
        valueLabel.stringValue = "BAT \(capacity)%\(charging ? "+" : "")"
    }
}
