import AppKit

// MARK: - Delegate

protocol GitPanelViewDelegate: AnyObject {
    func gitPanelDidRequestOpenWorktree(path: String)
    func gitPanelDidRequestOpenDiff(filePath: String, staged: Bool, repoRoot: String)
    func gitPanelDidRequestOpenCommit(hash: String, repoRoot: String)
}

// MARK: - Git Panel View
//
// Right-side git sidebar inspired by GitHub Desktop. Provides worktree + branch
// switching, commit authoring, pull/push, pull-request creation, staging, and history.

final class GitPanelView: NSView {
    weak var delegate: GitPanelViewDelegate?
    // MARK: - Backdrop + structure

    private var glassView: GlassBackgroundView?
    private var separatorLine: NSView!

    // Header
    private var repoButton: GitPanelChipButton!
    private var branchButton: GitPanelChipButton!
    private var createPRButton: GitPanelActionButton!
    private var refreshButton: DimIconButton!

    // Commit box
    private var commitBoxContainer: NSView!
    private var commitScroll: NSScrollView!
    private var commitTextView: CommitTextView!
    private var commitButton: GitPanelActionButton!
    private var pullButton: GitPanelActionButton!
    private var pushButton: GitPanelActionButton!

    // Changes
    private var changesHeader: SectionHeaderView!
    private var changesOutline: NSOutlineView!
    private var changesScroll: NSScrollView!

    // History
    private var historyHeader: SectionHeaderView!
    private var historyTable: HoverTableView!
    private var historyScroll: NSScrollView!

    private var splitView: NSSplitView!
    private var didSetInitialSplitPosition = false

    // Collapse state for Changes / History panels.
    private var changesCollapsed = false
    private var historyCollapsed = false
    /// Last divider position while both panels were expanded — restored on un-collapse.
    private var lastExpandedDividerPosition: CGFloat = 0

    // Empty state
    private var emptyLabel: NSTextField!

    private var topInsetConstraint: NSLayoutConstraint!

    /// Distance from the view's top to the first header row. Default 44pt reserves
    /// space for the window toolbar. Set to 0 when embedded below a shared header.
    var topContentInset: CGFloat = 44 {
        didSet { topInsetConstraint?.constant = topContentInset }
    }

    /// Hide internal separator + glass when wrapped inside a parent that draws chrome.
    var chromeHidden: Bool = false {
        didSet {
            separatorLine?.isHidden = chromeHidden
            if chromeHidden { glassView?.isHidden = true }
        }
    }

    // MARK: - State

    private var currentCwd: String?
    private var repoRoot: String?
    private var statusInfo: GitHelper.StatusInfo?
    private var branches: [GitHelper.BranchInfo] = []
    private var commits: [GitHelper.CommitInfo] = []
    private var worktrees: [GitHelper.WorktreeInfo] = []

    /// Section keys for the outline view root items.
    private var visibleSections: [String] = []
    private var sectionFiles: [String: [GitHelper.FileStatus]] = [:]

    private static let sectionCellID = NSUserInterfaceItemIdentifier("GitPanelSectionCell")
    private static let fileCellID = NSUserInterfaceItemIdentifier("GitPanelFileCell")
    private static let commitCellID = NSUserInterfaceItemIdentifier("GitPanelCommitCell")

    // MARK: - Init

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
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Public

    /// Hide glass layer during sidebar slide animations so blur artifacts don't linger.
    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    /// Refresh the panel against a new working directory (typically the focused pane's cwd).
    func refresh(cwd: String?) {
        currentCwd = cwd

        guard let cwd = cwd else {
            showEmptyState("No active directory")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let root = GitHelper.repoRoot(from: cwd)
            guard let root = root else {
                DispatchQueue.main.async { self?.showEmptyState("Not a git repository") }
                return
            }
            let status = GitHelper.status(from: root)
            let branches = GitHelper.listBranches(from: root)
            let log = GitHelper.log(from: root, limit: 150)
            let worktrees = GitHelper.listWorktrees(from: root)
            DispatchQueue.main.async {
                self?.applyData(root: root, status: status, branches: branches, log: log, worktrees: worktrees)
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        setupSeparator()
        setupHeader()
        setupCommitBox()
        setupActionRow()
        setupSplitView()
        setupEmptyLabel()
        setupConstraints()
        applyGlassOrSolid()
    }

    private func setupSeparator() {
        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)
    }

    private func setupHeader() {
        repoButton = GitPanelChipButton()
        repoButton.translatesAutoresizingMaskIntoConstraints = false
        repoButton.leadingSymbol = "square.stack.3d.up"
        repoButton.trailingSymbol = "chevron.down"
        repoButton.target = self
        repoButton.action = #selector(repoClicked)
        addSubview(repoButton)

        branchButton = GitPanelChipButton()
        branchButton.translatesAutoresizingMaskIntoConstraints = false
        branchButton.leadingSymbol = "arrow.triangle.branch"
        branchButton.trailingSymbol = "chevron.down"
        branchButton.target = self
        branchButton.action = #selector(branchClicked)
        addSubview(branchButton)

        createPRButton = GitPanelActionButton(title: "Create PR", symbolName: "arrow.up.right.square")
        createPRButton.translatesAutoresizingMaskIntoConstraints = false
        createPRButton.target = self
        createPRButton.action = #selector(createPRClicked)
        addSubview(createPRButton)

        let refreshImage = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        refreshButton = DimIconButton(image: refreshImage ?? NSImage(), target: self, action: #selector(refreshClicked))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)
    }

    private func setupCommitBox() {
        // NSScrollView swaps its own backing layer around internally, which drops
        // any border set on `commitScroll.layer`. Own the chrome with a dedicated
        // container view and put the (chromeless) scroll view inside it.
        commitBoxContainer = NSView()
        commitBoxContainer.translatesAutoresizingMaskIntoConstraints = false
        commitBoxContainer.wantsLayer = true
        commitBoxContainer.layer?.cornerRadius = Theme.CornerRadius.element
        commitBoxContainer.layer?.borderWidth = 1
        commitBoxContainer.layer?.borderColor = Theme.outline.withAlphaComponent(0.35).cgColor
        commitBoxContainer.layer?.backgroundColor = Theme.surfaceContainerLowest.cgColor
        commitBoxContainer.layer?.masksToBounds = true
        addSubview(commitBoxContainer)

        commitScroll = NSScrollView()
        commitScroll.translatesAutoresizingMaskIntoConstraints = false
        commitScroll.hasVerticalScroller = true
        commitScroll.drawsBackground = false
        commitScroll.borderType = .noBorder
        commitBoxContainer.addSubview(commitScroll)

        NSLayoutConstraint.activate([
            commitScroll.topAnchor.constraint(equalTo: commitBoxContainer.topAnchor),
            commitScroll.bottomAnchor.constraint(equalTo: commitBoxContainer.bottomAnchor),
            commitScroll.leadingAnchor.constraint(equalTo: commitBoxContainer.leadingAnchor),
            commitScroll.trailingAnchor.constraint(equalTo: commitBoxContainer.trailingAnchor),
        ])

        let textView = CommitTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = Theme.Fonts.body(size: 12)
        textView.drawsBackground = false
        textView.textColor = Theme.primaryText
        textView.insertionPointColor = Theme.primary
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        textView.onSubmit = { [weak self] in self?.commitClicked() }
        textView.onTextChange = { [weak self] in self?.updateActionStates() }

        commitScroll.documentView = textView
        commitTextView = textView
    }

    private func setupActionRow() {
        commitButton = GitPanelActionButton(title: "Commit", symbolName: "checkmark", style: .primary)
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.isEnabled = false
        addSubview(commitButton)

        pullButton = GitPanelActionButton(title: "Pull", symbolName: "arrow.down")
        pullButton.translatesAutoresizingMaskIntoConstraints = false
        pullButton.target = self
        pullButton.action = #selector(pullClicked)
        addSubview(pullButton)

        pushButton = GitPanelActionButton(title: "Push", symbolName: "arrow.up")
        pushButton.translatesAutoresizingMaskIntoConstraints = false
        pushButton.target = self
        pushButton.action = #selector(pushClicked)
        addSubview(pushButton)
    }

    private func setupSplitView() {
        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        addSubview(splitView)

        // --- Changes side ---
        let changesContainer = NSView()
        changesContainer.translatesAutoresizingMaskIntoConstraints = false

        changesHeader = SectionHeaderView(title: "CHANGES")
        changesHeader.translatesAutoresizingMaskIntoConstraints = false
        changesHeader.configureActions([
            SectionHeaderView.Action(symbol: "checklist", tooltip: "Stage all", handler: { [weak self] in self?.stageAllClicked() }),
            SectionHeaderView.Action(symbol: "arrow.uturn.backward", tooltip: "Discard all", handler: { [weak self] in self?.discardAllClicked() }),
            SectionHeaderView.Action(symbol: "arrow.clockwise", tooltip: "Refresh", handler: { [weak self] in self?.refresh(cwd: self?.currentCwd) }),
        ])
        changesHeader.onToggle = { [weak self] in self?.toggleChangesCollapsed() }
        changesContainer.addSubview(changesHeader)

        changesOutline = NSOutlineView()
        changesOutline.headerView = nil
        changesOutline.rowHeight = 22
        changesOutline.intercellSpacing = NSSize(width: 0, height: 0)
        changesOutline.selectionHighlightStyle = .none
        changesOutline.indentationPerLevel = 12
        changesOutline.delegate = self
        changesOutline.dataSource = self
        changesOutline.backgroundColor = .clear
        changesOutline.menu = createChangesMenu()
        changesOutline.target = self
        changesOutline.action = #selector(changeClicked)
        changesOutline.doubleAction = #selector(changeDoubleClicked)

        let changesColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GitPanelChangesColumn"))
        changesColumn.isEditable = false
        changesOutline.addTableColumn(changesColumn)
        changesOutline.outlineTableColumn = changesColumn

        changesScroll = NSScrollView()
        changesScroll.translatesAutoresizingMaskIntoConstraints = false
        changesScroll.documentView = changesOutline
        changesScroll.hasVerticalScroller = true
        changesScroll.drawsBackground = false
        changesScroll.borderType = .noBorder
        changesScroll.autohidesScrollers = true
        changesScroll.scrollerStyle = .overlay
        changesScroll.verticalScroller = ThinScroller()
        changesContainer.addSubview(changesScroll)

        NSLayoutConstraint.activate([
            changesHeader.topAnchor.constraint(equalTo: changesContainer.topAnchor),
            changesHeader.leadingAnchor.constraint(equalTo: changesContainer.leadingAnchor),
            changesHeader.trailingAnchor.constraint(equalTo: changesContainer.trailingAnchor),
            changesHeader.heightAnchor.constraint(equalToConstant: 26),

            changesScroll.topAnchor.constraint(equalTo: changesHeader.bottomAnchor),
            changesScroll.leadingAnchor.constraint(equalTo: changesContainer.leadingAnchor),
            changesScroll.trailingAnchor.constraint(equalTo: changesContainer.trailingAnchor),
            changesScroll.bottomAnchor.constraint(equalTo: changesContainer.bottomAnchor),
        ])

        // --- History side ---
        let historyContainer = NSView()
        historyContainer.translatesAutoresizingMaskIntoConstraints = false

        historyHeader = SectionHeaderView(title: "HISTORY")
        historyHeader.translatesAutoresizingMaskIntoConstraints = false
        historyHeader.configureActions([
            SectionHeaderView.Action(symbol: "arrow.clockwise", tooltip: "Refresh", handler: { [weak self] in self?.refresh(cwd: self?.currentCwd) }),
        ])
        historyHeader.onToggle = { [weak self] in self?.toggleHistoryCollapsed() }
        historyContainer.addSubview(historyHeader)

        historyTable = HoverTableView()
        historyTable.headerView = nil
        historyTable.rowHeight = 42
        historyTable.intercellSpacing = NSSize(width: 0, height: 0)
        historyTable.selectionHighlightStyle = .none
        historyTable.delegate = self
        historyTable.dataSource = self
        historyTable.backgroundColor = .clear
        historyTable.menu = createHistoryMenu()
        historyTable.target = self
        historyTable.action = #selector(historyClicked)

        let historyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GitPanelHistoryColumn"))
        historyColumn.isEditable = false
        historyTable.addTableColumn(historyColumn)

        historyScroll = NSScrollView()
        historyScroll.translatesAutoresizingMaskIntoConstraints = false
        historyScroll.documentView = historyTable
        historyScroll.hasVerticalScroller = true
        historyScroll.drawsBackground = false
        historyScroll.borderType = .noBorder
        historyScroll.autohidesScrollers = true
        historyScroll.scrollerStyle = .overlay
        historyScroll.verticalScroller = ThinScroller()
        historyContainer.addSubview(historyScroll)

        NSLayoutConstraint.activate([
            historyHeader.topAnchor.constraint(equalTo: historyContainer.topAnchor),
            historyHeader.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor),
            historyHeader.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor),
            historyHeader.heightAnchor.constraint(equalToConstant: 26),

            historyScroll.topAnchor.constraint(equalTo: historyHeader.bottomAnchor),
            historyScroll.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor),
            historyScroll.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor),
            historyScroll.bottomAnchor.constraint(equalTo: historyContainer.bottomAnchor),
        ])

        splitView.addArrangedSubview(changesContainer)
        splitView.addArrangedSubview(historyContainer)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(251), forSubviewAt: 0)
    }

    private func setupEmptyLabel() {
        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.backgroundColor = .clear
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    private func setupConstraints() {
        topInsetConstraint = repoButton.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)

        NSLayoutConstraint.activate([
            // Left-edge separator
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),

            // Header row (below toolbar area)
            topInsetConstraint,
            repoButton.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor, constant: 10),
            repoButton.heightAnchor.constraint(equalToConstant: 24),

            branchButton.centerYAnchor.constraint(equalTo: repoButton.centerYAnchor),
            branchButton.leadingAnchor.constraint(equalTo: repoButton.trailingAnchor, constant: 6),
            branchButton.heightAnchor.constraint(equalToConstant: 24),

            createPRButton.centerYAnchor.constraint(equalTo: repoButton.centerYAnchor),
            createPRButton.leadingAnchor.constraint(greaterThanOrEqualTo: branchButton.trailingAnchor, constant: 6),
            createPRButton.heightAnchor.constraint(equalToConstant: 22),

            refreshButton.centerYAnchor.constraint(equalTo: repoButton.centerYAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: createPRButton.trailingAnchor, constant: 6),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            // Commit textarea
            commitBoxContainer.topAnchor.constraint(equalTo: repoButton.bottomAnchor, constant: 10),
            commitBoxContainer.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor, constant: 10),
            commitBoxContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            commitBoxContainer.heightAnchor.constraint(equalToConstant: 90),

            // Action row
            commitButton.topAnchor.constraint(equalTo: commitBoxContainer.bottomAnchor, constant: 8),
            commitButton.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor, constant: 10),
            commitButton.trailingAnchor.constraint(lessThanOrEqualTo: pullButton.leadingAnchor, constant: -6),
            commitButton.heightAnchor.constraint(equalToConstant: 22),
            commitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),

            pullButton.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
            pullButton.trailingAnchor.constraint(equalTo: pushButton.leadingAnchor, constant: -6),
            pullButton.heightAnchor.constraint(equalToConstant: 22),

            pushButton.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
            pushButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pushButton.heightAnchor.constraint(equalToConstant: 22),

            // Split view (Changes + History)
            splitView.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 10),
            splitView.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Empty state
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Split view defaults to 50/50 but the first time the panel appears the
        // Changes outline can end up with no visible height. Force a sensible
        // initial position once the view has a real frame.
        if !didSetInitialSplitPosition, splitView.bounds.height > 100 {
            splitView.setPosition(splitView.bounds.height * 0.42, ofDividerAt: 0)
            lastExpandedDividerPosition = splitView.bounds.height * 0.42
            didSetInitialSplitPosition = true
        }
        // Re-enforce collapsed divider positions after window resize.
        if changesCollapsed || historyCollapsed {
            applyCollapseState()
        }
    }

    // MARK: - Collapse

    private func toggleChangesCollapsed() {
        changesCollapsed.toggle()
        changesHeader.isCollapsed = changesCollapsed
        applyCollapseState()
    }

    private func toggleHistoryCollapsed() {
        historyCollapsed.toggle()
        historyHeader.isCollapsed = historyCollapsed
        applyCollapseState()
    }

    private func applyCollapseState() {
        changesScroll.isHidden = changesCollapsed
        historyScroll.isHidden = historyCollapsed

        let totalHeight = splitView.bounds.height
        guard totalHeight > 80 else { return }
        let headerHeight: CGFloat = 26
        let divider = splitView.dividerThickness

        if changesCollapsed && !historyCollapsed {
            splitView.setPosition(headerHeight, ofDividerAt: 0)
        } else if historyCollapsed && !changesCollapsed {
            splitView.setPosition(totalHeight - headerHeight - divider, ofDividerAt: 0)
        } else if !changesCollapsed && !historyCollapsed {
            let pos = lastExpandedDividerPosition > 0 ? lastExpandedDividerPosition : totalHeight * 0.42
            splitView.setPosition(pos, ofDividerAt: 0)
        }
    }

    // MARK: - Glass

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

    // MARK: - Theme

    @objc private func themeDidChange() {
        applyGlassOrSolid()
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        commitBoxContainer.layer?.borderColor = Theme.outline.withAlphaComponent(0.35).cgColor
        commitBoxContainer.layer?.backgroundColor = Theme.surfaceContainerLowest.cgColor
        commitTextView.textColor = Theme.primaryText
        commitTextView.font = Theme.Fonts.body(size: 12)
        refreshButton.refreshDimState()
        changesHeader.applyTheme()
        historyHeader.applyTheme()
        changesOutline.reloadData()
        historyTable.reloadData()
    }

    @objc private func gitCommandDidFinish() {
        refresh(cwd: currentCwd)
    }

    // MARK: - Apply data

    private func applyData(
        root: String,
        status: GitHelper.StatusInfo?,
        branches: [GitHelper.BranchInfo],
        log: [GitHelper.CommitInfo],
        worktrees: [GitHelper.WorktreeInfo]
    ) {
        repoRoot = root
        statusInfo = status
        self.branches = branches
        self.commits = log
        self.worktrees = worktrees

        // Hide empty state
        emptyLabel.isHidden = true
        setContentViewsHidden(false)

        // Repo label shows the current worktree's folder name (e.g. agent-orc, agent-orc-feat)
        let currentWorktree = worktrees.first(where: { $0.isCurrent }) ?? worktrees.first
        let repoName = URL(fileURLWithPath: currentWorktree?.path ?? root).lastPathComponent
        repoButton.title = repoName

        // Branch label
        branchButton.title = status?.branch ?? "(detached)"

        // Ahead/behind annotation on push button
        let ahead = status?.ahead ?? 0
        let behind = status?.behind ?? 0
        pushButton.badgeValue = ahead > 0 ? "\(ahead)" : nil
        pullButton.badgeValue = behind > 0 ? "\(behind)" : nil

        // Group files
        var staged: [GitHelper.FileStatus] = []
        var modified: [GitHelper.FileStatus] = []
        var untracked: [GitHelper.FileStatus] = []

        for file in status?.files ?? [] {
            switch file.kind {
            case .staged, .renamed:
                staged.append(file)
            case .modified, .deleted:
                modified.append(file)
            case .untracked:
                untracked.append(file)
            }
        }

        var sections: [String] = []
        var byKey: [String: [GitHelper.FileStatus]] = [:]
        if !staged.isEmpty { sections.append("staged"); byKey["staged"] = staged }
        if !modified.isEmpty { sections.append("modified"); byKey["modified"] = modified }
        if !untracked.isEmpty { sections.append("untracked"); byKey["untracked"] = untracked }
        visibleSections = sections
        sectionFiles = byKey

        let totalChanges = staged.count + modified.count + untracked.count
        changesHeader.setCount(totalChanges)
        historyHeader.setCount(commits.count)

        changesOutline.reloadData()
        for section in visibleSections { changesOutline.expandItem(section) }
        historyTable.reloadData()

        updateActionStates()
    }

    private func showEmptyState(_ message: String) {
        repoRoot = nil
        statusInfo = nil
        branches = []
        commits = []
        visibleSections = []
        sectionFiles = [:]

        setContentViewsHidden(true)
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false

        updateActionStates()
    }

    private func setContentViewsHidden(_ hidden: Bool) {
        repoButton.isHidden = hidden
        branchButton.isHidden = hidden
        createPRButton.isHidden = hidden
        refreshButton.isHidden = hidden
        commitBoxContainer.isHidden = hidden
        commitButton.isHidden = hidden
        pullButton.isHidden = hidden
        pushButton.isHidden = hidden
        splitView.isHidden = hidden
    }

    private func updateActionStates() {
        let hasStaged = sectionFiles["staged"]?.isEmpty == false
        let message = commitTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        commitButton.isEnabled = repoRoot != nil && hasStaged && !message.isEmpty
        pullButton.isEnabled = repoRoot != nil
        pushButton.isEnabled = repoRoot != nil
        createPRButton.isEnabled = repoRoot != nil
    }

    // MARK: - Actions

    @objc private func refreshClicked() { refresh(cwd: currentCwd) }

    @objc private func repoClicked() {
        guard repoRoot != nil else { return }
        let dropdown = ThemedDropdown()

        if worktrees.isEmpty {
            dropdown.addRow("No worktrees", enabled: false) {}
        } else {
            for worktree in worktrees {
                let name = URL(fileURLWithPath: worktree.path).lastPathComponent
                let branchText = worktree.branch ?? "(detached)"
                dropdown.addRow(
                    name,
                    subtitle: branchText,
                    icon: "square.stack.3d.up",
                    checked: worktree.isCurrent
                ) { [weak self] in
                    self?.delegate?.gitPanelDidRequestOpenWorktree(path: worktree.path)
                }
            }
        }

        dropdown.addSeparator()
        dropdown.addRow("New Worktree…", icon: "plus") { [weak self] in
            self?.newWorktreeClicked()
        }
        dropdown.addRow("Reveal in Finder", icon: "folder") { [weak self] in
            self?.revealRepoClicked()
        }

        dropdown.show(relativeTo: repoButton)
    }

    private func newWorktreeClicked() {
        guard let root = repoRoot else { return }

        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Enter a branch name for the new worktree:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "branch-name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        runInBackground { [weak self] in
            let result = GitHelper.addWorktree(from: root, branch: name)
            DispatchQueue.main.async {
                switch result {
                case .success(let path):
                    self?.delegate?.gitPanelDidRequestOpenWorktree(path: path)
                case .failure(let err):
                    self?.showError(title: "Worktree create failed", message: err.description)
                }
            }
        }
    }

    private func revealRepoClicked() {
        guard let root = repoRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
    }

    @objc private func branchClicked() {
        guard repoRoot != nil else { return }
        let dropdown = ThemedDropdown()

        let current = statusInfo?.branch
        let locals = branches.filter { !$0.isRemote }
        let remotes = branches.filter { $0.isRemote }

        for branch in locals {
            dropdown.addRow(
                branch.name,
                icon: "arrow.triangle.branch",
                checked: branch.name == current
            ) { [weak self] in
                self?.checkout(ref: branch.name, isRemote: false)
            }
        }
        if !remotes.isEmpty {
            dropdown.addSeparator()
            dropdown.addHeader("Remote")
            for branch in remotes {
                dropdown.addRow(branch.name, icon: "cloud") { [weak self] in
                    self?.checkout(ref: branch.name, isRemote: true)
                }
            }
        }
        dropdown.addSeparator()
        dropdown.addRow("New Branch…", icon: "plus") { [weak self] in
            self?.newBranchClicked()
        }

        dropdown.show(relativeTo: branchButton)
    }

    private func checkout(ref: String, isRemote: Bool) {
        guard let root = repoRoot else { return }
        // For remote refs like "origin/feature/foo", strip only the first path
        // component (the remote name) and keep the rest as the local branch.
        let target: String
        if isRemote, let slash = ref.firstIndex(of: "/") {
            target = String(ref[ref.index(after: slash)...])
        } else {
            target = ref
        }

        runInBackground { [weak self] in
            let result = GitHelper.checkoutBranch(from: root, branch: target)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Checkout failed")
            }
        }
    }

    private func newBranchClicked() {
        guard let root = repoRoot else { return }
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Create a new branch from \(statusInfo?.branch ?? "HEAD"):"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "branch-name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        runInBackground { [weak self] in
            let result = GitHelper.createBranch(from: root, name: name, checkout: true)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Branch create failed")
            }
        }
    }

    @objc private func commitClicked() {
        guard let root = repoRoot else { return }
        let message = commitTextView.string
        runInBackground { [weak self] in
            let result = GitHelper.commit(from: root, message: message)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.commitTextView.string = ""
                case .failure(let err):
                    self?.showError(title: "Commit failed", message: err.description)
                }
            }
        }
    }

    @objc private func pullClicked() {
        guard let root = repoRoot else { return }
        pullButton.isLoading = true
        runInBackground { [weak self] in
            let result = GitHelper.pull(from: root)
            DispatchQueue.main.async {
                self?.pullButton.isLoading = false
                self?.handleResult(result.map { _ in () }, successMessage: nil, failureTitle: "Pull failed")
            }
        }
    }

    @objc private func pushClicked() {
        guard let root = repoRoot else { return }
        pushButton.isLoading = true
        runInBackground { [weak self] in
            var result = GitHelper.push(from: root)
            // If upstream is unset, offer to set it to origin/<branch>.
            if case .failure(let err) = result, err.description.contains("no upstream") || err.description.contains("--set-upstream") {
                if let branch = self?.statusInfo?.branch {
                    result = GitHelper.pushSetUpstream(from: root, branch: branch)
                }
            }
            DispatchQueue.main.async {
                self?.pushButton.isLoading = false
                self?.handleResult(result.map { _ in () }, successMessage: nil, failureTitle: "Push failed")
            }
        }
    }

    @objc private func createPRClicked() {
        guard let root = repoRoot else { return }
        runInBackground { [weak self] in
            let result = GitHelper.openPullRequestInBrowser(from: root)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Create PR failed")
            }
        }
    }

    @objc private func historyClicked() {
        let row = historyTable.clickedRow
        guard row >= 0, row < commits.count, let root = repoRoot else { return }
        let commit = commits[row]
        delegate?.gitPanelDidRequestOpenCommit(hash: commit.hash, repoRoot: root)
    }

    // MARK: - Changes interactions

    @objc private func changeDoubleClicked() {
        let row = changesOutline.clickedRow
        guard row >= 0,
              let file = changesOutline.item(atRow: row) as? GitHelper.FileStatus,
              let root = repoRoot else { return }
        toggleStage(for: file, root: root)
    }

    @objc private func changeClicked() {
        let row = changesOutline.clickedRow
        guard row >= 0,
              let file = changesOutline.item(atRow: row) as? GitHelper.FileStatus,
              let root = repoRoot else { return }
        let staged = (file.kind == .staged || file.kind == .renamed)
        delegate?.gitPanelDidRequestOpenDiff(filePath: file.path, staged: staged, repoRoot: root)
    }

    private func toggleStage(for file: GitHelper.FileStatus, root: String) {
        runInBackground { [weak self] in
            let result: Result<Void, GitHelper.GitError>
            switch file.kind {
            case .staged, .renamed:
                result = GitHelper.unstage(from: root, paths: [file.path])
            case .modified, .untracked, .deleted:
                result = GitHelper.stage(from: root, paths: [file.path])
            }
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Stage failed")
            }
        }
    }

    private func stageAllClicked() {
        guard let root = repoRoot else { return }
        runInBackground { [weak self] in
            let result = GitHelper.stageAll(from: root)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Stage all failed")
            }
        }
    }

    private func discardAllClicked() {
        guard let root = repoRoot, let info = statusInfo, !info.files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Discard all changes?"
        alert.informativeText = "This will revert tracked file changes and remove untracked files. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paths = info.files.map { $0.path }
        runInBackground { [weak self] in
            let result = GitHelper.discard(from: root, paths: paths, includeUntracked: true)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Discard failed")
            }
        }
    }

    // MARK: - Context menus

    private func createChangesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func createHistoryMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func stageMenuItem(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? GitHelper.FileStatus,
              let root = repoRoot else { return }
        runInBackground { [weak self] in
            let result = GitHelper.stage(from: root, paths: [file.path])
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Stage failed")
            }
        }
    }

    @objc private func unstageMenuItem(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? GitHelper.FileStatus,
              let root = repoRoot else { return }
        runInBackground { [weak self] in
            let result = GitHelper.unstage(from: root, paths: [file.path])
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Unstage failed")
            }
        }
    }

    @objc private func discardMenuItem(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? GitHelper.FileStatus,
              let root = repoRoot else { return }
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(file.path)?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let untracked = file.kind == .untracked
        runInBackground { [weak self] in
            let result = GitHelper.discard(from: root, paths: [file.path], includeUntracked: untracked)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Discard failed")
            }
        }
    }

    @objc private func revealInFinderMenuItem(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? GitHelper.FileStatus,
              let root = repoRoot else { return }
        let absolute = (root as NSString).appendingPathComponent(file.path)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
    }

    @objc private func copyCommitHashMenuItem(_ sender: NSMenuItem) {
        guard let commit = sender.representedObject as? GitHelper.CommitInfo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
    }

    @objc private func checkoutCommitMenuItem(_ sender: NSMenuItem) {
        guard let commit = sender.representedObject as? GitHelper.CommitInfo,
              let root = repoRoot else { return }
        let alert = NSAlert()
        alert.messageText = "Checkout \(commit.shortHash)?"
        alert.informativeText = "This will move HEAD to a detached state at \(commit.shortHash)."
        alert.addButton(withTitle: "Checkout")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runInBackground { [weak self] in
            let result = GitHelper.checkoutBranch(from: root, branch: commit.hash)
            DispatchQueue.main.async {
                self?.handleResult(result, successMessage: nil, failureTitle: "Checkout failed")
            }
        }
    }

    // MARK: - Helpers

    private func runInBackground(_ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { block() }
    }

    private func handleResult(
        _ result: Result<Void, GitHelper.GitError>,
        successMessage: String?,
        failureTitle: String
    ) {
        switch result {
        case .success:
            if let msg = successMessage {
                showInfo(title: msg, message: "")
            }
        case .failure(let error):
            showError(title: failureTitle, message: error.description)
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - NSSplitViewDelegate

extension GitPanelView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return changesCollapsed ? 26 : 80
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let h = splitView.bounds.height
        return historyCollapsed ? h - 26 - splitView.dividerThickness : h - 120
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Remember the divider position so we can restore it after un-collapsing.
        guard !changesCollapsed, !historyCollapsed else { return }
        let pos = splitView.arrangedSubviews.first?.frame.height ?? 0
        if pos > 30 { lastExpandedDividerPosition = pos }
    }
}

// MARK: - NSOutlineViewDataSource / Delegate (Changes)

extension GitPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return visibleSections.count }
        if let section = item as? String { return sectionFiles[section]?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return visibleSections[index] }
        if let section = item as? String { return sectionFiles[section]![index] }
        fatalError("Unexpected outline item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is String
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? String {
            var cell = outlineView.makeView(withIdentifier: GitPanelView.sectionCellID, owner: self) as? ChangesSectionCell
            if cell == nil {
                cell = ChangesSectionCell()
                cell?.identifier = GitPanelView.sectionCellID
            }
            let count = sectionFiles[section]?.count ?? 0
            cell?.configure(section: section, count: count)
            return cell
        }
        if let file = item as? GitHelper.FileStatus {
            var cell = outlineView.makeView(withIdentifier: GitPanelView.fileCellID, owner: self) as? FileRowCell
            if cell == nil {
                cell = FileRowCell()
                cell?.identifier = GitPanelView.fileCellID
            }
            cell?.configure(file: file)
            return cell
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 22
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = NSTableRowView()
        row.isEmphasized = false
        return row
    }
}

// MARK: - NSTableViewDataSource / Delegate (History)

extension GitPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return commits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < commits.count else { return nil }
        var cell = tableView.makeView(withIdentifier: GitPanelView.commitCellID, owner: self) as? CommitRowCell
        if cell == nil {
            cell = CommitRowCell()
            cell?.identifier = GitPanelView.commitCellID
        }
        cell?.configure(commit: commits[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 42
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = false
        return rowView
    }
}

// MARK: - NSMenuDelegate (context menus)

extension GitPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if menu === changesOutline.menu {
            let row = changesOutline.clickedRow
            guard row >= 0, let file = changesOutline.item(atRow: row) as? GitHelper.FileStatus else { return }
            switch file.kind {
            case .staged, .renamed:
                let item = NSMenuItem(title: "Unstage", action: #selector(unstageMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = file
                menu.addItem(item)
            case .modified, .untracked, .deleted:
                let item = NSMenuItem(title: "Stage", action: #selector(stageMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = file
                menu.addItem(item)
            }
            let discard = NSMenuItem(title: "Discard Changes", action: #selector(discardMenuItem(_:)), keyEquivalent: "")
            discard.target = self
            discard.representedObject = file
            menu.addItem(discard)
            menu.addItem(NSMenuItem.separator())
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinderMenuItem(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = file
            menu.addItem(reveal)
        } else if menu === historyTable.menu {
            let row = historyTable.clickedRow
            guard row >= 0, row < commits.count else { return }
            let commit = commits[row]

            let copy = NSMenuItem(title: "Copy Hash (\(commit.shortHash))", action: #selector(copyCommitHashMenuItem(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = commit
            menu.addItem(copy)

            let checkout = NSMenuItem(title: "Checkout \(commit.shortHash)", action: #selector(checkoutCommitMenuItem(_:)), keyEquivalent: "")
            checkout.target = self
            checkout.representedObject = commit
            menu.addItem(checkout)
        }
    }
}

// MARK: - Commit text view (captures Cmd+Return)

private final class CommitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onTextChange: (() -> Void)?

    private let placeholder = "Commit message (⌘↵ to commit)"

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n" {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.Fonts.body(size: 12),
            .foregroundColor: Theme.tertiaryText,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + textContainer!.lineFragmentPadding,
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - Chip button (repo / branch selectors)

private final class GitPanelChipButton: NSButton {
    var leadingSymbol: String = "" { didSet { rebuild() } }
    var trailingSymbol: String? { didSet { rebuild() } }

    private var _displayTitle: String = ""
    override var title: String {
        get { _displayTitle }
        set {
            _displayTitle = newValue
            // Never let NSButton draw its own title (it would overlap the custom label).
            super.title = ""
            super.attributedTitle = NSAttributedString(string: "")
            rebuild()
        }
    }

    private let leadingIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingIcon = NSImageView()
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        imagePosition = .noImage
        super.title = ""
        super.attributedTitle = NSAttributedString(string: "")
        wantsLayer = true
        layer?.cornerRadius = Theme.CornerRadius.element
        layer?.borderWidth = 1
        layer?.borderColor = Theme.outlineVariant.cgColor

        leadingIcon.translatesAutoresizingMaskIntoConstraints = false
        leadingIcon.imageScaling = .scaleProportionallyUpOrDown
        leadingIcon.contentTintColor = Theme.secondaryText
        addSubview(leadingIcon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.Fonts.body(size: 12)
        titleLabel.textColor = Theme.secondaryText
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)

        trailingIcon.translatesAutoresizingMaskIntoConstraints = false
        trailingIcon.imageScaling = .scaleProportionallyUpOrDown
        trailingIcon.contentTintColor = Theme.tertiaryText
        addSubview(trailingIcon)

        NSLayoutConstraint.activate([
            leadingIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            leadingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingIcon.widthAnchor.constraint(equalToConstant: 11),
            leadingIcon.heightAnchor.constraint(equalToConstant: 11),

            titleLabel.leadingAnchor.constraint(equalTo: leadingIcon.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailingIcon.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            trailingIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            trailingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingIcon.widthAnchor.constraint(equalToConstant: 9),
            trailingIcon.heightAnchor.constraint(equalToConstant: 9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        titleLabel.sizeToFit()
        return NSSize(width: titleLabel.frame.width + 36, height: 24)
    }

    private func rebuild() {
        leadingIcon.image = NSImage(systemSymbolName: leadingSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        if let trail = trailingSymbol {
            trailingIcon.image = NSImage(systemSymbolName: trail, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
            trailingIcon.isHidden = false
        } else {
            trailingIcon.image = nil
            trailingIcon.isHidden = true
        }
        titleLabel.stringValue = title
        titleLabel.textColor = Theme.secondaryText
        invalidateIntrinsicContentSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.hoverBg.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        layer?.borderColor = Theme.outlineVariant.cgColor
        titleLabel.textColor = Theme.secondaryText
        leadingIcon.contentTintColor = Theme.secondaryText
        trailingIcon.contentTintColor = Theme.tertiaryText
    }
}

// MARK: - Action button (Pull/Push with optional badge)

final class GitPanelActionButton: NSButton {
    enum Style { case primary, secondary }

    var badgeValue: String? {
        didSet { updateDisplayTitle() }
    }

    var isLoading: Bool = false {
        didSet {
            isEnabled = !isLoading
            if isLoading {
                labelView.stringValue = "…"
            } else {
                updateDisplayTitle()
            }
        }
    }

    private let symbolName: String
    private let baseTitle: String
    private let style: Style

    private let iconView = NSImageView()
    private let labelView = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false

    init(title: String, symbolName: String, style: Style = .secondary) {
        self.baseTitle = title
        self.symbolName = symbolName
        self.style = style
        super.init(frame: .zero)

        // Neutralize NSButton's own drawing so the layer + subviews own the appearance.
        bezelStyle = .inline
        isBordered = false
        imagePosition = .noImage
        super.title = ""
        super.attributedTitle = NSAttributedString(string: "")
        wantsLayer = true
        layer?.cornerRadius = Theme.CornerRadius.element

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        addSubview(iconView)

        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.font = Theme.Fonts.label(size: 11)
        labelView.stringValue = title
        labelView.backgroundColor = .clear
        labelView.isBezeled = false
        labelView.isEditable = false
        labelView.isSelectable = false
        addSubview(labelView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 11),
            iconView.heightAnchor.constraint(equalToConstant: 11),

            labelView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        labelView.sizeToFit()
        return NSSize(width: labelView.frame.width + 9 + 11 + 5 + 10, height: 24)
    }

    override var isEnabled: Bool {
        didSet { applyTheme() }
    }

    private func updateDisplayTitle() {
        let base = baseTitle
        labelView.stringValue = (badgeValue?.isEmpty == false) ? "\(base) \(badgeValue!)" : base
        invalidateIntrinsicContentSize()
    }

    private func applyTheme() {
        let bg: NSColor
        let border: NSColor
        let fg: NSColor
        switch style {
        case .primary:
            if isEnabled {
                bg = isHovered ? (Theme.primary.blended(withFraction: 0.10, of: .white) ?? Theme.primary) : Theme.primary
                border = .clear
                fg = Theme.onPrimary
            } else {
                // Disabled primary: neutral surface so the label remains legible,
                // rather than tinted primary + tinted onPrimary (which end up too
                // close in luminance and look washed out).
                bg = Theme.surfaceContainerHigh.withAlphaComponent(0.35)
                border = Theme.outline.withAlphaComponent(0.25)
                fg = Theme.tertiaryText
            }
        case .secondary:
            bg = isEnabled
                ? (isHovered ? Theme.hoverBg : Theme.surfaceContainerHigh)
                : Theme.surfaceContainerHigh.withAlphaComponent(0.35)
            border = Theme.outline.withAlphaComponent(0.35)
            fg = isEnabled ? Theme.primaryText : Theme.tertiaryText
        }
        layer?.backgroundColor = bg.cgColor
        // Show a border whenever one was requested (secondary, or disabled primary
        // which falls back to a neutral chip look).
        let wantsBorder = (style == .secondary) || (style == .primary && !isEnabled)
        layer?.borderWidth = wantsBorder ? 1 : 0
        layer?.borderColor = border.cgColor
        labelView.textColor = fg
        iconView.contentTintColor = fg
        iconView.alphaValue = isEnabled ? 1.0 : 0.6
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyTheme()
    }

    override func layout() {
        super.layout()
        applyTheme()
    }
}

// MARK: - Section header (CHANGES / HISTORY)

final class SectionHeaderView: NSView {
    struct Action {
        let symbol: String
        let tooltip: String
        let handler: () -> Void
    }

    var onToggle: (() -> Void)?
    var isCollapsed: Bool = false {
        didSet { updateChevron() }
    }

    private let chevronIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var actions: [Action] = []

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.withAlphaComponent(0.65).cgColor

        chevronIcon.translatesAutoresizingMaskIntoConstraints = false
        chevronIcon.imageScaling = .scaleProportionallyUpOrDown
        chevronIcon.contentTintColor = Theme.tertiaryText
        addSubview(chevronIcon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.Fonts.label(size: 10)
        titleLabel.textColor = Theme.tertiaryText
        titleLabel.stringValue = title
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Theme.Fonts.body(size: 10)
        countLabel.textColor = Theme.quaternaryText
        countLabel.backgroundColor = .clear
        countLabel.isBezeled = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        addSubview(countLabel)

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            chevronIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevronIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronIcon.widthAnchor.constraint(equalToConstant: 9),
            chevronIcon.heightAnchor.constraint(equalToConstant: 9),

            titleLabel.leadingAnchor.constraint(equalTo: chevronIcon.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateChevron()
    }

    private func updateChevron() {
        let symbol = isCollapsed ? "chevron.right" : "chevron.down"
        chevronIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks on child buttons go to those buttons directly (hit-test). We only
        // receive mouseDown when the user clicks on empty header area — treat that
        // as a toggle so the whole row feels clickable.
        onToggle?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureActions(_ actions: [Action]) {
        self.actions = actions
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            let button = DimIconButton()
            button.title = ""
            button.toolTip = action.tooltip
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.tooltip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(actionButtonClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier("header-\(action.symbol)")
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            button.refreshDimState()
            actionStack.addArrangedSubview(button)
        }
    }

    @objc private func actionButtonClicked(_ sender: DimIconButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let symbol = String(id.dropFirst("header-".count))
        if let action = actions.first(where: { $0.symbol == symbol }) {
            action.handler()
        }
    }

    func setCount(_ count: Int) {
        countLabel.stringValue = count > 0 ? "\(count)" : ""
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.sidebarBg.withAlphaComponent(0.65).cgColor
        titleLabel.textColor = Theme.tertiaryText
        countLabel.textColor = Theme.quaternaryText
        chevronIcon.contentTintColor = Theme.tertiaryText
        for view in actionStack.arrangedSubviews {
            (view as? DimIconButton)?.refreshDimState()
        }
    }
}

// MARK: - Changes section-header cell

private final class ChangesSectionCell: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.label(size: 10)
        label.textColor = Theme.tertiaryText
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: String, count: Int) {
        let labels: [String: String] = [
            "staged": "STAGED",
            "modified": "MODIFIED",
            "untracked": "UNTRACKED",
        ]
        let title = labels[section] ?? section.uppercased()
        label.stringValue = count > 0 ? "\(title)  \(count)" : title
        label.textColor = Theme.tertiaryText
        label.font = Theme.Fonts.label(size: 10)
    }
}

// MARK: - Change file row cell

private final class FileRowCell: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = Theme.Fonts.body(size: 12)
        pathLabel.textColor = Theme.secondaryText
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        addSubview(pathLabel)

        // Single-letter status marker (M/A/D/U/R) right-aligned, subtle tint.
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        statusBadge.backgroundColor = .clear
        statusBadge.isBezeled = false
        statusBadge.isEditable = false
        statusBadge.isSelectable = false
        statusBadge.alignment = .center
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        statusBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(statusBadge)

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = Theme.Fonts.body(size: 10)
        statsLabel.backgroundColor = .clear
        statsLabel.isBezeled = false
        statsLabel.isEditable = false
        statsLabel.isSelectable = false
        statsLabel.alignment = .right
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(statsLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 4),
            statsLabel.trailingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: -6),
            statsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(file: GitHelper.FileStatus) {
        // File name only for the icon lookup — `file.path` may be nested.
        let fileName = URL(fileURLWithPath: file.path).lastPathComponent
        let iconInfo = FileIconInfo.forFile(named: fileName)
        iconView.image = NSImage(
            systemSymbolName: iconInfo.symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        iconView.contentTintColor = iconInfo.color

        pathLabel.stringValue = fileName
        pathLabel.toolTip = file.path
        pathLabel.font = Theme.Fonts.body(size: 12)
        pathLabel.textColor = Theme.secondaryText

        // Status letter + tint — keeps the change kind legible without the dot.
        let badge: (String, NSColor)
        switch file.kind {
        case .staged:
            badge = ("A", NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1.0))
        case .renamed:
            badge = ("R", NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1.0))
        case .modified:
            badge = ("M", NSColor(srgbRed: 0.90, green: 0.72, blue: 0.20, alpha: 1.0))
        case .untracked:
            badge = ("U", NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0))
        case .deleted:
            badge = ("D", NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0))
        }
        statusBadge.stringValue = badge.0
        statusBadge.textColor = badge.1

        let total = file.linesAdded + file.linesRemoved
        if total > 0 {
            let combined = NSMutableAttributedString()
            combined.append(NSAttributedString(string: "+\(file.linesAdded)", attributes: [
                .foregroundColor: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1.0),
                .font: Theme.Fonts.body(size: 10),
            ]))
            combined.append(NSAttributedString(string: " ", attributes: [.font: Theme.Fonts.body(size: 10)]))
            combined.append(NSAttributedString(string: "-\(file.linesRemoved)", attributes: [
                .foregroundColor: NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0),
                .font: Theme.Fonts.body(size: 10),
            ]))
            statsLabel.attributedStringValue = combined
            statsLabel.isHidden = false
        } else {
            statsLabel.stringValue = ""
            statsLabel.isHidden = true
        }
    }
}

// MARK: - Hover-tracking table view
//
// Tracks a single hovered row via a table-level tracking area. Cell-level tracking
// areas drop events during fast movement or scroll; delegating hover to the table
// keeps exactly one row highlighted at a time.

protocol HoverableRowCell: AnyObject {
    func setHovered(_ hovered: Bool)
}

final class HoverTableView: NSTableView {
    private var trackingAreaRef: NSTrackingArea?
    private(set) var hoveredRow: Int = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredRow(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredRow(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(-1)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        setHoveredRow(-1)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHoveredRow(for: event)
    }

    override func reloadData() {
        super.reloadData()
        setHoveredRow(-1)
    }

    private func updateHoveredRow(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        setHoveredRow(row)
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        applyHover(to: previous, hovered: false)
        applyHover(to: row, hovered: true)
    }

    private func applyHover(to row: Int, hovered: Bool) {
        guard row >= 0, row < numberOfRows else { return }
        if let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? HoverableRowCell {
            cell.setHovered(hovered)
        }
    }
}

// MARK: - Commit row cell (history)

private final class CommitRowCell: NSView, HoverableRowCell {
    private let hoverBg = NSView()
    private let dot = NSView()
    private let subjectLabel = NSTextField(labelWithString: "")
    private let hashLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let chipStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        hoverBg.translatesAutoresizingMaskIntoConstraints = false
        hoverBg.wantsLayer = true
        hoverBg.layer?.cornerRadius = Theme.CornerRadius.element
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverBg)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = Theme.primary.cgColor
        addSubview(dot)

        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.font = Theme.Fonts.body(size: 12)
        subjectLabel.textColor = Theme.primaryText
        subjectLabel.backgroundColor = .clear
        subjectLabel.isBezeled = false
        subjectLabel.isEditable = false
        subjectLabel.isSelectable = false
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.maximumNumberOfLines = 1
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(subjectLabel)

        hashLabel.translatesAutoresizingMaskIntoConstraints = false
        hashLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hashLabel.textColor = Theme.tertiaryText
        hashLabel.backgroundColor = .clear
        hashLabel.isBezeled = false
        hashLabel.isEditable = false
        hashLabel.isSelectable = false
        hashLabel.alignment = .right
        hashLabel.setContentHuggingPriority(.required, for: .horizontal)
        hashLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(hashLabel)

        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.orientation = .horizontal
        chipStack.spacing = 5
        addSubview(chipStack)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = Theme.Fonts.body(size: 11)
        metaLabel.textColor = Theme.tertiaryText
        metaLabel.backgroundColor = .clear
        metaLabel.isBezeled = false
        metaLabel.isEditable = false
        metaLabel.isSelectable = false
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        addSubview(metaLabel)

        // Chips should yield first when space runs short; meta text must stay visible.
        chipStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chipStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            hoverBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            hoverBg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            hoverBg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            subjectLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            subjectLabel.trailingAnchor.constraint(lessThanOrEqualTo: hashLabel.leadingAnchor, constant: -8),
            subjectLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            hashLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hashLabel.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),

            // Meta sits on its own line with a fixed offset from the subject so its
            // position is identical whether or not there are chips on this row.
            metaLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            chipStack.leadingAnchor.constraint(equalTo: subjectLabel.leadingAnchor),
            chipStack.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            chipStack.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(commit: GitHelper.CommitInfo) {
        subjectLabel.stringValue = commit.subject
        hashLabel.stringValue = commit.shortHash
        metaLabel.stringValue = "\(commit.authorName)  \(commit.relativeDate)"
        metaLabel.textColor = Theme.tertiaryText

        // Blue dot when this commit has a local ref but no matching remote (i.e. unpushed).
        let hasOrigin = commit.refs.contains(where: { $0.hasPrefix("origin/") })
        let hasLocal = commit.refs.contains(where: { !$0.hasPrefix("origin/") && !$0.isEmpty && $0 != "HEAD" })
        dot.layer?.backgroundColor = (hasLocal && !hasOrigin ? Theme.primary : Theme.outlineVariant).cgColor

        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Cap at 2 chips; long ref names are truncated inside the chip itself.
        for ref in commit.refs.prefix(2) {
            chipStack.addArrangedSubview(RefChipView(ref: ref))
        }
    }

    func setHovered(_ hovered: Bool) {
        hoverBg.layer?.backgroundColor = hovered ? Theme.hoverBg.cgColor : NSColor.clear.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovered(false)
    }
}

// MARK: - Ref chip (local branch / remote / tag)

private final class RefChipView: NSView {
    init(ref: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3

        let isRemote = ref.hasPrefix("origin/") || ref.contains("/")
        let isHEAD = ref.hasPrefix("HEAD")

        let bgColor: NSColor
        let fgColor: NSColor
        let symbol: String

        if isRemote {
            bgColor = NSColor(srgbRed: 0.10, green: 0.32, blue: 0.18, alpha: 1.0)
            fgColor = NSColor(srgbRed: 0.69, green: 0.94, blue: 0.40, alpha: 1.0)
            symbol = "cloud"
        } else if isHEAD {
            bgColor = NSColor(srgbRed: 0.30, green: 0.24, blue: 0.10, alpha: 1.0)
            fgColor = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.40, alpha: 1.0)
            symbol = "arrowtriangle.right.fill"
        } else {
            bgColor = NSColor(srgbRed: 0.10, green: 0.32, blue: 0.38, alpha: 1.0)
            fgColor = NSColor(srgbRed: 0.45, green: 0.90, blue: 0.88, alpha: 1.0)
            symbol = "arrow.triangle.branch"
        }

        layer?.backgroundColor = bgColor.cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        icon.contentTintColor = fgColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let label = NSTextField(labelWithString: ref)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.body(size: 10)
        label.textColor = fgColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 9),
            icon.heightAnchor.constraint(equalToConstant: 9),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 14),
            widthAnchor.constraint(lessThanOrEqualToConstant: 110),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
