import AppKit

// MARK: - Worktree View

class WorktreeView: NSView {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var headerLabel: NSTextField!
    private var addButton: NSButton!
    private var emptyLabel: NSTextField!
    private var worktrees: [GitHelper.WorktreeInfo] = []
    private var currentCwd: String?

    var onOpenWorktree: ((String) -> Void)?
    var onCreateWorktree: ((String) -> Void)?

    private static let rowHeight: CGFloat = 22
    private static let cellID = NSUserInterfaceItemIdentifier("WorktreeCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(gitCommandDidFinish),
            name: GitHelper.commandDidFinishNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func themeDidChange() {
        headerLabel.font = Theme.Fonts.headline(size: 11)
        headerLabel.textColor = Theme.primaryText
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        addButton.contentTintColor = Theme.secondaryText
        tableView.reloadData()
    }

    @objc private func gitCommandDidFinish() {
        refresh(cwd: currentCwd)
    }

    private func setupUI() {
        wantsLayer = true

        // Header label
        headerLabel = NSTextField(labelWithString: "")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = Theme.Fonts.headline(size: 11)
        headerLabel.textColor = Theme.primaryText
        headerLabel.backgroundColor = .clear
        headerLabel.isBezeled = false
        headerLabel.isEditable = false
        headerLabel.isSelectable = false
        headerLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(headerLabel)

        // Add button
        addButton = NSButton(image: NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add worktree"
        )!, target: self, action: #selector(addWorktreeClicked))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.contentTintColor = Theme.secondaryText
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(addButton)

        // Empty state label
        emptyLabel = NSTextField(labelWithString: "Not a git repository")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.backgroundColor = .clear
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Table view
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = WorktreeView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.action = #selector(tableRowClicked)
        tableView.target = self
        tableView.menu = createContextMenu()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorktreeColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)

        // Scroll view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScroller = ThinScroller()
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),

            addButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Public

    func refresh(cwd: String?) {
        guard let cwd = cwd else {
            worktrees = []
            currentCwd = nil
            headerLabel.stringValue = ""
            updateVisibility()
            tableView.reloadData()
            return
        }

        currentCwd = cwd

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = GitHelper.listWorktrees(from: cwd)
            let repoName = GitHelper.repoRoot(from: cwd).map {
                URL(fileURLWithPath: $0).lastPathComponent.uppercased()
            } ?? ""

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.worktrees = results
                self.headerLabel.stringValue = repoName
                self.updateVisibility()
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Private

    private func updateVisibility() {
        let isEmpty = worktrees.isEmpty
        emptyLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    @objc private func tableRowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < worktrees.count else { return }
        onOpenWorktree?(worktrees[row].path)
    }

    @objc private func addWorktreeClicked() {
        guard let cwd = currentCwd else { return }

        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Enter a branch name for the new worktree:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = "branch-name"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let branchName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !branchName.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitHelper.addWorktree(from: cwd, branch: branchName)
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let newPath):
                    self.onCreateWorktree?(newPath)
                    self.refresh(cwd: self.currentCwd)
                case .failure(let error):
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Failed to Create Worktree"
                    errorAlert.informativeText = error.description
                    errorAlert.alertStyle = .warning
                    errorAlert.runModal()
                }
            }
        }
    }

    // MARK: - Context Menu

    private func createContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func removeWorktreeClicked(_ sender: NSMenuItem) {
        guard let cwd = currentCwd else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < worktrees.count else { return }
        let worktree = worktrees[row]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitHelper.removeWorktree(from: cwd, path: worktree.path)
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.refresh(cwd: self.currentCwd)
                case .failure(let error):
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Failed to Remove Worktree"
                    errorAlert.informativeText = error.description
                    errorAlert.alertStyle = .warning
                    errorAlert.runModal()
                }
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension WorktreeView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return worktrees.count
    }
}

// MARK: - NSTableViewDelegate

extension WorktreeView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < worktrees.count else { return nil }
        let worktree = worktrees[row]

        var cell = tableView.makeView(
            withIdentifier: WorktreeView.cellID,
            owner: self
        ) as? WorktreeCellView

        if cell == nil {
            cell = WorktreeCellView()
            cell?.identifier = WorktreeView.cellID
        }

        cell?.configure(worktree: worktree)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRowByItem item: Int) -> CGFloat {
        return WorktreeView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = false
        return rowView
    }
}

// MARK: - NSMenuDelegate

extension WorktreeView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < worktrees.count else { return }
        let worktree = worktrees[row]
        guard !worktree.isMain else { return }

        let removeItem = NSMenuItem(
            title: "Remove Worktree",
            action: #selector(removeWorktreeClicked(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
    }
}

// MARK: - Worktree Cell View

private class WorktreeCellView: NSView {
    private let iconView = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.font = Theme.Fonts.body(size: 12)
        branchLabel.textColor = Theme.secondaryText
        branchLabel.backgroundColor = .clear
        branchLabel.isBezeled = false
        branchLabel.isEditable = false
        branchLabel.isSelectable = false
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.maximumNumberOfLines = 1
        addSubview(branchLabel)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = Theme.Fonts.body(size: 10)
        pathLabel.textColor = Theme.tertiaryText
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            branchLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        branchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func configure(worktree: GitHelper.WorktreeInfo) {
        let branchName = worktree.branch ?? "(detached)"
        branchLabel.stringValue = branchName
        branchLabel.font = worktree.isCurrent
            ? Theme.Fonts.headline(size: 12)
            : Theme.Fonts.body(size: 12)
        branchLabel.textColor = worktree.isCurrent ? Theme.primaryText : Theme.secondaryText

        pathLabel.stringValue = worktree.path
        pathLabel.textColor = Theme.tertiaryText

        iconView.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        iconView.contentTintColor = worktree.isCurrent ? Theme.primary : Theme.tertiaryText
    }
}
