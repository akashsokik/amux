import AppKit

class PaneCountSegment: StatusBarSegment {
    let id = "pane-count"
    let label = "Pane Count"
    let icon = "rectangle.split.3x1"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 2.0

    private let valueLabel = NSTextField(labelWithString: "")
    var paneCountProvider: (() -> Int)?

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
        let count = paneCountProvider?() ?? 0
        valueLabel.stringValue = "\(count) pane\(count == 1 ? "" : "s")"
    }
}
