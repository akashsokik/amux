import AppKit

class PaneCountSegment: StatusBarSegment {
    let id = "pane-count"
    let label = "Pane Count"
    let icon = "rectangle.split.3x1"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 2.0

    private let valueLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    var paneCountProvider: (() -> Int)?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        iconView.image = NSImage(
            systemSymbolName: "rectangle.split.3x1",
            accessibilityDescription: "Panes"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = dim
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
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
        let count = paneCountProvider?() ?? 0
        valueLabel.stringValue = "\(count)"
    }
}
