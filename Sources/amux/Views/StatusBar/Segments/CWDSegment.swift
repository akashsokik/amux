import AppKit

class CWDSegment: StatusBarSegment {
    let id = "cwd"
    let label = "Working Directory"
    let icon = "folder"
    let position = SegmentPosition.center
    let refreshInterval: TimeInterval = 0  // driven by Ghostty callbacks, not polling

    private let pathButton = NSButton()
    private let iconView = NSImageView()
    private(set) var currentCwd: String?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        iconView.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "Directory"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = Theme.tertiaryText
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

        let stack = HoverableSegmentStack(views: [iconView, pathButton])
        stack.segmentIcon = iconView
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        return stack
    }

    func setCwd(_ cwd: String?) {
        currentCwd = cwd
        update()
    }

    func update() {
        guard let cwd = currentCwd else {
            pathButton.title = "~"
            return
        }
        let home = NSHomeDirectory()
        pathButton.title = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    @objc private func copyPath() {
        guard let cwd = currentCwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
        let original = pathButton.contentTintColor
        pathButton.contentTintColor = Theme.primaryText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pathButton.contentTintColor = original
        }
    }
}
