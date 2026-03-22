import AppKit

class ExitCodeSegment: StatusBarSegment {
    let id = "exit-code"
    let label = "Exit Code"
    let icon = "exclamationmark.circle"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 0  // updated externally, not polled

    private let valueLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let stack = NSStackView()
    private var lastExitCode: Int32 = 0

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let red = NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)

        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "Exit Code"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = red
        iconView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        valueLabel.font = font
        valueLabel.textColor = red
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false

        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(valueLabel)
        stack.isHidden = true
        return stack
    }

    func setExitCode(_ code: Int32) {
        lastExitCode = code
        update()
    }

    func update() {
        if lastExitCode != 0 {
            valueLabel.stringValue = "\(lastExitCode)"
            stack.isHidden = false
        } else {
            valueLabel.stringValue = ""
            stack.isHidden = true
        }
    }
}
