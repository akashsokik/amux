import AppKit

class ProcessSegment: StatusBarSegment {
    let id = "process"
    let label = "Process"
    let icon = "terminal"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 3.0

    private let nameLabel = NSTextField(labelWithString: "")
    var shellPid: pid_t?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        nameLabel.font = font
        nameLabel.textColor = Theme.quaternaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80).isActive = true
        return nameLabel
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
