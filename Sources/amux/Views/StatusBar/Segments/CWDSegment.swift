import AppKit

class CWDSegment: StatusBarSegment {
    let id = "cwd"
    let label = "Working Directory"
    let icon = "folder"
    let position = SegmentPosition.center
    let refreshInterval: TimeInterval = 3.0

    private let pathButton = NSButton()
    private let iconView = NSImageView()
    private var lastCwd: String?
    var shellPid: pid_t?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        iconView.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "Directory"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = dim
        iconView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathButton.title = ""
        pathButton.font = font
        pathButton.contentTintColor = Theme.tertiaryText
        pathButton.isBordered = false
        pathButton.bezelStyle = .accessoryBarAction
        pathButton.setButtonType(.momentaryChange)
        pathButton.target = self
        pathButton.action = #selector(copyPath)
        pathButton.alignment = .center
        if let cell = pathButton.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }

        let stack = NSStackView(views: [iconView, pathButton])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        return stack
    }

    func update() {
        guard let pid = shellPid else {
            pathButton.title = "~"
            lastCwd = nil
            return
        }
        if let cwd = ProcessHelper.cwd(of: pid) {
            let home = NSHomeDirectory()
            pathButton.title = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            lastCwd = cwd
        } else {
            pathButton.title = "~"
            lastCwd = nil
        }
    }

    var currentCwd: String? { lastCwd }

    @objc private func copyPath() {
        guard let cwd = lastCwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
        let original = pathButton.contentTintColor
        pathButton.contentTintColor = Theme.primaryText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pathButton.contentTintColor = original
        }
    }
}
