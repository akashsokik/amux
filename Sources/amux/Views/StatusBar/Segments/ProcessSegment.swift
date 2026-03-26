import AppKit

class ProcessSegment: StatusBarSegment {
    let id = "process"
    let label = "Process"
    let icon = "terminal"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 3.0

    private let nameLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    var shellPid: pid_t?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        iconView.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Process"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = Theme.tertiaryText
        iconView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        nameLabel.font = font
        nameLabel.textColor = Theme.tertiaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80).isActive = true

        let stack = HoverableSegmentStack(views: [iconView, nameLabel])
        stack.segmentIcon = iconView
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        return stack
    }

    func update() {
        guard let pid = shellPid else {
            nameLabel.stringValue = "shell"
            return
        }
        let shellName = ProcessHelper.name(of: pid) ?? "shell"
        if let fgPid = ProcessHelper.foregroundChild(of: pid),
           let fgName = ProcessHelper.name(of: fgPid) {
            nameLabel.stringValue = fgName
        } else {
            nameLabel.stringValue = shellName
        }
    }
}
