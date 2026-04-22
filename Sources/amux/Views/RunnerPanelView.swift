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

    // Coalesce log refreshes so rapid output bursts don't starve the main thread.
    private var pendingLogRefresh: DispatchWorkItem?

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
                rebuildOutlineData()
                outlineView.reloadData()
                for src in visibleSources {
                    if let item = groupItems[src] { outlineView.expandItem(item) }
                }
            }
        } else {
            if store != nil {
                store = nil
                selectedTaskID = nil
                rebuildOutlineData()
                outlineView.reloadData()
            }
        }
        refreshEmptyState()
        refreshErrorBanner()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        // Outline + scroll view host the task list.
        outlineView = NSOutlineView()
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

        headerTitleLabel = NSTextField(labelWithString: "Tasks")
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
            tooltip: "Refresh tasks",
            action: #selector(refreshClicked)
        )
        addButton = makeIconButton(
            symbol: "plus.circle",
            tooltip: "Add custom task",
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
        textView.textColor = Theme.secondaryText
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
        container.addSubview(scroll)
        logScrollView = scroll
        logTextView = textView

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
            emptyLabel.stringValue = "Open a worktree to run tasks."
            emptyLabel.isHidden = false
            splitView.isHidden = true
        } else if store?.tasks.isEmpty == true {
            emptyLabel.stringValue = "No tasks detected. Tap + to add one, or create .amux/tasks.json."
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
        // readabilityHandler fires off arbitrary threads; hop to main before
        // touching AppKit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Keep the outline row in sync (status dot, play/stop icon).
            if let item = self.taskItems[taskId] {
                self.outlineView.reloadItem(item, reloadChildren: false)
            }
            // Refresh header buttons' enabled state in case session just appeared.
            self.updateLogButtonsEnabled()
            // Coalesced log text refresh: only if the update is for the selected task.
            if taskId == self.selectedTaskID {
                self.scheduleLogRefresh()
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

        // Text view contents.
        guard let id = selectedTaskID,
              let worktreePath = store?.worktreePath,
              let session = runner.session(for: id, worktreePath: worktreePath) else {
            if replaceContents {
                setLogText("")
            }
            return
        }

        let snapshot = session.buffer.snapshot()
        setLogText(snapshot)
    }

    /// Replace the text view's contents, preserving scroll position when the
    /// user has scrolled away from the bottom.
    private func setLogText(_ text: String) {
        guard let textView = logTextView, let scroll = logScrollView else { return }

        // Determine "at bottom" BEFORE mutating contents. Use a small slack
        // window because scrollers are overlays and content insets can nudge
        // the math by a pixel or two.
        let atBottom: Bool = {
            let visibleMaxY = scroll.contentView.bounds.maxY
            let documentHeight = textView.frame.height
            return visibleMaxY >= documentHeight - 2
        }()

        if textView.string != text {
            textView.string = text
        }

        if atBottom {
            // Defer to next runloop tick so layout settles before scrolling.
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollToEndOfDocument(nil)
            }
        }
    }

    private func updateLogButtonsEnabled() {
        guard promoteButton != nil else { return }
        let hasSelection = selectedTaskID != nil
        let hasSession: Bool = {
            guard let id = selectedTaskID,
                  let worktreePath = store?.worktreePath else { return false }
            return runner.session(for: id, worktreePath: worktreePath) != nil
        }()
        let enabled = hasSelection && hasSession
        promoteButton.isEnabled = enabled
        stopButton.isEnabled = enabled
        clearButton.isEnabled = enabled
        // Alpha hint — DimIconButton doesn't style disabled state on its own.
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        promoteButton.alphaValue = alpha
        stopButton.alphaValue = alpha
        clearButton.alphaValue = alpha
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

        // Leave a breadcrumb in the log buffer BEFORE stopping so the user
        // can scroll the inline log later and see where the run went. Only
        // do this if there's actually a session; a never-started task has
        // nothing to annotate.
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
        if let id = selectedTaskID,
           let worktreePath = store?.worktreePath,
           let session = runner.session(for: id, worktreePath: worktreePath) {
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

    fileprivate func toggleRun(task: RunnerTask) {
        guard let worktreePath = store?.worktreePath else { return }
        // Route the log panel to the task being toggled, so the user sees
        // output in the bottom pane the moment Run (or Stop) is clicked —
        // otherwise a red status dot with an empty "—" log panel is confusing.
        selectedTaskID = task.id
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
        logTextView?.textColor = Theme.secondaryText
        outlineView?.reloadData()
        for src in visibleSources {
            if let item = groupItems[src] { outlineView.expandItem(item) }
        }
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

private final class RunnerOutlineItem {
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
    private let toggleButton = DimIconButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let customBadge = NSTextField(labelWithString: "custom")
    private let statusDot = NSView()

    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

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
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(statusDot)

        NSLayoutConstraint.activate([
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
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(task: RunnerTask, status: TaskStatus?, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        let isRunning: Bool
        if let status, case .running = status { isRunning = true } else { isRunning = false }

        let symbolName = isRunning ? "stop.fill" : "play.fill"
        toggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
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
