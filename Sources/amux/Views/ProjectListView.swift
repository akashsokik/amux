import AppKit

// MARK: - Delegate

protocol ProjectListViewDelegate: AnyObject {
    func projectListDidSelectProject(_ project: Project)
    func projectListDidRequestAddProject()
    func projectListDidRequestDeleteProject(_ project: Project)
    func projectListDidRequestRenameProject(_ project: Project)
    func projectListDidRequestOpenFolder(_ project: Project)
}

// MARK: - ProjectListView

class ProjectListView: NSView {

    weak var delegate: ProjectListViewDelegate?
    private var projectManager: ProjectManager!

    private var headerLabel: NSTextField!
    private var addButton: DimIconButton!
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var emptyStateLabel: NSTextField!

    private static let rowHeight: CGFloat = 34
    private static let cellID = NSUserInterfaceItemIdentifier("ProjectCell")

    // MARK: - Init

    init(projectManager: ProjectManager, sessionManager: SessionManager) {
        self.projectManager = projectManager
        super.init(frame: .zero)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Theme

    @objc private func themeDidChange() {
        headerLabel.textColor = Theme.tertiaryText
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        headerLabel = NSTextField(labelWithString: "PROJECTS")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = Theme.Fonts.label(size: 11)
        headerLabel.textColor = Theme.tertiaryText
        headerLabel.backgroundColor = .clear
        headerLabel.isBezeled = false
        headerLabel.isEditable = false
        headerLabel.isSelectable = false
        addSubview(headerLabel)

        addButton = DimIconButton()
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = ""
        addButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add Project"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        addButton.imagePosition = .imageOnly
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.toolTip = "Open folder as project"
        addButton.target = self
        addButton.action = #selector(addButtonClicked)
        addButton.refreshDimState()
        addSubview(addButton)

        emptyStateLabel = NSTextField(labelWithString: "No projects.\nClick + to open a folder.")
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.font = Theme.Fonts.body(size: 12)
        emptyStateLabel.textColor = Theme.quaternaryText
        emptyStateLabel.backgroundColor = .clear
        emptyStateLabel.isBezeled = false
        emptyStateLabel.isEditable = false
        emptyStateLabel.isSelectable = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 3
        emptyStateLabel.isHidden = true
        addSubview(emptyStateLabel)

        tableView = NSTableView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = ProjectListView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(tableViewClicked(_:))

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectCol"))
        col.isEditable = false
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        if #available(macOS 11.0, *) {
            tableView.style = .fullWidth
        }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

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
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 22),
            addButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 32),
            emptyStateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        updateEmptyState()
    }

    // MARK: - Public API

    func reloadProjects() {
        tableView.reloadData()
        let idx = projectManager.activeProjectIndex
        if idx >= 0 && idx < projectManager.projects.count {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateEmptyState()
    }

    func reloadSessions() {
        // No-op: sessions are no longer shown in the sidebar
    }

    // MARK: - Private

    private func updateEmptyState() {
        let isEmpty = projectManager.projects.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    // MARK: - Actions

    @objc private func addButtonClicked() {
        delegate?.projectListDidRequestAddProject()
    }

    @objc private func tableViewClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < projectManager.projects.count else { return }
        delegate?.projectListDidSelectProject(projectManager.projects[row])
    }

    @objc private func renameMenuItemClicked(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        delegate?.projectListDidRequestRenameProject(project)
    }

    @objc private func deleteMenuItemClicked(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        delegate?.projectListDidRequestDeleteProject(project)
    }

    @objc private func openFolderMenuItemClicked(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        delegate?.projectListDidRequestOpenFolder(project)
    }
}

// MARK: - NSTableViewDataSource

extension ProjectListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        projectManager.projects.count
    }
}

// MARK: - NSTableViewDelegate

extension ProjectListView: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < projectManager.projects.count else { return nil }
        let project = projectManager.projects[row]
        let isActive = (row == projectManager.activeProjectIndex)

        var cell =
            tableView.makeView(
                withIdentifier: ProjectListView.cellID, owner: self
            ) as? ProjectCellView

        if cell == nil {
            cell = ProjectCellView()
            cell?.identifier = ProjectListView.cellID
        }

        cell?.configure(project: project, isActive: isActive)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        ProjectListView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ProjectRowView()
    }
}

// MARK: - NSMenuDelegate

extension ProjectListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = tableView.clickedRow
        guard row >= 0, row < projectManager.projects.count else { return }
        let project = projectManager.projects[row]

        let openItem = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(openFolderMenuItemClicked(_:)),
            keyEquivalent: "")
        openItem.representedObject = project
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(
            title: "Rename",
            action: #selector(renameMenuItemClicked(_:)),
            keyEquivalent: "")
        renameItem.representedObject = project
        renameItem.target = self
        menu.addItem(renameItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(
            title: "Remove Project",
            action: #selector(deleteMenuItemClicked(_:)),
            keyEquivalent: "")
        deleteItem.representedObject = project
        deleteItem.target = self
        menu.addItem(deleteItem)
    }
}

// MARK: - ProjectCellView

private class ProjectCellView: NSView {
    private let colorDot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let highlightView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        wantsLayer = true

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.CornerRadius.element
        addSubview(highlightView)

        colorDot.translatesAutoresizingMaskIntoConstraints = false
        colorDot.wantsLayer = true
        colorDot.layer?.cornerRadius = 0
        addSubview(colorDot)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Theme.Fonts.body(size: 13)
        nameLabel.textColor = Theme.secondaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.truncatesLastVisibleLine = true
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            colorDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            colorDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorDot.widthAnchor.constraint(equalToConstant: 8),
            colorDot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: colorDot.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(project: Project, isActive: Bool) {
        self.isActive = isActive
        self.isHovered = false
        nameLabel.stringValue = project.displayName
        nameLabel.textColor = isActive ? Theme.primaryText : Theme.secondaryText
        nameLabel.font = isActive ? Theme.Fonts.headline(size: 13) : Theme.Fonts.body(size: 13)
        colorDot.layer?.backgroundColor = project.color.cgColor
        updateBackground()
    }

    private func updateBackground() {
        if isActive {
            highlightView.layer?.backgroundColor = Theme.activeBg.cgColor
        } else if isHovered {
            highlightView.layer?.backgroundColor = Theme.hoverBg.cgColor
        } else {
            highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }
}

// MARK: - ProjectRowView

private class ProjectRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
