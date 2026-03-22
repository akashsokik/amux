import AppKit

class GitSegment: StatusBarSegment {
    let id = "git"
    let label = "Git Branch"
    let icon = "arrow.triangle.branch"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 5.0  // git dirty check still polls

    private let container = NSStackView()
    private let dirtyDot = NSView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")

    private var currentCwd: String?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 2.5
        dirtyDot.layer?.backgroundColor = NSColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1.0).cgColor
        dirtyDot.isHidden = true
        dirtyDot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dirtyDot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        branchIcon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Branch"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        branchIcon.contentTintColor = dim
        branchIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        branchIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        branchLabel.font = font
        branchLabel.textColor = dim
        branchLabel.backgroundColor = .clear
        branchLabel.isBezeled = false
        branchLabel.isEditable = false
        branchLabel.isSelectable = false
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100).isActive = true

        container.orientation = .horizontal
        container.spacing = 4
        container.alignment = .centerY
        container.addArrangedSubview(dirtyDot)
        container.addArrangedSubview(branchIcon)
        container.addArrangedSubview(branchLabel)

        return container
    }

    func setCwd(_ cwd: String?) {
        currentCwd = cwd
        update()
    }

    func update() {
        guard let cwd = currentCwd,
              let branch = ProcessHelper.gitBranch(at: cwd) else {
            container.isHidden = true
            return
        }
        container.isHidden = false
        branchLabel.stringValue = branch
        dirtyDot.isHidden = !ProcessHelper.gitIsDirty(at: cwd)
    }
}
