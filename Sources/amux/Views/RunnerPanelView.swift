import AppKit

// MARK: - Delegate

protocol RunnerPanelViewDelegate: AnyObject {
    /// Called when the user taps "Open in pane" for a running task.
    func runnerPanelDidRequestOpenInPane(command: String, cwd: String)
}

// MARK: - Runner Panel View
//
// Right-side panel that lists user-defined tasks for the active worktree and
// will later host run/stop controls and a log viewer. Task 11 adds the
// scrollable outline list (grouped by source) with play/stop toggles and
// status dots. Log panel, "+" sheet, and loadError banner land in later tasks.

final class RunnerPanelView: NSView {
    weak var delegate: RunnerPanelViewDelegate?

    /// Distance from the view's top to the first content row. Matches the
    /// convention used by GitPanelView / EditorSidebarView so the parent can
    /// slot this view under a shared header.
    var topContentInset: CGFloat = 10 {
        didSet {
            topInsetConstraint?.constant = topContentInset
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

    /// Most recently selected task id. Task 12's log panel reads this.
    private(set) var selectedTaskID: String?

    private var glassView: GlassBackgroundView?
    private var emptyLabel: NSTextField!
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var topInsetConstraint: NSLayoutConstraint?
    private var scrollTopConstraint: NSLayoutConstraint?

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
        addSubview(scrollView)

        let scrollTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)
        scrollTopConstraint = scrollTop
        NSLayoutConstraint.activate([
            scrollTop,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Empty-state label floats above the outline; only one is visible at a time.
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

        let topC = emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)
        topInsetConstraint = topC
        NSLayoutConstraint.activate([
            topC,
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        applyGlassOrSolid()
        refreshEmptyState()
    }

    private func refreshEmptyState() {
        if store == nil {
            emptyLabel.stringValue = "Open a worktree to run tasks."
            emptyLabel.isHidden = false
            scrollView.isHidden = true
        } else if store?.tasks.isEmpty == true {
            emptyLabel.stringValue = "No tasks detected. Tap + to add one, or create .amux/tasks.json."
            emptyLabel.isHidden = false
            scrollView.isHidden = true
        } else {
            emptyLabel.isHidden = true
            scrollView.isHidden = false
        }
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
        }
    }

    @objc private func runnerDidUpdate(_ note: Notification) {
        guard let taskId = note.userInfo?["taskId"] as? String else { return }
        // readabilityHandler fires off arbitrary threads; hop to main before
        // touching AppKit.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.taskItems[taskId] else { return }
            self.outlineView.reloadItem(item, reloadChildren: false)
        }
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
            toggleRun(task: task)
        }
        // Group rows: NSOutlineView handles expand/collapse itself.
    }

    fileprivate func toggleRun(task: RunnerTask) {
        guard let worktreePath = store?.worktreePath else { return }
        if let session = runner.session(for: task.id), session.status == .running {
            runner.stop(id: task.id)
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
        outlineView?.reloadData()
        for src in visibleSources {
            if let item = groupItems[src] { outlineView.expandItem(item) }
        }
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
            let status = runner.session(for: task.id)?.status
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
