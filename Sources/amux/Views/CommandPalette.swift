import AppKit

// MARK: - Command Model

struct PaletteCommand {
    let name: String
    let shortcut: String
    let icon: String
    let action: () -> Void
}

// MARK: - Command Palette (overlay-based, same window)

class CommandPaletteController {
    static let shared = CommandPaletteController()

    private var overlay: CommandPaletteOverlay?
    var isVisible: Bool { overlay != nil }

    /// The list of commands, set by AppDelegate before showing.
    var commands: [PaletteCommand] = []

    func toggle(in window: NSWindow) {
        if isVisible { dismiss() } else { show(in: window) }
    }

    func show(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        dismiss()

        let ov = CommandPaletteOverlay(frame: contentView.bounds, commands: commands)
        ov.autoresizingMask = [.width, .height]
        ov.onDismiss = { [weak self] in self?.dismiss() }
        contentView.addSubview(ov, positioned: .above, relativeTo: nil)

        overlay = ov
        ov.activate()
    }

    func dismiss() {
        overlay?.removeFromSuperview()
        overlay = nil
    }
}

// MARK: - Overlay View

private class CommandPaletteOverlay: NSView {
    var onDismiss: (() -> Void)?

    private var panelView: NSView!
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    private var allCommands: [PaletteCommand]
    private var filteredCommands: [PaletteCommand]
    private var selectedIndex: Int = 0

    private static let panelWidth: CGFloat = 520
    private static let maxResultsHeight: CGFloat = 380
    private static let rowHeight: CGFloat = 32
    private static let cellID = NSUserInterfaceItemIdentifier("PalCmd")

    init(frame: NSRect, commands: [PaletteCommand]) {
        self.allCommands = commands
        self.filteredCommands = commands
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        setupPanel()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupPanel() {
        panelView = NSView()
        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.wantsLayer = true
        panelView.layer?.backgroundColor = Theme.background.cgColor
        panelView.layer?.cornerRadius = 8
        panelView.layer?.borderWidth = 1
        panelView.layer?.borderColor = Theme.borderSecondary.cgColor
        panelView.layer?.masksToBounds = false
        panelView.shadow = NSShadow()
        panelView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.5).cgColor
        panelView.layer?.shadowRadius = 20
        panelView.layer?.shadowOffset = NSSize(width: 0, height: -8)
        panelView.layer?.shadowOpacity = 1
        addSubview(panelView)

        // Clip container (separate from shadow layer)
        let clipView = NSView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 8
        clipView.layer?.masksToBounds = true
        clipView.layer?.backgroundColor = Theme.background.cgColor
        panelView.addSubview(clipView)

        // Search field
        searchField = PaletteTextField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Type a command..."
        searchField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        searchField.textColor = Theme.primaryText
        searchField.backgroundColor = .clear
        searchField.drawsBackground = false
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.delegate = self
        clipView.addSubview(searchField)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.borderPrimary.cgColor
        clipView.addSubview(separator)

        // Results
        tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = CommandPaletteOverlay.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        if #available(macOS 11.0, *) { tableView.style = .fullWidth }

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("C"))
        col.isEditable = false
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        clipView.addSubview(scrollView)

        // Footer
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.hoverBg.cgColor
        clipView.addSubview(footer)

        let footerSep = NSView()
        footerSep.translatesAutoresizingMaskIntoConstraints = false
        footerSep.wantsLayer = true
        footerSep.layer?.backgroundColor = Theme.borderPrimary.cgColor
        footer.addSubview(footerSep)

        let hint = NSTextField(labelWithString: "Up/Down navigate  |  Enter execute  |  Esc close")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = Theme.quaternaryText
        hint.isBezeled = false
        hint.isEditable = false
        footer.addSubview(hint)

        let pw = CommandPaletteOverlay.panelWidth
        let maxH = CommandPaletteOverlay.maxResultsHeight

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            panelView.widthAnchor.constraint(equalToConstant: pw),

            clipView.topAnchor.constraint(equalTo: panelView.topAnchor),
            clipView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            scrollView.heightAnchor.constraint(
                equalToConstant: min(CGFloat(allCommands.count) * CommandPaletteOverlay.rowHeight, maxH)
            ),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),

            footerSep.topAnchor.constraint(equalTo: footer.topAnchor),
            footerSep.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerSep.heightAnchor.constraint(equalToConstant: 1),

            hint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
        ])
    }

    func activate() {
        window?.makeFirstResponder(searchField)
        tableView.reloadData()
    }

    // MARK: - Click backdrop to dismiss

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !panelView.frame.contains(local) {
            onDismiss?()
        }
    }

    // MARK: - Filter

    private func filterCommands(_ query: String) {
        if query.isEmpty {
            filteredCommands = allCommands
        } else {
            let q = query.lowercased()
            filteredCommands = allCommands.filter { $0.name.lowercased().contains(q) }
        }
        selectedIndex = filteredCommands.isEmpty ? -1 : 0
        tableView.reloadData()
        if selectedIndex >= 0 { tableView.scrollRowToVisible(0) }
    }

    private func moveUp() {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        tableView.reloadData()
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func moveDown() {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = min(filteredCommands.count - 1, selectedIndex + 1)
        tableView.reloadData()
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func executeSelected() {
        guard selectedIndex >= 0, selectedIndex < filteredCommands.count else { return }
        let cmd = filteredCommands[selectedIndex]
        onDismiss?()
        cmd.action()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredCommands.count else { return }
        selectedIndex = row
        executeSelected()
    }
}

// MARK: - NSTextFieldDelegate

extension CommandPaletteOverlay: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        filterCommands(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.moveUp(_:)) { moveUp(); return true }
        if sel == #selector(NSResponder.moveDown(_:)) { moveDown(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { executeSelected(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { onDismiss?(); return true }
        return false
    }
}

// MARK: - NSTableViewDataSource

extension CommandPaletteOverlay: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredCommands.count
    }
}

// MARK: - NSTableViewDelegate

extension CommandPaletteOverlay: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredCommands.count else { return nil }
        let cmd = filteredCommands[row]
        let selected = (row == selectedIndex)

        var cell = tableView.makeView(withIdentifier: CommandPaletteOverlay.cellID, owner: nil) as? PaletteCellView
        if cell == nil {
            cell = PaletteCellView()
            cell?.identifier = CommandPaletteOverlay.cellID
        }
        cell?.configure(name: cmd.name, shortcut: cmd.shortcut, icon: cmd.icon, isSelected: selected)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return CommandPaletteOverlay.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = NSTableRowView()
        rv.isEmphasized = false
        return rv
    }
}

// MARK: - Cell View

private class PaletteCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let highlightView = NSView()
    private let badgeStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 4
        addSubview(highlightView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Theme.quaternaryText
        iconView.alphaValue = 0.5
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 2
        badgeStack.alignment = .centerY
        addSubview(badgeStack)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeStack.leadingAnchor, constant: -12),

            badgeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badgeStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(name: String, shortcut: String, icon: String, isSelected: Bool) {
        nameLabel.stringValue = name
        iconView.image = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        )
        highlightView.layer?.backgroundColor = isSelected ? Theme.activeBg.cgColor : NSColor.clear.cgColor
        nameLabel.textColor = isSelected ? Theme.primaryText : Theme.secondaryText
        iconView.contentTintColor = isSelected ? Theme.primaryText : Theme.quaternaryText
        iconView.alphaValue = isSelected ? 1.0 : 0.5

        // Rebuild shortcut pills
        badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !shortcut.isEmpty else { return }
        for part in shortcut.components(separatedBy: "+") {
            badgeStack.addArrangedSubview(makeKeyBadge(part))
        }
    }

    private func makeKeyBadge(_ key: String) -> NSView {
        let label = NSTextField(labelWithString: key)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = Theme.tertiaryText
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.layer?.backgroundColor = Theme.elevated.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
        ])

        return badge
    }
}

// MARK: - Search Text Field

private class PaletteTextField: NSTextField {
    override func cancelOperation(_ sender: Any?) {
        CommandPaletteController.shared.dismiss()
    }
}
