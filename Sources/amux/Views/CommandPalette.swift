import AppKit

// MARK: - Command Model

struct PaletteCommand {
    let category: String
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

        let overlay = CommandPaletteOverlay(frame: contentView.bounds, commands: commands)
        overlay.autoresizingMask = [.width, .height]
        overlay.onDismiss = { [weak self] in self?.dismiss() }
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)

        self.overlay = overlay
        overlay.activate()
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
    private var categoryFilterStack: NSStackView!
    private var categoryFilterHeightConstraint: NSLayoutConstraint!
    private var resultsHeightConstraint: NSLayoutConstraint!

    private enum PaletteRow {
        case categoryHeader(String)
        case command(PaletteCommand)
    }

    private var allCommands: [PaletteCommand]
    private var filteredCommands: [PaletteCommand]
    private var displayRows: [PaletteRow] = []
    private var selectedIndex: Int = 0  // index into displayRows, only selects .command rows
    private var activeCategory: String?

    private static let panelWidth: CGFloat = 600
    private static let maxResultsHeight: CGFloat = 300
    private static let commandRowHeight: CGFloat = 32
    private static let categoryHeaderHeight: CGFloat = 28
    private static let cellID = NSUserInterfaceItemIdentifier("PalCmd")
    private static let headerCellID = NSUserInterfaceItemIdentifier("PalCatHdr")

    init(frame: NSRect, commands: [PaletteCommand]) {
        self.allCommands = commands
        self.filteredCommands = commands
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        buildDisplayRows()
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

        let clipView = NSView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 8
        clipView.layer?.masksToBounds = true
        clipView.layer?.backgroundColor = Theme.background.cgColor
        panelView.addSubview(clipView)

        searchField = PaletteTextField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Type a command or category..."
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

        categoryFilterStack = NSStackView()
        categoryFilterStack.translatesAutoresizingMaskIntoConstraints = false
        categoryFilterStack.orientation = .horizontal
        categoryFilterStack.spacing = 6
        categoryFilterStack.alignment = .centerY
        categoryFilterStack.isHidden = true
        clipView.addSubview(categoryFilterStack)

        tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = CommandPaletteOverlay.commandRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        if #available(macOS 11.0, *) { tableView.style = .fullWidth }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("C"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
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

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.hoverBg.cgColor
        clipView.addSubview(footer)

        let footerSeparator = NSView()
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.wantsLayer = true
        footerSeparator.layer?.backgroundColor = Theme.borderPrimary.cgColor
        footer.addSubview(footerSeparator)

        let hint = NSTextField(labelWithString: "Up/Down navigate  |  Tab filter category  |  Enter execute  |  Esc close")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = Theme.quaternaryText
        hint.isBezeled = false
        hint.isEditable = false
        hint.isSelectable = false
        footer.addSubview(hint)

        let panelWidth = CommandPaletteOverlay.panelWidth
        let maxHeight = CommandPaletteOverlay.maxResultsHeight
        resultsHeightConstraint = scrollView.heightAnchor.constraint(
            equalToConstant: min(CGFloat(max(displayRows.count, 1)) * CommandPaletteOverlay.commandRowHeight, maxHeight)
        )
        categoryFilterHeightConstraint = categoryFilterStack.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            panelView.widthAnchor.constraint(equalToConstant: panelWidth),

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

            categoryFilterStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            categoryFilterStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 14),
            categoryFilterStack.trailingAnchor.constraint(lessThanOrEqualTo: clipView.trailingAnchor, constant: -14),
            categoryFilterHeightConstraint,

            scrollView.topAnchor.constraint(equalTo: categoryFilterStack.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            resultsHeightConstraint,

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),

            footerSeparator.topAnchor.constraint(equalTo: footer.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

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

    private func buildDisplayRows() {
        displayRows = []
        // Group filtered commands by category, preserving order of first appearance
        var seenCategories: [String] = []
        var grouped: [String: [PaletteCommand]] = [:]
        for cmd in filteredCommands {
            if grouped[cmd.category] == nil {
                seenCategories.append(cmd.category)
            }
            grouped[cmd.category, default: []].append(cmd)
        }
        for cat in seenCategories {
            displayRows.append(.categoryHeader(cat))
            for cmd in grouped[cat]! {
                displayRows.append(.command(cmd))
            }
        }
    }

    /// Returns the displayRows index of the first .command row, or -1
    private func firstCommandRowIndex() -> Int {
        displayRows.firstIndex(where: {
            if case .command = $0 { return true }
            return false
        }) ?? -1
    }

    private func filterCommands(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.lowercased()

        filteredCommands = allCommands.filter { command in
            let matchesActiveCategory = activeCategory.map {
                command.category.caseInsensitiveCompare($0) == .orderedSame
            } ?? true
            let matchesQuery =
                normalizedQuery.isEmpty
                || command.name.lowercased().contains(normalizedQuery)
                || command.category.lowercased().contains(normalizedQuery)
            return matchesActiveCategory && matchesQuery
        }

        buildDisplayRows()
        selectedIndex = firstCommandRowIndex()
        updateResultsHeight()
        tableView.reloadData()
        if selectedIndex >= 0 {
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    private func updateResultsHeight() {
        let maxHeight = CommandPaletteOverlay.maxResultsHeight
        var totalHeight: CGFloat = 0
        for row in displayRows {
            switch row {
            case .categoryHeader: totalHeight += CommandPaletteOverlay.categoryHeaderHeight
            case .command: totalHeight += CommandPaletteOverlay.commandRowHeight
            }
        }
        if displayRows.isEmpty { totalHeight = CommandPaletteOverlay.commandRowHeight }
        resultsHeightConstraint.constant = min(totalHeight, maxHeight)
    }

    private func tryApplyingCategoryFilter() -> Bool {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }

        let categories = Array(Set(allCommands.map(\.category))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        let exactMatch = categories.first {
            $0.caseInsensitiveCompare(query) == .orderedSame
        }
        let prefixMatches = categories.filter {
            $0.lowercased().hasPrefix(query.lowercased())
        }

        guard let category = exactMatch ?? (prefixMatches.count == 1 ? prefixMatches[0] : nil) else {
            return false
        }

        activeCategory = category
        searchField.stringValue = ""
        updateActiveCategoryUI()
        filterCommands("")
        return true
    }

    private func clearCategoryFilter() {
        activeCategory = nil
        updateActiveCategoryUI()
        filterCommands(searchField.stringValue)
    }

    private func updateActiveCategoryUI() {
        for view in categoryFilterStack.arrangedSubviews {
            categoryFilterStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let activeCategory else {
            categoryFilterHeightConstraint.constant = 0
            categoryFilterStack.isHidden = true
            return
        }

        categoryFilterStack.isHidden = false
        categoryFilterHeightConstraint.constant = 20

        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 3
        pill.layer?.backgroundColor = Theme.elevated.cgColor
        let pillLabel = NSTextField(labelWithString: activeCategory.uppercased())
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        pillLabel.textColor = Theme.tertiaryText
        pillLabel.backgroundColor = .clear
        pillLabel.isBezeled = false
        pillLabel.isEditable = false
        pillLabel.isSelectable = false
        pill.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            pillLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            pillLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
        ])
        categoryFilterStack.addArrangedSubview(pill)

        let hint = NSTextField(labelWithString: "Backspace clears filter")
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = Theme.quaternaryText
        hint.isBezeled = false
        hint.isEditable = false
        hint.isSelectable = false
        categoryFilterStack.addArrangedSubview(hint)
    }

    private func moveUp() {
        guard !displayRows.isEmpty else { return }
        var idx = selectedIndex - 1
        while idx >= 0 {
            if case .command = displayRows[idx] { break }
            idx -= 1
        }
        guard idx >= 0 else { return }
        selectedIndex = idx
        tableView.reloadData()
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func moveDown() {
        guard !displayRows.isEmpty else { return }
        var idx = selectedIndex + 1
        while idx < displayRows.count {
            if case .command = displayRows[idx] { break }
            idx += 1
        }
        guard idx < displayRows.count else { return }
        selectedIndex = idx
        tableView.reloadData()
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func executeSelected() {
        guard selectedIndex >= 0, selectedIndex < displayRows.count,
              case .command(let command) = displayRows[selectedIndex] else { return }
        onDismiss?()
        command.action()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < displayRows.count else { return }
        if case .command = displayRows[row] {
            selectedIndex = row
            executeSelected()
        }
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
        if sel == #selector(NSResponder.insertTab(_:)) {
            if !tryApplyingCategoryFilter() {
                NSSound.beep()
            }
            return true
        }
        if sel == #selector(NSResponder.deleteBackward(_:)),
           searchField.stringValue.isEmpty,
           activeCategory != nil {
            clearCategoryFilter()
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) { executeSelected(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { onDismiss?(); return true }
        return false
    }
}

// MARK: - NSTableViewDataSource

extension CommandPaletteOverlay: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }
}

// MARK: - NSTableViewDelegate

extension CommandPaletteOverlay: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayRows.count else { return nil }

        switch displayRows[row] {
        case .categoryHeader(let category):
            var header = tableView.makeView(withIdentifier: CommandPaletteOverlay.headerCellID, owner: nil) as? PaletteCategoryHeaderView
            if header == nil {
                header = PaletteCategoryHeaderView()
                header?.identifier = CommandPaletteOverlay.headerCellID
            }
            header?.configure(category: category)
            return header

        case .command(let command):
            let isSelected = (row == selectedIndex)
            var cell = tableView.makeView(withIdentifier: CommandPaletteOverlay.cellID, owner: nil) as? PaletteCellView
            if cell == nil {
                cell = PaletteCellView()
                cell?.identifier = CommandPaletteOverlay.cellID
            }
            cell?.configure(
                name: command.name,
                shortcut: command.shortcut,
                icon: command.icon,
                isSelected: isSelected
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < displayRows.count else { return CommandPaletteOverlay.commandRowHeight }
        switch displayRows[row] {
        case .categoryHeader: return CommandPaletteOverlay.categoryHeaderHeight
        case .command: return CommandPaletteOverlay.commandRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = false
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < displayRows.count else { return false }
        if case .command = displayRows[row] { return true }
        return false
    }
}

// MARK: - Category Header View

private class PaletteCategoryHeaderView: NSView {
    private let pillLabel = NSTextField(labelWithString: "")
    private let separatorLine = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let pillContainer = NSView()
        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.wantsLayer = true
        pillContainer.layer?.cornerRadius = 3
        pillContainer.layer?.backgroundColor = Theme.elevated.cgColor
        addSubview(pillContainer)

        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        pillLabel.textColor = Theme.tertiaryText
        pillLabel.backgroundColor = .clear
        pillLabel.isBezeled = false
        pillLabel.isEditable = false
        pillLabel.isSelectable = false
        pillLabel.alignment = .center
        pillContainer.addSubview(pillLabel)

        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.borderSecondary.cgColor
        addSubview(separatorLine)

        NSLayoutConstraint.activate([
            pillContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pillContainer.centerYAnchor.constraint(equalTo: centerYAnchor),

            pillLabel.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 7),
            pillLabel.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -7),
            pillLabel.topAnchor.constraint(equalTo: pillContainer.topAnchor, constant: 2),
            pillLabel.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor, constant: -2),

            separatorLine.leadingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: 8),
            separatorLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            separatorLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    func configure(category: String) {
        pillLabel.stringValue = category.uppercased()
    }
}

// MARK: - Cell View

private class PaletteCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let highlightView = NSView()
    private let shortcutStack = NSStackView()

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
        iconView.contentTintColor = Theme.tertiaryText
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        shortcutStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutStack.orientation = .horizontal
        shortcutStack.spacing = 3
        shortcutStack.alignment = .centerY
        addSubview(shortcutStack)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutStack.leadingAnchor, constant: -12),

            shortcutStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(name: String, shortcut: String, icon: String, isSelected: Bool) {
        nameLabel.stringValue = name
        iconView.image = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        highlightView.layer?.backgroundColor = isSelected ? Theme.activeBg.cgColor : NSColor.clear.cgColor
        nameLabel.textColor = isSelected ? Theme.primaryText : Theme.secondaryText
        iconView.contentTintColor = isSelected ? Theme.primaryText : Theme.tertiaryText

        for view in shortcutStack.arrangedSubviews {
            shortcutStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !shortcut.isEmpty else { return }
        for part in shortcut.components(separatedBy: "+") {
            shortcutStack.addArrangedSubview(PaletteKeyBadge(text: part))
        }
    }
}

// MARK: - Search Text Field

private class PaletteTextField: NSTextField {
    override func cancelOperation(_ sender: Any?) {
        CommandPaletteController.shared.dismiss()
    }
}

// MARK: - Key Badge (shortcut keys only, no neon)

private class PaletteKeyBadge: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = Theme.elevated.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = Theme.tertiaryText
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
