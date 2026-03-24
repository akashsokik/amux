import AppKit

protocol SidebarViewDelegate: AnyObject {
    func sidebarDidSelectSession(_ session: Session)
    func sidebarDidRequestNewSession()
    func sidebarDidRequestDeleteSession(_ session: Session)
    func sidebarDidRequestRenameSession(_ session: Session)
    func sidebarCurrentDirectory() -> String?
    func sidebarDidRequestOpenWorktree(path: String)
    func sidebarDidSelectFile(path: String)
    func sidebarDidRequestFocusAgentPane(paneID: UUID, sessionID: UUID)
    func sidebarDidRequestSendInterrupt(agent: AgentInstance)
    func sidebarDidRequestKillAgent(agent: AgentInstance)
}

enum SidebarMode {
    case sessions
    case fileTree
    case worktrees
    case gitStatus
    case agents
}

class SidebarView: NSView {
    weak var delegate: SidebarViewDelegate?
    private var sessionManager: SessionManager!

    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var headerLabel: NSTextField!
    private var separatorLine: NSView!

    // Glass background (vibrancy)
    private var glassView: GlassBackgroundView?

    // Icon tab bar
    private var iconBar: NSView!
    private var sessionsButton: DimIconButton!
    private var fileTreeButton: DimIconButton!
    private var iconBarSeparator: NSView!

    // File tree
    private var fileTreeView: FileTreeView!

    // Worktree & Git status
    private var worktreeButton: DimIconButton!
    private var gitStatusButton: DimIconButton!
    private var worktreeView: WorktreeView!
    private var gitStatusView: GitStatusView!

    // Agents
    private var agentsButton: DimIconButton!
    private var agentListView: AgentListView!
    private var agentsBadge: NSView!
    private var agentManager: AgentManager!

    private(set) var mode: SidebarMode = .sessions

    private static let rowHeight: CGFloat = 34
    private static let sessionCellID = NSUserInterfaceItemIdentifier("SessionCell")

    init(sessionManager: SessionManager, agentManager: AgentManager) {
        self.sessionManager = sessionManager
        self.agentManager = agentManager
        super.init(frame: .zero)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(attentionCountDidChange),
            name: AgentManager.attentionCountDidChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        applyGlassOrSolid()
        headerLabel.textColor = Theme.tertiaryText
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        sessionsButton.isActiveState = mode == .sessions
        fileTreeButton.isActiveState = mode == .fileTree
        worktreeButton.isActiveState = mode == .worktrees
        gitStatusButton.isActiveState = mode == .gitStatus
        agentsButton.isActiveState = mode == .agents
        tableView.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    /// Temporarily hide/show the glass backdrop (used during sidebar slide animations
    /// to prevent the NSVisualEffectView blur from creating a trailing shadow artifact).
    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy {
            layer?.backgroundColor = NSColor.clear.cgColor
            if glassView == nil {
                let gv = GlassBackgroundView()
                gv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(gv, positioned: .below, relativeTo: subviews.first)
                NSLayoutConstraint.activate([
                    gv.topAnchor.constraint(equalTo: topAnchor),
                    gv.bottomAnchor.constraint(equalTo: bottomAnchor),
                    gv.leadingAnchor.constraint(equalTo: leadingAnchor),
                    gv.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                glassView = gv
            }
            glassView?.isHidden = false
            glassView?.setTint(Theme.sidebarBg)
        } else {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
            glassView?.isHidden = true
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        setupIconBar()
        setupHeader()
        setupTableView()
        setupFileTree()
        setupWorktreeView()
        setupGitStatusView()
        setupAgentListView()
        setupSeparatorLine()
        setupConstraints()
        applyGlassOrSolid()
    }

    private func setupIconBar() {
        iconBar = NSView()
        iconBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBar)

        sessionsButton = makeIconBarButton(symbolName: "terminal", action: #selector(sessionsButtonClicked))
        sessionsButton.isActiveState = true
        iconBar.addSubview(sessionsButton)

        fileTreeButton = makeIconBarButton(symbolName: "folder", action: #selector(fileTreeButtonClicked))
        iconBar.addSubview(fileTreeButton)

        worktreeButton = makeIconBarButton(symbolName: "arrow.triangle.branch", action: #selector(worktreeButtonClicked))
        iconBar.addSubview(worktreeButton)

        gitStatusButton = makeIconBarButton(symbolName: "chart.bar.doc.horizontal", action: #selector(gitStatusButtonClicked))
        iconBar.addSubview(gitStatusButton)

        agentsButton = makeIconBarButton(symbolName: "cpu", action: #selector(agentsButtonClicked))
        iconBar.addSubview(agentsButton)

        agentsBadge = NSView()
        agentsBadge.translatesAutoresizingMaskIntoConstraints = false
        agentsBadge.wantsLayer = true
        agentsBadge.layer?.backgroundColor = NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0).cgColor
        agentsBadge.layer?.cornerRadius = 4
        agentsBadge.isHidden = true
        iconBar.addSubview(agentsBadge)

        NSLayoutConstraint.activate([
            sessionsButton.leadingAnchor.constraint(equalTo: iconBar.leadingAnchor, constant: 14),
            sessionsButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            sessionsButton.widthAnchor.constraint(equalToConstant: 24),
            sessionsButton.heightAnchor.constraint(equalToConstant: 24),

            fileTreeButton.leadingAnchor.constraint(equalTo: sessionsButton.trailingAnchor, constant: 6),
            fileTreeButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            fileTreeButton.widthAnchor.constraint(equalToConstant: 24),
            fileTreeButton.heightAnchor.constraint(equalToConstant: 24),

            worktreeButton.leadingAnchor.constraint(equalTo: fileTreeButton.trailingAnchor, constant: 6),
            worktreeButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            worktreeButton.widthAnchor.constraint(equalToConstant: 24),
            worktreeButton.heightAnchor.constraint(equalToConstant: 24),

            gitStatusButton.leadingAnchor.constraint(equalTo: worktreeButton.trailingAnchor, constant: 6),
            gitStatusButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            gitStatusButton.widthAnchor.constraint(equalToConstant: 24),
            gitStatusButton.heightAnchor.constraint(equalToConstant: 24),

            agentsButton.leadingAnchor.constraint(equalTo: gitStatusButton.trailingAnchor, constant: 6),
            agentsButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            agentsButton.widthAnchor.constraint(equalToConstant: 24),
            agentsButton.heightAnchor.constraint(equalToConstant: 24),

            agentsBadge.widthAnchor.constraint(equalToConstant: 8),
            agentsBadge.heightAnchor.constraint(equalToConstant: 8),
            agentsBadge.topAnchor.constraint(equalTo: agentsButton.topAnchor, constant: -1),
            agentsBadge.trailingAnchor.constraint(equalTo: agentsButton.trailingAnchor, constant: 3),
        ])

        iconBarSeparator = NSView()
        iconBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        iconBarSeparator.wantsLayer = true
        iconBarSeparator.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(iconBarSeparator)
    }

    private func makeIconBarButton(symbolName: String, action: Selector) -> DimIconButton {
        let button = DimIconButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: symbolName
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        )
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.refreshDimState()
        return button
    }

    private func setupFileTree() {
        fileTreeView = FileTreeView(frame: .zero)
        fileTreeView.translatesAutoresizingMaskIntoConstraints = false
        fileTreeView.isHidden = true
        fileTreeView.delegate = self
        addSubview(fileTreeView)
    }

    private func setupWorktreeView() {
        worktreeView = WorktreeView(frame: .zero)
        worktreeView.translatesAutoresizingMaskIntoConstraints = false
        worktreeView.isHidden = true
        worktreeView.onOpenWorktree = { [weak self] path in
            self?.delegate?.sidebarDidRequestOpenWorktree(path: path)
        }
        worktreeView.onCreateWorktree = { [weak self] path in
            self?.delegate?.sidebarDidRequestOpenWorktree(path: path)
        }
        addSubview(worktreeView)
    }

    private func setupGitStatusView() {
        gitStatusView = GitStatusView(frame: .zero)
        gitStatusView.translatesAutoresizingMaskIntoConstraints = false
        gitStatusView.isHidden = true
        addSubview(gitStatusView)
    }

    private func setupAgentListView() {
        agentListView = AgentListView(agentManager: agentManager, sessionManager: sessionManager)
        agentListView.translatesAutoresizingMaskIntoConstraints = false
        agentListView.isHidden = true
        agentListView.delegate = self
        addSubview(agentListView)
    }

    private func setupHeader() {
        headerLabel = NSTextField(labelWithString: "")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.backgroundColor = .clear
        headerLabel.isBezeled = false
        headerLabel.isEditable = false
        headerLabel.isSelectable = false
        headerLabel.font = Theme.Fonts.label(size: 11)
        headerLabel.textColor = Theme.tertiaryText
        headerLabel.stringValue = "SESSIONS"
        addSubview(headerLabel)
    }

    private func setupTableView() {
        tableView = NSTableView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = SidebarView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(tableViewClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SessionColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        if #available(macOS 11.0, *) {
            tableView.style = .fullWidth
        }

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

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    private func setupSeparatorLine() {
        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)
    }

    private func setupConstraints() {
        let contentTrailing = separatorLine.leadingAnchor

        NSLayoutConstraint.activate([
            // Icon bar below titlebar
            iconBar.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            iconBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconBar.trailingAnchor.constraint(equalTo: contentTrailing),
            iconBar.heightAnchor.constraint(equalToConstant: 30),

            iconBarSeparator.topAnchor.constraint(equalTo: iconBar.bottomAnchor),
            iconBarSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconBarSeparator.trailingAnchor.constraint(equalTo: contentTrailing, constant: -12),
            iconBarSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Sessions header
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor, constant: 10),

            // Sessions scroll view
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentTrailing),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // File tree (same region, toggled via isHidden)
            fileTreeView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            fileTreeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileTreeView.trailingAnchor.constraint(equalTo: contentTrailing),
            fileTreeView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Worktree view (same region, toggled via isHidden)
            worktreeView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            worktreeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            worktreeView.trailingAnchor.constraint(equalTo: contentTrailing),
            worktreeView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Git status view (same region, toggled via isHidden)
            gitStatusView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            gitStatusView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gitStatusView.trailingAnchor.constraint(equalTo: contentTrailing),
            gitStatusView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Agent list view (same region, toggled via isHidden)
            agentListView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            agentListView.leadingAnchor.constraint(equalTo: leadingAnchor),
            agentListView.trailingAnchor.constraint(equalTo: contentTrailing),
            agentListView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Right edge separator
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Mode Switching

    @objc private func sessionsButtonClicked() { setMode(.sessions) }
    @objc private func fileTreeButtonClicked() { setMode(.fileTree) }
    @objc private func worktreeButtonClicked() { setMode(.worktrees) }
    @objc private func gitStatusButtonClicked() { setMode(.gitStatus) }
    @objc private func agentsButtonClicked() { setMode(.agents) }

    @objc private func attentionCountDidChange() {
        let count = agentManager.attentionCount
        agentsBadge.isHidden = count == 0
    }

    private func setMode(_ newMode: SidebarMode) {
        mode = newMode
        sessionsButton.isActiveState = mode == .sessions
        fileTreeButton.isActiveState = mode == .fileTree
        worktreeButton.isActiveState = mode == .worktrees
        gitStatusButton.isActiveState = mode == .gitStatus
        agentsButton.isActiveState = mode == .agents

        headerLabel.isHidden = mode != .sessions
        scrollView.isHidden = mode != .sessions
        fileTreeView.isHidden = mode != .fileTree
        worktreeView.isHidden = mode != .worktrees
        gitStatusView.isHidden = mode != .gitStatus
        agentListView.isHidden = mode != .agents

        let dir = delegate?.sidebarCurrentDirectory()
        if mode == .fileTree {
            fileTreeView.setRootPath(dir)
        } else if mode == .worktrees {
            worktreeView.refresh(cwd: dir)
        } else if mode == .gitStatus {
            gitStatusView.refresh(cwd: dir)
        }
    }

    /// Called externally when the active pane changes or its pwd updates.
    func updateFileTreePath(_ path: String?) {
        guard mode == .fileTree else { return }
        fileTreeView.setRootPath(path)
    }

    /// Called externally when the active pane changes or its pwd updates.
    func updateGitViews(cwd: String?) {
        if mode == .worktrees { worktreeView.refresh(cwd: cwd) }
        if mode == .gitStatus { gitStatusView.refresh(cwd: cwd) }
    }

    // MARK: - Public

    func reloadSessions() {
        tableView.reloadData()

        let activeIndex = sessionManager.activeSessionIndex
        if activeIndex >= 0 && activeIndex < sessionManager.sessions.count {
            tableView.selectRowIndexes(IndexSet(integer: activeIndex), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    @objc private func tableViewClicked(_ sender: Any) {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < sessionManager.sessions.count else { return }
        let session = sessionManager.sessions[clickedRow]
        delegate?.sidebarDidSelectSession(session)
    }

    @objc private func renameMenuItemClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        delegate?.sidebarDidRequestRenameSession(session)
    }

    @objc private func deleteMenuItemClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        delegate?.sidebarDidRequestDeleteSession(session)
    }
}

// MARK: - NSTableViewDataSource

extension SidebarView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return sessionManager.sessions.count
    }
}

// MARK: - NSTableViewDelegate

extension SidebarView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sessionManager.sessions.count else { return nil }
        let session = sessionManager.sessions[row]
        let isActive = (row == sessionManager.activeSessionIndex)

        var cellView = tableView.makeView(
            withIdentifier: SidebarView.sessionCellID,
            owner: self
        ) as? SessionCellView

        if cellView == nil {
            cellView = SessionCellView()
            cellView?.identifier = SidebarView.sessionCellID
        }

        cellView?.configure(session: session, isActive: isActive, index: row + 1)
        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return SidebarView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return SidebarSessionRowView()
    }
}

// MARK: - NSMenuDelegate (context menu)

extension SidebarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < sessionManager.sessions.count else { return }
        let session = sessionManager.sessions[clickedRow]

        let renameItem = NSMenuItem(title: "Rename", action: #selector(renameMenuItemClicked(_:)), keyEquivalent: "")
        renameItem.representedObject = session
        renameItem.target = self
        menu.addItem(renameItem)

        if sessionManager.sessions.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let deleteItem = NSMenuItem(title: "Close", action: #selector(deleteMenuItemClicked(_:)), keyEquivalent: "")
            deleteItem.representedObject = session
            deleteItem.target = self
            menu.addItem(deleteItem)
        }
    }
}

// MARK: - FileTreeViewDelegate

extension SidebarView: FileTreeViewDelegate {
    func fileTreeView(_ view: FileTreeView, didSelectFileAt path: String) {
        delegate?.sidebarDidSelectFile(path: path)
    }
}

// MARK: - AgentListViewDelegate

extension SidebarView: AgentListViewDelegate {
    func agentListDidRequestFocusPane(paneID: UUID, sessionID: UUID) {
        delegate?.sidebarDidRequestFocusAgentPane(paneID: paneID, sessionID: sessionID)
    }
    func agentListDidRequestSendInterrupt(agent: AgentInstance) {
        delegate?.sidebarDidRequestSendInterrupt(agent: agent)
    }
    func agentListDidRequestKillAgent(agent: AgentInstance) {
        delegate?.sidebarDidRequestKillAgent(agent: agent)
    }
}

// MARK: - Session Cell View

private class SessionCellView: NSView {
    private let colorDot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let highlightView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isActiveSession = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = Theme.quaternaryText
        shortcutLabel.backgroundColor = .clear
        shortcutLabel.isBezeled = false
        shortcutLabel.isEditable = false
        shortcutLabel.isSelectable = false
        shortcutLabel.alignment = .center
        addSubview(shortcutLabel)

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
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(session: Session, isActive: Bool, index: Int) {
        isActiveSession = isActive
        nameLabel.stringValue = session.name

        colorDot.layer?.backgroundColor = session.statusColor.cgColor

        nameLabel.textColor = isActive ? Theme.primaryText : Theme.secondaryText
        nameLabel.font = isActive ? Theme.Fonts.headline(size: 13) : Theme.Fonts.body(size: 13)

        if index <= 9 {
            shortcutLabel.stringValue = "\(index)"
            shortcutLabel.isHidden = false
        } else {
            shortcutLabel.isHidden = true
        }

        updateBackground()
    }

    private func updateBackground() {
        if isActiveSession {
            highlightView.layer?.backgroundColor = Theme.activeBg.cgColor
        } else if isHovered {
            highlightView.layer?.backgroundColor = Theme.hoverBg.cgColor
        } else {
            highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
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

// MARK: - Custom row view

private class SidebarSessionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // Handled by cell view
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return .emphasized
    }
}
