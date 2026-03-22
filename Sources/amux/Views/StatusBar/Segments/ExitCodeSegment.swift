import AppKit

class ExitCodeSegment: StatusBarSegment {
    let id = "exit-code"
    let label = "Exit Code"
    let icon = "exclamationmark.circle"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 0  // updated externally, not polled

    private let valueLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private var lastExitCode: Int32 = 0

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        valueLabel.font = font
        valueLabel.textColor = NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func setExitCode(_ code: Int32) {
        lastExitCode = code
        update()
    }

    func update() {
        if lastExitCode != 0 {
            valueLabel.stringValue = "exit \(lastExitCode)"
            container.isHidden = false
        } else {
            valueLabel.stringValue = ""
            container.isHidden = true
        }
    }
}
