import AppKit

// MARK: - Delegate

protocol RunnerPanelViewDelegate: AnyObject {
    /// Called when the user taps "Open in pane" for a running task.
    func runnerPanelDidRequestOpenInPane(command: String, cwd: String)
}

// MARK: - Runner Panel View
//
// Right-side panel that lists user-defined tasks for the active worktree and
// hosts run/stop controls and a log viewer. Task 11 added the outline list.
// Task 12 wraps that list in an NSSplitView with a log-tailing panel below.

final class RunnerPanelView: NSView {
    weak var delegate: RunnerPanelViewDelegate?

    /// Distance from the view's top to the first content row. Matches the
    /// convention used by GitPanelView / EditorSidebarView so the parent can
    /// slot this view under a shared header.
    var topContentInset: CGFloat = 10 {
        didSet {
            scrollTopConstraint?.constant = topContentInset
        }
    }

    /// Hide glass when wrapped inside a parent that already draws chrome.
    var chromeHidden: Bool = false {
        didSet {
            if chromeHidden { glassView?.isHidden = true }
            applyGlassOrSolid()
        }
    }

    private(set) var store: RunnerTaskStore?
    private let runner = TaskRunner()

    /// Most recently selected task id. Setter refreshes the log panel
    /// (header label, button states, text view contents).
    private(set) var selectedTaskID: String? {
        didSet {
            if oldValue != selectedTaskID {
                // Default to latest run when switching tasks.
                selectedRunNumber = nil
                rebuildRunTabs()
                refreshLogPanel(replaceContents: true)
            }
        }
    }

    private var glassView: GlassBackgroundView?
    private var emptyLabel: NSTextField!
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var scrollTopConstraint: NSLayoutConstraint?

    // Top header row (title + refresh + plus).
    private var headerRow: NSView!
    private var headerTitleLabel: NSTextField!
    private var refreshButton: DimIconButton!
    private var addButton: DimIconButton!

    // Invalid-tasks.json banner (red, hidden unless store.loadError != nil).
    private var errorBanner: NSView!
    private var errorBannerLabel: NSTextField!
    private var errorBannerButton: NSButton!
    private var errorBannerHeight: NSLayoutConstraint!

    // Split view hosting outline (top) + log panel (bottom).
    private var splitView: NSSplitView!
    private var didSetInitialSplitPosition = false

    // Log panel subviews.
    private var logContainer: NSView!
    private var logTitleLabel: NSTextField!
    private var logTaskNameLabel: NSTextField!
    private var promoteButton: DimIconButton!
    private var stopButton: DimIconButton!
    private var clearButton: DimIconButton!
    private var logScrollView: NSScrollView!
    private var logTextView: NSTextView!
    private var logFrameView: NSView!
    private var runTabsContainer: NSView!
    private var runTabsScroll: NSScrollView!
    private var runTabsStack: NSStackView!
    private var runTabsLabel: NSTextField!
    private var runTabsEmptyLabel: NSTextField!
    private var runTabsAddButton: DimIconButton!
    private var runTabsSeparator: NSView!
    private var runTabsHeight: NSLayoutConstraint!

    /// When non-nil, the log panel pins to this run number for the selected
    /// task. When nil, the panel follows the latest run.
    private var selectedRunNumber: Int?

    // Coalesce log refreshes so rapid output bursts don't starve the main thread.
    private var pendingLogRefresh: DispatchWorkItem?

    /// Last rendered raw snapshot. ANSI rendering is expensive on large
    /// buffers, so we skip re-rendering when the buffer hasn't changed.
    private var lastRenderedRawSnapshot: String?

    // Outline data — wrappers use reference-equality so NSOutlineView's
    // identity-keyed APIs (reloadItem, expandItem) work correctly across
    // repeated reloads. Fresh wrappers per reload would defeat reloadItem.
    private var visibleSources: [RunnerTaskSource] = []
    private var tasksBySource: [RunnerTaskSource: [RunnerTask]] = [:]
    private var groupItems: [RunnerTaskSource: RunnerOutlineItem] = [:]
    private var taskItems: [String: RunnerOutlineItem] = [:]

    private static let groupCellID = NSUserInterfaceItemIdentifier("RunnerPanelGroupCell")
    private static let taskCellID = NSUserInterfaceItemIdentifier("RunnerPanelTaskCell")

    /// Fixed display order for sources — hidden when the corresponding bucket is empty.
    private static let sourceOrder: [RunnerTaskSource] = [.pinned, .npm, .make, .procfile]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChange(_:)),
            name: RunnerTaskStore.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(runnerDidUpdate(_:)),
            name: TaskRunner.didUpdateNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingLogRefresh?.cancel()
    }

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

    /// Bind the panel to a worktree (or clear it). Rebuilds the store when the
    /// path changes, resets selection, and refreshes the outline.
    func setWorktree(_ path: String?) {
        if let p = path {
            if store?.worktreePath != p {
                store = RunnerTaskStore(worktreePath: p)
                store?.reload()
                selectedTaskID = nil
                selectedRunNumber = nil
                rebuildOutlineData()
                outlineView.reloadData()
                for src in visibleSources {
                    if let item = groupItems[src] { outlineView.expandItem(item) }
                }
                // Background-run visibility: if any task in this worktree
                // already has a running process (e.g. started earlier and
                // still going after the user switched scopes), surface it
                // by auto-selecting so the tab strip + log panel repopulate
                // immediately — otherwise a silently-running task would
                // require the user to remember which row to click.
                if let running = firstTaskWithRunningSession(in: p) {
                    selectedTaskID = running
                }
            }
        } else {
            if store != nil {
                store = nil
                selectedTaskID = nil
                selectedRunNumber = nil
                rebuildOutlineData()
                outlineView.reloadData()
            }
        }
        rebuildRunTabs()
        refreshEmptyState()
        refreshErrorBanner()
    }

    /// Return the first task id that has a live running session for this
    /// worktree, preferring the outline display order.
    private func firstTaskWithRunningSession(in worktreePath: String) -> String? {
        for src in Self.sourceOrder {
            for task in tasksBySource[src] ?? [] {
                if let s = runner.session(for: task.id, worktreePath: worktreePath),
                   s.status == .running {
                    return task.id
                }
            }
        }
        return nil
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        // Outline + scroll view host the task list. Use RunnerOutlineView so
        // right-click selects the row under the cursor before the context
        // menu is built in menuNeedsUpdate.
        outlineView = RunnerOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.selectionHighlightStyle = .none
        outlineView.indentationPerLevel = 12
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.backgroundColor = .clear
        outlineView.allowsEmptySelection = true
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked)
        outlineView.doubleAction = #selector(outlineRowDoubleClicked)

        // Context menu for right-click on pinned task rows. Items are built
        // dynamically in menuNeedsUpdate based on the clicked row.
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RunnerPanelColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = ThinScroller()

        // Top container: just the outline scroll view, flush-filling.
        let outlineContainer = NSView()
        outlineContainer.translatesAutoresizingMaskIntoConstraints = false
        outlineContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: outlineContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: outlineContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: outlineContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: outlineContainer.bottomAnchor),
        ])

        // Bottom container: log panel.
        logContainer = buildLogContainer()

        // Header row: "Tasks" title + refresh + add buttons. Sits above the split view.
        headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)

        headerTitleLabel = NSTextField(labelWithString: "Runner")
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.font = Theme.Fonts.label(size: 10)
        headerTitleLabel.textColor = Theme.tertiaryText
        headerTitleLabel.isBezeled = false
        headerTitleLabel.isEditable = false
        headerTitleLabel.isSelectable = false
        headerTitleLabel.backgroundColor = .clear
        headerRow.addSubview(headerTitleLabel)

        refreshButton = makeIconButton(
            symbol: "arrow.clockwise",
            tooltip: "Refresh",
            action: #selector(refreshClicked)
        )
        addButton = makeIconButton(
            symbol: "plus.circle",
            tooltip: "Add custom command",
            action: #selector(addCustomTaskClicked)
        )
        headerRow.addSubview(refreshButton)
        headerRow.addSubview(addButton)

        // Error banner: red-tinted row that appears when tasks.json fails to
        // parse. Built here so the split-view constraints below can pin to it.
        errorBanner = NSView()
        errorBanner.translatesAutoresizingMaskIntoConstraints = false
        errorBanner.wantsLayer = true
        errorBanner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        errorBanner.isHidden = true
        addSubview(errorBanner)

        errorBannerLabel = NSTextField(labelWithString: "")
        errorBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        errorBannerLabel.font = Theme.Fonts.body(size: 11)
        errorBannerLabel.textColor = Theme.primaryText
        errorBannerLabel.isBezeled = false
        errorBannerLabel.isEditable = false
        errorBannerLabel.isSelectable = false
        errorBannerLabel.backgroundColor = .clear
        errorBannerLabel.lineBreakMode = .byTruncatingTail
        errorBannerLabel.maximumNumberOfLines = 1
        errorBanner.addSubview(errorBannerLabel)

        errorBannerButton = NSButton(title: "Edit file", target: self, action: #selector(editTasksFileClicked))
        errorBannerButton.translatesAutoresizingMaskIntoConstraints = false
        errorBannerButton.bezelStyle = .rounded
        errorBannerButton.controlSize = .small
        errorBannerButton.setContentHuggingPriority(.required, for: .horizontal)
        errorBannerButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        errorBanner.addSubview(errorBannerButton)

        // Split view wraps both halves.
        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(outlineContainer)
        splitView.addArrangedSubview(logContainer)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(251), forSubviewAt: 0)
        addSubview(splitView)

        // Header row sits at top; banner sits below it (0-height when hidden);
        // split view begins below the banner.
        let scrollTop = headerRow.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)
        scrollTopConstraint = scrollTop
        errorBannerHeight = errorBanner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollTop,
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 28),

            headerTitleLabel.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 10),
            headerTitleLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            addButton.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),

            refreshButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
            refreshButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 20),
            refreshButton.heightAnchor.constraint(equalToConstant: 20),

            errorBanner.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            errorBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorBanner.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorBannerHeight,

            errorBannerButton.trailingAnchor.constraint(equalTo: errorBanner.trailingAnchor, constant: -8),
            errorBannerButton.centerYAnchor.constraint(equalTo: errorBanner.centerYAnchor),

            errorBannerLabel.leadingAnchor.constraint(equalTo: errorBanner.leadingAnchor, constant: 10),
            errorBannerLabel.centerYAnchor.constraint(equalTo: errorBanner.centerYAnchor),
            errorBannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: errorBannerButton.leadingAnchor, constant: -8),

            splitView.topAnchor.constraint(equalTo: errorBanner.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Empty-state label floats above the split view; only one is visible at a time.
        emptyLabel = NSTextField(labelWithString: "Open a worktree to run tasks.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.backgroundColor = .clear
        addSubview(emptyLabel)

        // Empty label sits below the banner so it never covers the + button
        // or overlaps the error row.
        NSLayoutConstraint.activate([
            emptyLabel.topAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: 10),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        applyGlassOrSolid()
        refreshEmptyState()
        refreshErrorBanner()
        refreshLogPanel(replaceContents: true)
    }

    private func buildLogContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Header row.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        logTitleLabel = NSTextField(labelWithString: "Log")
        logTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        logTitleLabel.font = Theme.Fonts.label(size: 10)
        logTitleLabel.textColor = Theme.tertiaryText
        logTitleLabel.isBezeled = false
        logTitleLabel.isEditable = false
        logTitleLabel.isSelectable = false
        logTitleLabel.backgroundColor = .clear
        header.addSubview(logTitleLabel)

        logTaskNameLabel = NSTextField(labelWithString: "—")
        logTaskNameLabel.translatesAutoresizingMaskIntoConstraints = false
        logTaskNameLabel.font = Theme.Fonts.body(size: 11)
        logTaskNameLabel.textColor = Theme.secondaryText
        logTaskNameLabel.isBezeled = false
        logTaskNameLabel.isEditable = false
        logTaskNameLabel.isSelectable = false
        logTaskNameLabel.backgroundColor = .clear
        logTaskNameLabel.lineBreakMode = .byTruncatingTail
        logTaskNameLabel.maximumNumberOfLines = 1
        header.addSubview(logTaskNameLabel)

        promoteButton = makeIconButton(
            symbol: "arrow.up.right.square",
            tooltip: "Promote to pane",
            action: #selector(promoteClicked)
        )
        stopButton = makeIconButton(
            symbol: "stop.fill",
            tooltip: "Stop",
            action: #selector(stopClicked)
        )
        clearButton = makeIconButton(
            symbol: "trash",
            tooltip: "Clear log",
            action: #selector(clearClicked)
        )
        header.addSubview(promoteButton)
        header.addSubview(stopButton)
        header.addSubview(clearButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            logTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            logTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            logTaskNameLabel.leadingAnchor.constraint(equalTo: logTitleLabel.trailingAnchor, constant: 6),
            logTaskNameLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            logTaskNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: promoteButton.leadingAnchor, constant: -6),

            clearButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            clearButton.heightAnchor.constraint(equalToConstant: 20),

            stopButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            stopButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 20),
            stopButton.heightAnchor.constraint(equalToConstant: 20),

            promoteButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -2),
            promoteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            promoteButton.widthAnchor.constraint(equalToConstant: 20),
            promoteButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Run-tabs strip: always visible when a task is selected. Layout:
        //   [Runs] [pill] [pill] …                       [+]
        // Bottom separator clearly delimits it from the log panel below.
        runTabsContainer = NSView()
        runTabsContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(runTabsContainer)

        runTabsLabel = NSTextField(labelWithString: "Runs")
        runTabsLabel.translatesAutoresizingMaskIntoConstraints = false
        runTabsLabel.font = Theme.Fonts.label(size: 10)
        runTabsLabel.textColor = Theme.tertiaryText
        runTabsLabel.backgroundColor = .clear
        runTabsLabel.isBezeled = false
        runTabsLabel.isEditable = false
        runTabsLabel.isSelectable = false
        runTabsContainer.addSubview(runTabsLabel)

        runTabsAddButton = makeIconButton(
            symbol: "plus",
            tooltip: "Start a new run",
            action: #selector(runTabsAddClicked)
        )
        runTabsContainer.addSubview(runTabsAddButton)

        runTabsStack = NSStackView()
        runTabsStack.translatesAutoresizingMaskIntoConstraints = false
        runTabsStack.orientation = .horizontal
        runTabsStack.spacing = 4
        runTabsStack.alignment = .centerY
        runTabsStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        runTabsScroll = NSScrollView()
        runTabsScroll.translatesAutoresizingMaskIntoConstraints = false
        runTabsScroll.hasVerticalScroller = false
        runTabsScroll.hasHorizontalScroller = false
        runTabsScroll.drawsBackground = false
        runTabsScroll.borderType = .noBorder
        runTabsScroll.documentView = runTabsStack
        runTabsContainer.addSubview(runTabsScroll)

        runTabsEmptyLabel = NSTextField(labelWithString: "no runs yet — tap ＋ or Run to start one")
        runTabsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        runTabsEmptyLabel.font = Theme.Fonts.body(size: 10)
        runTabsEmptyLabel.textColor = Theme.quaternaryText
        runTabsEmptyLabel.backgroundColor = .clear
        runTabsEmptyLabel.isBezeled = false
        runTabsEmptyLabel.isEditable = false
        runTabsEmptyLabel.isSelectable = false
        runTabsEmptyLabel.lineBreakMode = .byTruncatingTail
        runTabsEmptyLabel.isHidden = true
        runTabsContainer.addSubview(runTabsEmptyLabel)

        runTabsSeparator = NSView()
        runTabsSeparator.translatesAutoresizingMaskIntoConstraints = false
        runTabsSeparator.wantsLayer = true
        runTabsSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        runTabsContainer.addSubview(runTabsSeparator)

        // Themed frame around the log text area — gives logs a distinct
        // "terminal panel" feel vs. the plain surrounding chrome.
        logFrameView = NSView()
        logFrameView.translatesAutoresizingMaskIntoConstraints = false
        logFrameView.wantsLayer = true
        logFrameView.layer?.cornerRadius = Theme.CornerRadius.element
        logFrameView.layer?.backgroundColor = Theme.surfaceContainerLowest.cgColor
        logFrameView.layer?.borderColor = Theme.outlineVariant.cgColor
        logFrameView.layer?.borderWidth = 1
        container.addSubview(logFrameView)

        // Log text view — selectable, not editable, monospace.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = ThinScroller()

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = Theme.primaryText
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Enable word wrap (matches most log views).
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(
                width: scroll.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        scroll.documentView = textView
        logFrameView.addSubview(scroll)
        logScrollView = scroll
        logTextView = textView

        runTabsHeight = runTabsContainer.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            runTabsContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            runTabsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            runTabsContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            runTabsHeight,

            runTabsLabel.leadingAnchor.constraint(equalTo: runTabsContainer.leadingAnchor, constant: 10),
            runTabsLabel.centerYAnchor.constraint(equalTo: runTabsContainer.centerYAnchor, constant: -1),

            runTabsAddButton.trailingAnchor.constraint(equalTo: runTabsContainer.trailingAnchor, constant: -8),
            runTabsAddButton.centerYAnchor.constraint(equalTo: runTabsContainer.centerYAnchor, constant: -1),
            runTabsAddButton.widthAnchor.constraint(equalToConstant: 20),
            runTabsAddButton.heightAnchor.constraint(equalToConstant: 20),

            runTabsScroll.leadingAnchor.constraint(equalTo: runTabsLabel.trailingAnchor, constant: 8),
            runTabsScroll.trailingAnchor.constraint(equalTo: runTabsAddButton.leadingAnchor, constant: -6),
            runTabsScroll.topAnchor.constraint(equalTo: runTabsContainer.topAnchor),
            runTabsScroll.bottomAnchor.constraint(equalTo: runTabsContainer.bottomAnchor, constant: -1),

            runTabsStack.leadingAnchor.constraint(equalTo: runTabsScroll.contentView.leadingAnchor),
            runTabsStack.topAnchor.constraint(equalTo: runTabsScroll.contentView.topAnchor),
            runTabsStack.bottomAnchor.constraint(equalTo: runTabsScroll.contentView.bottomAnchor),
            runTabsStack.heightAnchor.constraint(equalTo: runTabsScroll.heightAnchor),

            runTabsEmptyLabel.leadingAnchor.constraint(equalTo: runTabsScroll.leadingAnchor),
            runTabsEmptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: runTabsScroll.trailingAnchor),
            runTabsEmptyLabel.centerYAnchor.constraint(equalTo: runTabsScroll.centerYAnchor),

            runTabsSeparator.leadingAnchor.constraint(equalTo: runTabsContainer.leadingAnchor, constant: 8),
            runTabsSeparator.trailingAnchor.constraint(equalTo: runTabsContainer.trailingAnchor, constant: -8),
            runTabsSeparator.bottomAnchor.constraint(equalTo: runTabsContainer.bottomAnchor),
            runTabsSeparator.heightAnchor.constraint(equalToConstant: 1),

            logFrameView.topAnchor.constraint(equalTo: runTabsContainer.bottomAnchor, constant: 4),
            logFrameView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            logFrameView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            logFrameView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: logFrameView.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: logFrameView.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: logFrameView.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: logFrameView.bottomAnchor, constant: -1),
        ])

        return container
    }

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> DimIconButton {
        let button = DimIconButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.refreshDimState()
        return button
    }

    override func layout() {
        super.layout()
        if !didSetInitialSplitPosition, splitView.bounds.height > 100 {
            splitView.setPosition(splitView.bounds.height * 0.6, ofDividerAt: 0)
            didSetInitialSplitPosition = true
        }
    }

    private func refreshEmptyState() {
        if store == nil {
            emptyLabel.stringValue = "Open a worktree to run commands."
            emptyLabel.isHidden = false
            splitView.isHidden = true
        } else if store?.tasks.isEmpty == true {
            emptyLabel.stringValue = "No commands detected. Tap + to add one, or create .amux/tasks.json."
            emptyLabel.isHidden = false
            splitView.isHidden = true
        } else {
            emptyLabel.isHidden = true
            splitView.isHidden = false
        }
        updateHeaderButtonsEnabled()
    }

    private func updateHeaderButtonsEnabled() {
        guard refreshButton != nil, addButton != nil else { return }
        let enabled = store != nil
        refreshButton.isEnabled = enabled
        addButton.isEnabled = enabled
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        refreshButton.alphaValue = alpha
        addButton.alphaValue = alpha
    }

    // MARK: - Outline data

    private func rebuildOutlineData() {
        var buckets: [RunnerTaskSource: [RunnerTask]] = [:]
        for task in store?.tasks ?? [] {
            buckets[task.source, default: []].append(task)
        }
        tasksBySource = buckets
        visibleSources = Self.sourceOrder.filter { !(buckets[$0]?.isEmpty ?? true) }

        // Reuse existing wrappers where possible so reloadItem keeps working.
        var newGroupItems: [RunnerTaskSource: RunnerOutlineItem] = [:]
        for src in visibleSources {
            newGroupItems[src] = groupItems[src] ?? RunnerOutlineItem(group: src)
        }
        groupItems = newGroupItems

        var newTaskItems: [String: RunnerOutlineItem] = [:]
        for task in store?.tasks ?? [] {
            if let existing = taskItems[task.id] {
                existing.task = task
                newTaskItems[task.id] = existing
            } else {
                newTaskItems[task.id] = RunnerOutlineItem(task: task)
            }
        }
        taskItems = newTaskItems
    }

    // MARK: - Notifications

    @objc private func storeDidChange(_ note: Notification) {
        guard let changedStore = note.object as? RunnerTaskStore,
              changedStore === store else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildOutlineData()
            self.outlineView.reloadData()
            for src in self.visibleSources {
                if let item = self.groupItems[src] { self.outlineView.expandItem(item) }
            }
            self.refreshEmptyState()
            self.refreshErrorBanner()
            // Clear stale selection if the task is gone.
            if let sel = self.selectedTaskID, self.taskItems[sel] == nil {
                self.selectedTaskID = nil
            } else {
                self.rebuildRunTabs()
                self.refreshLogPanel(replaceContents: false)
            }
        }
    }

    @objc private func runnerDidUpdate(_ note: Notification) {
        guard let taskId = note.userInfo?["taskId"] as? String,
              let notifWorktree = note.userInfo?["worktreePath"] as? String else { return }
        // Sessions are now keyed by (worktreePath, taskId). Drop notifications
        // that aren't for the worktree currently bound to this panel — otherwise
        // worktree A's "npm:dev" output would trigger row/log refreshes in
        // worktree B's UI.
        guard let boundWorktree = store?.worktreePath,
              notifWorktree == boundWorktree else { return }
        let notifRunNumber = note.userInfo?["runNumber"] as? Int
        // readabilityHandler fires off arbitrary threads; hop to main before
        // touching AppKit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Keep the outline row in sync (status square, play/stop icon).
            if let item = self.taskItems[taskId] {
                self.outlineView.reloadItem(item, reloadChildren: false)
            }
            // Refresh header buttons' enabled state in case session just appeared.
            self.updateLogButtonsEnabled()
            // Update run tabs (new run appeared, or status changed).
            if taskId == self.selectedTaskID {
                self.rebuildRunTabs()
            }
            // Coalesced log text refresh: only if the update is for the
            // currently displayed run of the currently selected task.
            if taskId == self.selectedTaskID {
                let displayedRun = self.selectedRunNumber
                    ?? self.runner.session(for: taskId, worktreePath: notifWorktree)?.runNumber
                if notifRunNumber == nil || notifRunNumber == displayedRun {
                    self.scheduleLogRefresh()
                }
            }
        }
    }

    // MARK: - Log panel refresh

    private func scheduleLogRefresh() {
        // Throttle (not debounce): under sustained output we must still
        // refresh every ~16 ms. Cancelling + rescheduling on every update
        // meant a never-pausing producer (e.g. a chatty dev server) could
        // starve the text view indefinitely. Instead, let the first
        // pending work item fire; subsequent updates are coalesced into it.
        if pendingLogRefresh != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingLogRefresh = nil
            self?.refreshLogPanel(replaceContents: false)
        }
        pendingLogRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
    }

    /// Refresh the log panel header + button states. When `replaceContents` is
    /// true the text view is replaced with the latest buffer snapshot (used on
    /// selection change and immediate refreshes). When false, contents are
    /// updated only if something is actually going to be displayed.
    private func refreshLogPanel(replaceContents: Bool) {
        guard logContainer != nil else { return }

        // Header label: task name or em-dash.
        let taskName: String
        if let id = selectedTaskID, let task = taskItems[id]?.task {
            taskName = task.name
        } else {
            taskName = "—"
        }
        logTaskNameLabel.stringValue = taskName

        updateLogButtonsEnabled()

        // Text view contents — route through the effective run so tab
        // selection (pinned historical run) overrides "latest".
        if replaceContents {
            // Force next render even if the raw text happens to match
            // (different run, same content edge case).
            lastRenderedRawSnapshot = nil
        }
        guard let session = effectiveSession() else {
            if replaceContents {
                setLogText("")
            }
            return
        }

        let snapshot = session.buffer.snapshot()
        setLogText(snapshot)
    }

    /// Run currently feeding the log panel, honoring `selectedRunNumber`
    /// (historical tab) or falling back to the latest run.
    private func effectiveSession() -> TaskRunSession? {
        guard let id = selectedTaskID,
              let worktreePath = store?.worktreePath else { return nil }
        if let pinned = selectedRunNumber {
            return runner.run(for: id, worktreePath: worktreePath, runNumber: pinned)
        }
        return runner.session(for: id, worktreePath: worktreePath)
    }

    /// Replace the text view's contents with ANSI-rendered output, preserving
    /// scroll position when the user has scrolled away from the bottom.
    private func setLogText(_ text: String) {
        guard let textView = logTextView, let scroll = logScrollView else { return }

        if lastRenderedRawSnapshot == text {
            return
        }
        lastRenderedRawSnapshot = text

        let atBottom: Bool = {
            let visibleMaxY = scroll.contentView.bounds.maxY
            let documentHeight = textView.frame.height
            return visibleMaxY >= documentHeight - 2
        }()

        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let rendered = ANSIRenderer.render(
            text,
            defaultColor: Theme.primaryText,
            font: font
        )
        textView.textStorage?.setAttributedString(rendered)

        if atBottom {
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollToEndOfDocument(nil)
            }
        }
    }

    private func updateLogButtonsEnabled() {
        guard promoteButton != nil else { return }
        let hasSession = effectiveSession() != nil
        // Stop only makes sense for the CURRENTLY running (latest) run.
        let latestRunning: Bool = {
            guard let id = selectedTaskID,
                  let worktreePath = store?.worktreePath else { return false }
            return runner.session(for: id, worktreePath: worktreePath)?.status == .running
        }()
        promoteButton.isEnabled = hasSession
        stopButton.isEnabled = latestRunning
        clearButton.isEnabled = hasSession
        // Alpha hint — DimIconButton doesn't style disabled state on its own.
        promoteButton.alphaValue = hasSession ? 1.0 : 0.4
        stopButton.alphaValue = latestRunning ? 1.0 : 0.4
        clearButton.alphaValue = hasSession ? 1.0 : 0.4
    }

    // MARK: - Run tabs

    /// Rebuild the run-tab strip for the currently selected task. Strip is
    /// visible whenever a task is selected, even with no runs — so users
    /// notice the + affordance and know where history will appear.
    private func rebuildRunTabs() {
        guard runTabsStack != nil else { return }

        runTabsStack.arrangedSubviews.forEach { view in
            runTabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let hasTask = selectedTaskID != nil && store != nil
        runTabsHeight.constant = hasTask ? 30 : 0
        runTabsAddButton.isEnabled = hasTask
        runTabsAddButton.alphaValue = hasTask ? 1.0 : 0.4

        let runs: [TaskRunSession] = {
            guard let id = selectedTaskID,
                  let worktreePath = store?.worktreePath else { return [] }
            return runner.runs(for: id, worktreePath: worktreePath)
        }()

        runTabsEmptyLabel.isHidden = !hasTask || !runs.isEmpty

        let activeRun = selectedRunNumber ?? runs.last?.runNumber ?? -1
        for session in runs {
            let pill = RunTabPill(runNumber: session.runNumber, status: session.status, isActive: session.runNumber == activeRun)
            pill.onClick = { [weak self] in
                self?.selectRun(session.runNumber)
            }
            pill.onDelete = { [weak self] in
                self?.deleteRun(session.runNumber)
            }
            runTabsStack.addArrangedSubview(pill)
        }
    }

    fileprivate func selectRun(_ runNumber: Int) {
        // Pinning to the latest run is equivalent to nil (follow-latest).
        guard let id = selectedTaskID,
              let worktreePath = store?.worktreePath else { return }
        let latest = runner.session(for: id, worktreePath: worktreePath)?.runNumber
        selectedRunNumber = (runNumber == latest) ? nil : runNumber
        rebuildRunTabs()
        refreshLogPanel(replaceContents: true)
    }

    /// Delete a run from history. If it's still running, the process is
    /// killed first; the user confirms before the kill.
    fileprivate func deleteRun(_ runNumber: Int) {
        guard let id = selectedTaskID,
              let worktreePath = store?.worktreePath else { return }
        let target = runner.run(for: id, worktreePath: worktreePath, runNumber: runNumber)
        if target?.status == .running {
            let alert = NSAlert()
            alert.messageText = "Delete Run \(runNumber)?"
            alert.informativeText = "This run is still active. Deleting will force-stop the process."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if selectedRunNumber == runNumber { selectedRunNumber = nil }
        runner.removeRun(id: id, worktreePath: worktreePath, runNumber: runNumber)
        rebuildRunTabs()
        refreshLogPanel(replaceContents: true)
    }

    @objc private func runTabsAddClicked() {
        // Start a fresh run regardless of whether the current one is still
        // going — user explicitly asked for a new run (likely because they
        // want the prior log preserved as a historical tab).
        guard let id = selectedTaskID,
              let worktreePath = store?.worktreePath,
              let task = taskItems[id]?.task else { return }
        selectedRunNumber = nil
        // `runner.start` already stops the prior run (keeps it as history)
        // so a plain start call gives the behavior the user expects here.
        runner.start(task, worktreePath: worktreePath)
    }

    // MARK: - Log panel actions

    @objc private func promoteClicked() {
        guard let id = selectedTaskID,
              let task = taskItems[id]?.task,
              let worktreePath = store?.worktreePath else { return }
        let cwd: String = {
            if let raw = task.cwd {
                return (raw as NSString).isAbsolutePath
                    ? raw
                    : (worktreePath as NSString).appendingPathComponent(raw)
            }
            return worktreePath
        }()

        // Leave a breadcrumb in the latest run's buffer BEFORE stopping so
        // the user can scroll the inline log later and see where the run
        // went. Only do this if there's actually a session; a never-started
        // task has nothing to annotate.
        if let session = runner.session(for: id, worktreePath: worktreePath) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            session.buffer.append("Promoted to pane at \(formatter.string(from: Date()))\n")
            runner.stop(id: id, worktreePath: worktreePath)
        }

        delegate?.runnerPanelDidRequestOpenInPane(command: task.command, cwd: cwd)
    }

    @objc private func stopClicked() {
        guard let id = selectedTaskID,
              let worktreePath = store?.worktreePath else { return }
        runner.stop(id: id, worktreePath: worktreePath)
    }

    @objc private func clearClicked() {
        // Clear only the currently displayed run's buffer; historical tabs
        // keep their logs so users can reference prior runs.
        if let session = effectiveSession() {
            session.buffer.clear()
        }
        logTextView?.string = ""
    }

    // MARK: - Error banner

    /// Show/hide the red banner based on `store?.loadError`. Collapsing the
    /// height to 0 when hidden keeps the split view flush against the header
    /// — we don't want a ghost gap when everything is fine.
    private func refreshErrorBanner() {
        guard errorBanner != nil else { return }
        if let msg = store?.loadError {
            errorBannerLabel.stringValue = msg
            errorBannerLabel.toolTip = msg
            errorBanner.isHidden = false
            errorBannerHeight.constant = 32
        } else {
            errorBannerLabel.stringValue = ""
            errorBannerLabel.toolTip = nil
            errorBanner.isHidden = true
            errorBannerHeight.constant = 0
        }
    }

    @objc private func editTasksFileClicked() {
        guard let store else { return }
        let url = URL(fileURLWithPath: store.worktreePath)
            .appendingPathComponent(".amux")
            .appendingPathComponent("tasks.json")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // Open the parent `.amux/` so Finder has something to show. Create
            // it first so the open call has a real target.
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            NSWorkspace.shared.open(parent)
        }
    }

    // MARK: - Header actions

    @objc private func refreshClicked() {
        store?.reload()
    }

    @objc private func addCustomTaskClicked() {
        guard let store, let hostWindow = window else { return }

        // Ids already used by pinned tasks, so we can de-dupe the derived id
        // against those (and only those — colliding with a detected id is the
        // intended "override" behavior).
        let pinnedIDs = Set(store.tasks.filter { $0.source == .pinned }.map(\.id))

        let sheet = AddCustomTaskSheet(existingPinnedIDs: pinnedIDs)
        sheet.onConfirmHandler = { [weak sheet] task, dismiss in
            guard let sheet else { return }
            do {
                try store.addPinned(task)
                dismiss()
            } catch {
                // Keep the sheet open so the user can fix their input — the
                // alert is presented on the sheet itself, not the host window.
                let alert = NSAlert()
                alert.messageText = "Unable to add task"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.beginSheetModal(for: sheet)
            }
        }
        hostWindow.beginSheet(sheet, completionHandler: nil)
    }

    // MARK: - Click handling

    @objc private func outlineRowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? RunnerOutlineItem else {
            return
        }
        switch item.kind {
        case .group:
            // Let NSOutlineView handle group expand/collapse via its default behavior.
            break
        case .task(let task):
            selectedTaskID = task.id
        }
    }

    @objc private func outlineRowDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? RunnerOutlineItem else {
            return
        }
        if case .task(let task) = item.kind {
            // Belt-and-braces: double-click implies the row was selected, but
            // explicitly set so the log panel routes to this task immediately.
            selectedTaskID = task.id
            toggleRun(task: task)
        }
        // Group rows: NSOutlineView handles expand/collapse itself.
    }

    // MARK: - Context menu actions

    @objc fileprivate func deletePinnedClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let store = store else { return }

        // If the task is currently running, confirm before stopping + deleting.
        if let session = runner.session(for: id, worktreePath: store.worktreePath),
           session.status == .running {
            let alert = NSAlert()
            alert.messageText = "Delete task?"
            alert.informativeText = "This task is currently running. It will be stopped and the entry removed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            runner.stop(id: id, worktreePath: store.worktreePath)
        }

        do {
            try store.removePinned(id: id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't delete task"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    fileprivate func toggleRun(task: RunnerTask) {
        guard let worktreePath = store?.worktreePath else { return }
        // Route the log panel to the task being toggled, so the user sees
        // output in the bottom pane the moment Run (or Stop) is clicked —
        // otherwise a red status square with an empty "—" log panel is confusing.
        selectedTaskID = task.id
        // A fresh start should follow the newly-spawned run, not stay pinned
        // to whatever historical tab the user had selected.
        selectedRunNumber = nil
        if let session = runner.session(for: task.id, worktreePath: worktreePath),
           session.status == .running {
            runner.stop(id: task.id, worktreePath: worktreePath)
        } else {
            runner.start(task, worktreePath: worktreePath)
        }
    }

    // MARK: - Glass

    private func applyGlassOrSolid() {
        if Theme.useVibrancy && !chromeHidden {
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
        emptyLabel?.textColor = Theme.tertiaryText
        emptyLabel?.font = Theme.Fonts.body(size: 12)
        logTitleLabel?.textColor = Theme.tertiaryText
        logTitleLabel?.font = Theme.Fonts.label(size: 10)
        logTaskNameLabel?.textColor = Theme.secondaryText
        logTaskNameLabel?.font = Theme.Fonts.body(size: 11)
        logTextView?.textColor = Theme.primaryText
        logFrameView?.layer?.backgroundColor = Theme.surfaceContainerLowest.cgColor
        logFrameView?.layer?.borderColor = Theme.outlineVariant.cgColor
        outlineView?.reloadData()
        for src in visibleSources {
            if let item = groupItems[src] { outlineView.expandItem(item) }
        }
        rebuildRunTabs()
        lastRenderedRawSnapshot = nil
        refreshLogPanel(replaceContents: true)
    }
}

// MARK: - NSSplitViewDelegate

extension RunnerPanelView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 80
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.bounds.height - 80
    }
}

// MARK: - NSMenuDelegate (context menu for outline rows)

extension RunnerPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0,
              let wrapper = outlineView.item(atRow: row) as? RunnerOutlineItem,
              case .task(let task) = wrapper.kind,
              task.source == .pinned else {
            // Non-pinned rows (auto-detected, group headers) get no menu.
            // Leaving the menu empty causes AppKit to skip presenting it.
            return
        }
        let delete = NSMenuItem(
            title: "Delete",
            action: #selector(deletePinnedClicked(_:)),
            keyEquivalent: ""
        )
        delete.target = self
        delete.representedObject = task.id
        menu.addItem(delete)
    }
}

// MARK: - NSOutlineViewDataSource / Delegate

extension RunnerPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return visibleSources.count }
        guard let wrapper = item as? RunnerOutlineItem, case .group(let src) = wrapper.kind else {
            return 0
        }
        return tasksBySource[src]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let src = visibleSources[index]
            return groupItems[src]!
        }
        if let wrapper = item as? RunnerOutlineItem, case .group(let src) = wrapper.kind,
           let tasks = tasksBySource[src] {
            let task = tasks[index]
            return taskItems[task.id]!
        }
        fatalError("Unexpected outline item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let wrapper = item as? RunnerOutlineItem else { return false }
        if case .group = wrapper.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let wrapper = item as? RunnerOutlineItem else { return nil }
        switch wrapper.kind {
        case .group(let src):
            var cell = outlineView.makeView(withIdentifier: RunnerPanelView.groupCellID, owner: self) as? RunnerGroupCell
            if cell == nil {
                cell = RunnerGroupCell()
                cell?.identifier = RunnerPanelView.groupCellID
            }
            cell?.configure(source: src)
            return cell
        case .task(let task):
            var cell = outlineView.makeView(withIdentifier: RunnerPanelView.taskCellID, owner: self) as? RunnerTaskCell
            if cell == nil {
                cell = RunnerTaskCell()
                cell?.identifier = RunnerPanelView.taskCellID
            }
            let status: TaskStatus? = {
                guard let worktreePath = store?.worktreePath else { return nil }
                return runner.session(for: task.id, worktreePath: worktreePath)?.status
            }()
            cell?.configure(task: task, status: status) { [weak self] in
                self?.toggleRun(task: task)
            }
            return cell
        }
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

// MARK: - Outline item wrapper
//
// Class so NSOutlineView can key off pointer identity — critical for
// `reloadItem(_:)` to find the row when `TaskRunner` posts an update.

fileprivate final class RunnerOutlineItem {
    enum Kind {
        case group(RunnerTaskSource)
        case task(RunnerTask)
    }

    var kind: Kind

    init(group: RunnerTaskSource) { self.kind = .group(group) }
    init(task: RunnerTask) { self.kind = .task(task) }

    var task: RunnerTask {
        get {
            if case .task(let t) = kind { return t }
            fatalError("RunnerOutlineItem.task accessed on group item")
        }
        set { kind = .task(newValue) }
    }
}

// MARK: - NSOutlineView subclass for right-click row selection
//
// Default NSOutlineView doesn't highlight the row under the cursor on
// right-click, so `clickedRow` in menuNeedsUpdate reports the row correctly
// but the user sees no visual confirmation. Selecting the row here gives
// feedback and lets menuNeedsUpdate rely on clickedRow/selectedRow.

fileprivate final class RunnerOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

// MARK: - Group header cell

private final class RunnerGroupCell: NSView {
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

    func configure(source: RunnerTaskSource) {
        label.stringValue = source.rawValue.capitalized
        label.textColor = Theme.tertiaryText
        label.font = Theme.Fonts.label(size: 10)
    }
}

// MARK: - Task row cell

private final class RunnerTaskCell: NSView {
    private let hoverBg = NSView()
    private let toggleButton = DimIconButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let customBadge = NSTextField(labelWithString: "custom")
    private let statusDot = NSView()

    private var onToggle: (() -> Void)?
    private var isHovered = false {
        didSet { updateHoverBg() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        hoverBg.translatesAutoresizingMaskIntoConstraints = false
        hoverBg.wantsLayer = true
        hoverBg.layer?.cornerRadius = Theme.CornerRadius.element
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverBg)

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.imagePosition = .imageOnly
        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        toggleButton.refreshDimState()
        addSubview(toggleButton)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Theme.Fonts.body(size: 12)
        nameLabel.textColor = Theme.secondaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        customBadge.translatesAutoresizingMaskIntoConstraints = false
        customBadge.wantsLayer = true
        customBadge.layer?.cornerRadius = 3
        customBadge.font = Theme.Fonts.label(size: 9)
        customBadge.textColor = Theme.secondaryText
        customBadge.drawsBackground = true
        customBadge.backgroundColor = Theme.surfaceContainerHigh
        customBadge.isBezeled = false
        customBadge.isEditable = false
        customBadge.isSelectable = false
        customBadge.alignment = .center
        customBadge.setContentHuggingPriority(.required, for: .horizontal)
        customBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(customBadge)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        // Square (not circle) so it's distinguishable from the dirty-dot motif
        // used elsewhere; subtle rounding keeps it on-brand with the rest of
        // the app's rounded-rect chrome.
        statusDot.layer?.cornerRadius = 1.5
        statusDot.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(statusDot)

        NSLayoutConstraint.activate([
            hoverBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            hoverBg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            hoverBg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 18),
            toggleButton.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            customBadge.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            customBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            customBadge.heightAnchor.constraint(equalToConstant: 13),
            customBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),

            statusDot.leadingAnchor.constraint(equalTo: customBadge.trailingAnchor, constant: 6),
            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        guard let window = window else { isHovered = false; return }
        let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(loc) {
            isHovered = false
        }
    }

    private func updateHoverBg() {
        CALayer.performWithoutAnimation {
            hoverBg.layer?.backgroundColor = isHovered
                ? Theme.hoverBg.cgColor
                : NSColor.clear.cgColor
        }
    }

    func configure(task: RunnerTask, status: TaskStatus?, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        let isRunning: Bool
        if let status, case .running = status { isRunning = true } else { isRunning = false }

        let symbolName = isRunning ? "stop.circle.fill" : "play.circle.fill"
        toggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        toggleButton.toolTip = isRunning ? "Stop" : "Run"
        toggleButton.refreshDimState()

        nameLabel.stringValue = task.name
        nameLabel.toolTip = task.command
        nameLabel.font = Theme.Fonts.body(size: 12)
        nameLabel.textColor = Theme.secondaryText

        customBadge.isHidden = !task.isOverridden
        customBadge.backgroundColor = Theme.surfaceContainerHigh
        customBadge.textColor = Theme.secondaryText

        let dotColor: NSColor
        switch status {
        case .running?:
            dotColor = Theme.primary
        case .failedToStart?:
            dotColor = NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)
        case .exited(let code)?:
            dotColor = code == 0
                ? NSColor.gray.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)
        case .terminated?:
            dotColor = NSColor(srgbRed: 0.95, green: 0.60, blue: 0.20, alpha: 1.0)
        case nil:
            dotColor = .clear
        }
        CALayer.performWithoutAnimation {
            statusDot.layer?.backgroundColor = dotColor.cgColor
        }
    }

    @objc private func toggleClicked() {
        onToggle?()
    }
}

// MARK: - Run tab pill
//
// Lightweight pill shown in the run-tabs strip. Carries the run number and a
// small status square. Clicking selects that run in the log panel.

private final class RunTabPill: NSView {
    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?

    let runNumber: Int
    private let label = NSTextField(labelWithString: "")
    private let statusSquare = NSView()
    private var isHovered = false
    private let isActive: Bool

    init(runNumber: Int, status: TaskStatus, isActive: Bool) {
        self.runNumber = runNumber
        self.isActive = isActive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Theme.CornerRadius.element
        layer?.borderWidth = isActive ? 0 : 1
        layer?.borderColor = Theme.outlineVariant.cgColor

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Delete Run", action: #selector(deleteClicked), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        self.menu = menu

        statusSquare.translatesAutoresizingMaskIntoConstraints = false
        statusSquare.wantsLayer = true
        statusSquare.layer?.cornerRadius = 1.5
        statusSquare.layer?.backgroundColor = Self.color(for: status).cgColor
        addSubview(statusSquare)

        label.stringValue = "Run \(runNumber)"
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.label(size: 10)
        label.textColor = isActive ? Theme.primaryText : Theme.tertiaryText
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            statusSquare.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            statusSquare.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusSquare.widthAnchor.constraint(equalToConstant: 7),
            statusSquare.heightAnchor.constraint(equalToConstant: 7),

            label.leadingAnchor.constraint(equalTo: statusSquare.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 20),
        ])

        applyBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false; applyBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    @objc private func deleteClicked() {
        onDelete?()
    }

    private func applyBackground() {
        let bg: NSColor
        if isActive {
            bg = Theme.activeBg
        } else if isHovered {
            bg = Theme.hoverBg
        } else {
            bg = .clear
        }
        CALayer.performWithoutAnimation {
            layer?.backgroundColor = bg.cgColor
        }
    }

    private static func color(for status: TaskStatus) -> NSColor {
        switch status {
        case .running:
            return Theme.primary
        case .failedToStart:
            return NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)
        case .exited(let code):
            return code == 0
                ? NSColor.gray.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)
        case .terminated:
            return NSColor(srgbRed: 0.95, green: 0.60, blue: 0.20, alpha: 1.0)
        }
    }
}
