import AppKit
import CGhostty

extension NSToolbarItem.Identifier {
    fileprivate static let sidebarToggle = NSToolbarItem.Identifier("sidebarToggle")
    fileprivate static let flexSpace = NSToolbarItem.Identifier.flexibleSpace
    fileprivate static let actions = NSToolbarItem.Identifier("actions")
}

private typealias ToolbarIconButton = DimIconButton

class MainWindowController: NSWindowController {
    private(set) var sidebarView: SidebarView!
    private(set) var splitContainerView: SplitContainerView!
    private(set) var globalStatusBar: PaneStatusBar!
    private var titlebarGlassView: GlassBackgroundView?
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarLeadingConstraint: NSLayoutConstraint!
    private var resizeHandle: SidebarResizeHandle!

    // Right sidebar (tabbed: editor + git + runner). Replaces the previous two panels.
    private(set) var rightSidebarView: RightSidebarView!
    private(set) var runnerPanelView: RunnerPanelView!
    var editorSidebarView: EditorSidebarView { rightSidebarView.editorSidebarView }
    var gitPanelView: GitPanelView { rightSidebarView.gitPanelView }
    private var rightSidebarWidthConstraint: NSLayoutConstraint!
    private var rightSidebarTrailingConstraint: NSLayoutConstraint!
    private var rightSidebarResizeHandle: SidebarResizeHandle!

    private(set) var isRightSidebarVisible = false
    private(set) var isEditorExpanded = false
    private var rightSidebarWidth: CGFloat = 460
    private var rightSidebarWidthBeforeExpand: CGFloat = 460
    private let minRightSidebarWidth: CGFloat = 320
    private let maxRightSidebarWidth: CGFloat = 640

    // Compatibility aliases so existing call sites keep working.
    var isEditorSidebarVisible: Bool { isRightSidebarVisible && rightSidebarView.mode == .editor }
    var isGitPanelVisible: Bool { isRightSidebarVisible && rightSidebarView.mode == .git }

    private let sessionManager: SessionManager
    private(set) var agentManager: AgentManager
    private(set) var projectManager: ProjectManager
    private var toolbarButtons: [ToolbarIconButton] = []
    private var toolbarEditorDropdown: EditorDropdownButton?
    private var statusPollTimer: Timer?

    private(set) var isSidebarVisible = true
    private var sidebarWidth: CGFloat = 220
    private let minSidebarWidth: CGFloat = 150
    private let maxSidebarWidth: CGFloat = 400

    init(sessionManager: SessionManager, agentManager: AgentManager, projectManager: ProjectManager)
    {
        self.sessionManager = sessionManager
        self.agentManager = agentManager
        self.projectManager = projectManager

        let window = MainWindowController.createWindow()
        super.init(window: window)

        setupToolbar()
        setupViews()

        // Restore project root scope so new tabs open in the right directory
        if let activeProject = projectManager.activeProject {
            splitContainerView.projectRootPath = activeProject.rootPath
        }

        if let activeSession = sessionManager.activeSession {
            displaySession(activeSession)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )

        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) {
            [weak self] _ in
            self?.pollSessionStatuses()
        }
    }

    deinit {
        statusPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        window?.appearance = NSAppearance(
            named: ThemeManager.shared.current.isLight ? .aqua : .darkAqua)
        if Theme.useVibrancy {
            window?.backgroundColor = .clear
            window?.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            titlebarGlassView?.isHidden = false
            titlebarGlassView?.setTint(Theme.background, opacity: 0.55)
        } else {
            window?.backgroundColor = Theme.background
            window?.contentView?.layer?.backgroundColor = Theme.background.cgColor
            titlebarGlassView?.isHidden = true
        }
        for button in toolbarButtons {
            button.refreshDimState()
        }
        toolbarEditorDropdown?.refreshTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Window creation

    private static func createWindow() -> NSWindow {
        let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.title = "amux"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(
            named: ThemeManager.shared.current.isLight ? .aqua : .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.background

        let contentView = NSView(frame: contentRect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Theme.background.cgColor
        window.contentView = contentView

        return window
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
    }

    // MARK: - View setup

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // The contentLayoutGuide respects the titlebar/toolbar area,
        // so views pinned to it won't overlap the toolbar.
        guard let layoutGuide = window?.contentLayoutGuide as? NSLayoutGuide else { return }

        // The split container hosts Metal-backed terminal surfaces, so it needs to
        // sit at the back of the z-order or it can paint over sibling views.
        splitContainerView = SplitContainerView(frame: .zero)
        splitContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitContainerView)

        sidebarView = SidebarView(
            sessionManager: sessionManager, agentManager: agentManager,
            projectManager: projectManager)
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.delegate = self
        contentView.addSubview(sidebarView)

        globalStatusBar = PaneStatusBar(frame: .zero)
        globalStatusBar.translatesAutoresizingMaskIntoConstraints = false
        globalStatusBar.setPaneCountProvider { [weak self] in
            self?.sessionManager.activeSession?.splitTree.allPaneIDs().count ?? 0
        }
        contentView.addSubview(globalStatusBar)

        resizeHandle = SidebarResizeHandle()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onResize = { [weak self] delta in
            self?.resizeSidebar(by: delta)
        }
        contentView.addSubview(resizeHandle)

        let editorSidebar = EditorSidebarView(frame: .zero)
        editorSidebar.delegate = self

        let gitPanel = GitPanelView(frame: .zero)
        gitPanel.delegate = self

        runnerPanelView = RunnerPanelView()
        runnerPanelView.delegate = self

        let containerPanel = ContainerPanelView(frame: .zero)
        containerPanel.delegate = self

        rightSidebarView = RightSidebarView(
            editorSidebarView: editorSidebar,
            gitPanelView: gitPanel,
            runnerPanelView: runnerPanelView,
            containerPanelView: containerPanel
        )
        rightSidebarView.translatesAutoresizingMaskIntoConstraints = false
        rightSidebarView.delegate = self
        contentView.addSubview(rightSidebarView)

        rightSidebarResizeHandle = SidebarResizeHandle()
        rightSidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        rightSidebarResizeHandle.onResize = { [weak self] delta in
            self?.resizeRightSidebar(by: -delta)
        }
        contentView.addSubview(rightSidebarResizeHandle)

        // Glass background behind the titlebar/toolbar area (center region only).
        // Sidebars already extend to contentView.topAnchor with their own glass views,
        // but the toolbar strip above the split container has no backing in glass mode.
        let tbGlass = GlassBackgroundView(blending: .behindWindow)
        tbGlass.translatesAutoresizingMaskIntoConstraints = false
        tbGlass.setTint(Theme.background, opacity: 0.55)
        tbGlass.isHidden = !Theme.useVibrancy
        contentView.addSubview(tbGlass, positioned: .above, relativeTo: splitContainerView)
        titlebarGlassView = tbGlass

        // Left sidebar constraints (leading edge, slides left to hide)
        sidebarLeadingConstraint = sidebarView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: 0
        )
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(equalToConstant: sidebarWidth)

        // Clip content view so off-screen sidebars don't leak beyond the window
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true

        // Right sidebar: single container pins to contentView.trailing, slides right when hidden.
        rightSidebarTrailingConstraint = rightSidebarView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: rightSidebarWidth
        )
        rightSidebarWidthConstraint = rightSidebarView.widthAnchor.constraint(
            equalToConstant: rightSidebarWidth)
        rightSidebarWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Left sidebar
            sidebarLeadingConstraint,
            sidebarWidthConstraint,
            sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Left resize handle
            resizeHandle.leadingAnchor.constraint(
                equalTo: sidebarView.trailingAnchor, constant: -2),
            resizeHandle.topAnchor.constraint(equalTo: contentView.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 5),

            // Right sidebar (unified editor + git tabs)
            rightSidebarTrailingConstraint,
            rightSidebarWidthConstraint,
            rightSidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightSidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Right resize handle
            rightSidebarResizeHandle.trailingAnchor.constraint(
                equalTo: rightSidebarView.leadingAnchor, constant: 2),
            rightSidebarResizeHandle.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightSidebarResizeHandle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rightSidebarResizeHandle.widthAnchor.constraint(equalToConstant: 5),

            // Titlebar glass: spans the toolbar strip above the split container
            tbGlass.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            tbGlass.trailingAnchor.constraint(equalTo: rightSidebarView.leadingAnchor),
            tbGlass.topAnchor.constraint(equalTo: contentView.topAnchor),
            tbGlass.bottomAnchor.constraint(equalTo: layoutGuide.topAnchor),

            // Split container: between the left sidebar and the right sidebar
            splitContainerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            splitContainerView.trailingAnchor.constraint(equalTo: rightSidebarView.leadingAnchor),
            splitContainerView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            splitContainerView.bottomAnchor.constraint(equalTo: globalStatusBar.topAnchor),

            // Status bar: between the left sidebar and the right sidebar
            globalStatusBar.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            globalStatusBar.trailingAnchor.constraint(equalTo: rightSidebarView.leadingAnchor),
            globalStatusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            globalStatusBar.heightAnchor.constraint(equalToConstant: PaneStatusBar.barHeight),
        ])
    }

    // MARK: - Sidebar resize

    private func resizeSidebar(by delta: CGFloat) {
        let newWidth = (sidebarWidthConstraint.constant + delta)
            .clamped(to: minSidebarWidth...maxSidebarWidth)
        sidebarWidthConstraint.constant = newWidth
        sidebarWidth = newWidth
    }

    // MARK: - Right sidebar resize

    private func resizeRightSidebar(by delta: CGFloat) {
        let newWidth = (rightSidebarWidthConstraint.constant + delta)
            .clamped(to: minRightSidebarWidth...maxRightSidebarWidth)
        rightSidebarWidthConstraint.constant = newWidth
        rightSidebarWidth = newWidth
    }

    // MARK: - Right sidebar toggle

    /// Shows or hides the unified right sidebar. `mode`, if provided, forces
    /// a specific tab so the palette-level "Toggle Editor" / "Toggle Git"
    /// commands land on the right content.
    func toggleRightSidebar(showingMode mode: RightSidebarMode? = nil) {
        if let mode = mode, isRightSidebarVisible, rightSidebarView.mode != mode {
            // Already open on the other tab — just switch tabs, don't collapse.
            rightSidebarView.setMode(mode)
            if mode == .git {
                rightSidebarView.gitPanelView.refresh(cwd: sidebarCurrentDirectory())
            }
            return
        }

        isRightSidebarVisible.toggle()

        if isRightSidebarVisible {
            if let mode = mode { rightSidebarView.setMode(mode) }

            if let contentView = window?.contentView {
                let leftEdge: CGFloat = isSidebarVisible ? sidebarWidth : 0
                let minTerminalWidth: CGFloat = 200
                let available = contentView.bounds.width - leftEdge - minTerminalWidth
                let clamped = rightSidebarWidth.clamped(
                    to: minRightSidebarWidth...max(minRightSidebarWidth, available))
                rightSidebarWidthConstraint.constant = clamped
                rightSidebarWidth = clamped
            }

            if rightSidebarView.mode == .git {
                rightSidebarView.gitPanelView.refresh(cwd: sidebarCurrentDirectory())
            }
        }

        let targetTrailing: CGFloat = isRightSidebarVisible ? 0 : rightSidebarWidth

        GhosttyTerminalView.deferSurfaceResize = true
        if Theme.useVibrancy { rightSidebarView.setGlassHidden(true) }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Theme.Animation.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)

                rightSidebarTrailingConstraint.animator().constant = targetTrailing
                window?.contentView?.layoutSubtreeIfNeeded()
            },
            completionHandler: {
                GhosttyTerminalView.deferSurfaceResize = false
                self.splitContainerView.needsLayout = true
                if Theme.useVibrancy { self.rightSidebarView.setGlassHidden(false) }
            })
    }

    // Back-compat shims so menu/palette actions keep working.
    func toggleEditorSidebar() { toggleRightSidebar(showingMode: .editor) }
    func toggleGitPanel() { toggleRightSidebar(showingMode: .git) }

    // MARK: - Sidebar toggle

    func toggleSidebar() {
        isSidebarVisible.toggle()

        let targetLeading: CGFloat = isSidebarVisible ? 0 : -sidebarWidth

        GhosttyTerminalView.deferSurfaceResize = true
        if Theme.useVibrancy { sidebarView.setGlassHidden(true) }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Theme.Animation.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)

                sidebarLeadingConstraint.animator().constant = targetLeading
                window?.contentView?.layoutSubtreeIfNeeded()
            },
            completionHandler: {
                GhosttyTerminalView.deferSurfaceResize = false
                self.splitContainerView.needsLayout = true
                if Theme.useVibrancy { self.sidebarView.setGlassHidden(false) }
                if self.isSidebarVisible {
                    self.sidebarView.reloadSessions()
                }
            })
    }

    // MARK: - Toolbar actions

    @objc private func toolbarToggleSidebar(_ sender: Any?) {
        toggleSidebar()
    }

    @objc private func toolbarToggleEditorSidebar(_ sender: Any?) {
        toggleRightSidebar()
    }

    @objc private func toolbarToggleGitPanel(_ sender: Any?) {
        toggleRightSidebar(showingMode: .git)
    }

    @objc private func toolbarNewSession(_ sender: Any?) {
        let session = sessionManager.createSession(projectID: projectManager.activeProject?.id)
        displaySession(session)
        if isSidebarVisible { sidebarView.reloadSessions() }
    }

    @objc private func toolbarSplitVertical(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        if session.splitFocusedPane(direction: .vertical) != nil {
            displaySession(session)
        }
    }

    @objc private func toolbarSplitHorizontal(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        if session.splitFocusedPane(direction: .horizontal) != nil {
            displaySession(session)
        }
    }

    // MARK: - Status polling

    private func pollSessionStatuses() {
        // Feed shell PIDs to agent manager each poll cycle
        splitContainerView.updateAgentManagerMappings()

        // Update global status bar from focused pane using Ghostty-provided CWD
        if let activeSession = sessionManager.activeSession,
            let focusedID = activeSession.focusedPaneID,
            let pane = splitContainerView.pane(for: focusedID)
        {
            globalStatusBar.updateFromPane(
                cwd: pane.currentDirectory,
                shellPid: pane.shellProcessID
            )
        }

        var needsReload = false
        for session in sessionManager.sessions {
            // Try focusedPaneID first, fall back to any pane in the split tree
            let candidateIDs: [UUID]
            if let focusedID = session.focusedPaneID {
                candidateIDs =
                    [focusedID] + session.splitTree.allPaneIDs().filter { $0 != focusedID }
            } else {
                candidateIDs = session.splitTree.allPaneIDs()
            }

            // Find a pane with a status file
            var statusPath: String?
            for id in candidateIDs {
                guard let scv = splitContainerView,
                    let pane = scv.paneIncludingCache(for: id),
                    let path = pane.statusFilePath
                else { continue }
                statusPath = path
                break
            }

            guard let statusPath = statusPath else { continue }

            let fileStatus =
                (try? String(contentsOfFile: statusPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if fileStatus == "running"
                && session.paneStatus != .running
                && session.paneStatus != .success
                && session.paneStatus != .error
            {
                session.paneStatus = .running
                needsReload = true
            } else if fileStatus != "running" && session.paneStatus != .idle {
                session.paneStatus = .idle
                needsReload = true
            }
        }
        if needsReload && isSidebarVisible {
            sidebarView.reloadSessions()
        }
    }

    // MARK: - File tree

    func updateSidebarFileTree(path: String?) {
        guard isSidebarVisible else { return }
        sidebarView.updateFileTreePath(path)
    }

    func updateSidebarGitViews(cwd: String?) {
        if isGitPanelVisible {
            gitPanelView.refresh(cwd: cwd)
        }
    }

    // MARK: - Session display

    func displaySession(_ session: Session) {
        splitContainerView.setSplitTree(session.splitTree, forSessionID: session.id)
        splitContainerView.focusedPaneID = session.focusedPaneID

        if let focusedID = session.focusedPaneID {
            DispatchQueue.main.async { [weak self] in
                self?.splitContainerView.focusPane(focusedID)
            }
        }

        if isSidebarVisible {
            sidebarView.reloadSessions()
        }

        rebindRunnerWorktree()
    }

    // MARK: - Runner worktree binding

    /// Resolve the currently-focused pane's working directory, normalized to
    /// the enclosing repo root when the cwd is inside a git worktree. Uses
    /// `queryShellCwd()` so we pick up live `cd` changes — same path the Git
    /// panel uses. Returns nil only when there is no active session or pane.
    private func activeWorktreePath() -> String? {
        guard let session = sessionManager.activeSession,
            let focusedID = session.focusedPaneID,
            let pane = splitContainerView.pane(for: focusedID)
        else { return nil }
        let cwd = pane.queryShellCwd()
        return GitHelper.repoRoot(from: cwd) ?? cwd
    }

    /// Rebind the runner panel to whatever worktree the focused pane is in.
    /// Safe to call before setupViews finishes — no-ops until the view exists.
    func rebindRunnerWorktree() {
        guard runnerPanelView != nil else { return }
        runnerPanelView.setWorktree(activeWorktreePath())
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    private func makeToolbarButton(
        symbolName: String, accessibilityDescription: String, action: Selector
    ) -> ToolbarIconButton {
        let button = ToolbarIconButton()
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        button.target = self
        button.action = action
        button.setFrameSize(NSSize(width: 30, height: 24))
        button.refreshDimState()
        toolbarButtons.append(button)
        return button
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarToggle:
            let item = NSToolbarItem(itemIdentifier: .sidebarToggle)
            item.view = makeToolbarButton(
                symbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar",
                action: #selector(toolbarToggleSidebar(_:)))
            item.isBordered = false
            item.label = "Sidebar"
            return item

        case .actions:
            let item = NSToolbarItem(itemIdentifier: .actions)
            item.isBordered = false

            let editorDropdown = EditorDropdownButton()
            editorDropdown.onOpenFile = { [weak self] bundleID in
                guard let self,
                    let activeSession = self.sessionManager.activeSession,
                    let focusedID = activeSession.focusedPaneID,
                    let pane = self.splitContainerView.pane(for: focusedID),
                    let cwd = pane.currentDirectory
                else { return }
                ExternalEditorHelper.openIn(filePath: cwd, bundleID: bundleID)
            }
            editorDropdown.heightAnchor.constraint(equalToConstant: 22).isActive = true
            toolbarEditorDropdown = editorDropdown

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.addArrangedSubview(editorDropdown)
            stack.addArrangedSubview(
                makeToolbarButton(
                    symbolName: "rectangle.split.1x2", accessibilityDescription: "Split Horizontal",
                    action: #selector(toolbarSplitHorizontal(_:))))
            stack.addArrangedSubview(
                makeToolbarButton(
                    symbolName: "rectangle.split.2x1", accessibilityDescription: "Split Vertical",
                    action: #selector(toolbarSplitVertical(_:))))
            stack.addArrangedSubview(
                makeToolbarButton(
                    symbolName: "plus", accessibilityDescription: "New Session",
                    action: #selector(toolbarNewSession(_:))))
            stack.addArrangedSubview(
                makeToolbarButton(
                    symbolName: "sidebar.right", accessibilityDescription: "Toggle Right Sidebar",
                    action: #selector(toolbarToggleEditorSidebar(_:))))
            item.view = stack
            item.label = "Actions"
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .sidebarToggle,
            .flexSpace,
            .actions,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .sidebarToggle,
            .flexSpace,
            .actions,
        ]
    }
}

// MARK: - SidebarViewDelegate

extension MainWindowController: SidebarViewDelegate {
    // MARK: - Projects

    func sidebarDidSelectProject(_ project: Project) {
        projectManager.selectProject(id: project.id)
        sidebarView.reloadProjects()

        // Stamp the project root on the container so all future tabs/panes auto-cd
        splitContainerView.projectRootPath = project.rootPath

        // Find existing sessions for this project
        let projectSessions = sessionManager.sessions(for: project.id)

        if let existing = projectSessions.last ?? projectSessions.first {
            // Switch to the last session of this project
            sessionManager.switchToSession(id: existing.id)
            displaySession(existing)
        } else {
            // No sessions yet — create the first one
            let session = sessionManager.createSession(
                name: project.displayName, projectID: project.id)
            displaySession(session)
        }
        sidebarView.reloadSessions()
    }

    func sidebarDidRequestAddProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "Choose a folder to open as a project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            let path = url.path

            // Avoid duplicate projects for the same root path
            if self.projectManager.hasProject(withRootPath: path) {
                // Just select the existing one
                if let existing = self.projectManager.projects.first(where: { $0.rootPath == path })
                {
                    self.sidebarDidSelectProject(existing)
                }
                return
            }

            let folderName = url.lastPathComponent
            let project = self.projectManager.addProject(rootPath: path, name: folderName)
            self.sidebarView.reloadProjects()

            // Auto-select the new project
            self.sidebarDidSelectProject(project)
        }
    }

    func sidebarDidRequestDeleteProject(_ project: Project) {
        let wasActive = (projectManager.activeProject?.id == project.id)
        // Remove all sessions for this project
        let projectSessions = sessionManager.sessions(for: project.id)
        for session in projectSessions {
            let paneIDs = session.splitTree.allPaneIDs()
            for paneID in paneIDs { splitContainerView.removePane(id: paneID) }
            splitContainerView.clearCachedPanes(forSessionID: session.id)
            sessionManager.deleteSession(id: session.id)
        }
        projectManager.deleteProject(id: project.id)
        sidebarView.reloadProjects()
        if wasActive {
            splitContainerView.projectRootPath = nil
            // Switch to whatever session is now active
            if let active = sessionManager.activeSession {
                displaySession(active)
            } else {
                // No sessions at all — make one unscoped session
                let s = sessionManager.createSession()
                displaySession(s)
            }
            sidebarView.reloadSessions()
        }
    }

    func sidebarDidRequestRenameProject(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        alert.informativeText = "Enter a new name for \"\(project.displayName)\"."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = project.displayName
        inputField.isEditable = true
        inputField.isSelectable = true
        inputField.placeholderString = "Project name"
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = inputField.stringValue.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                self?.projectManager.renameProject(id: project.id, name: newName)
                self?.sidebarView.reloadProjects()
            }
        }
    }

    func sidebarDidRequestOpenProjectFolder(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.rootPath))
    }

    func sidebarDidSelectSession(_ session: Session) {
        sessionManager.switchToSession(id: session.id)
        displaySession(session)
    }

    func sidebarDidRequestNewSession() {
        let session = sessionManager.createSession(projectID: projectManager.activeProject?.id)
        displaySession(session)
        sidebarView.reloadSessions()
    }

    func sidebarDidRequestDeleteSession(_ session: Session) {
        guard sessionManager.sessions.count > 1 else { return }

        let paneIDs = session.splitTree.allPaneIDs()
        for paneID in paneIDs {
            splitContainerView.removePane(id: paneID)
        }
        splitContainerView.clearCachedPanes(forSessionID: session.id)

        sessionManager.deleteSession(id: session.id)
        sidebarView.reloadSessions()

        if let activeSession = sessionManager.activeSession {
            displaySession(activeSession)
        }
    }

    func sidebarCurrentDirectory() -> String? {
        guard let activeID = sessionManager.activeSession?.focusedPaneID,
            let pane = splitContainerView.pane(for: activeID)
        else { return nil }
        return pane.queryShellCwd()
    }

    private func openWorktreeAsNewSession(path: String) {
        let url = URL(fileURLWithPath: path)
        let folderName = url.lastPathComponent

        // If a project already exists for this path, just switch to it
        if projectManager.hasProject(withRootPath: path),
            let existing = projectManager.projects.first(where: { $0.rootPath == path })
        {
            sidebarDidSelectProject(existing)
            return
        }

        // Otherwise add it as a new project and select it — same flow as the + button
        let project = projectManager.addProject(rootPath: path, name: folderName)
        sidebarView.reloadProjects()
        sidebarDidSelectProject(project)
    }

    func sidebarDidSelectFile(path: String) {
        if !isEditorSidebarVisible {
            toggleEditorSidebar()
        }
        editorSidebarView.openFile(at: path)
    }

    func sidebarDidRequestFocusAgentPane(paneID: UUID, tabID: UUID?, sessionID: UUID) {
        if let idx = sessionManager.sessions.firstIndex(where: { $0.id == sessionID }) {
            sessionManager.activeSessionIndex = idx
            let session = sessionManager.sessions[idx]
            displaySession(session)
            session.focusedPaneID = paneID
            if let pane = splitContainerView.pane(for: paneID) {
                if let tabID = tabID {
                    pane.switchToTab(tabID)
                }
                pane.focus()
            }
            sidebarView.reloadSessions()
            // Focused pane id changed after displaySession; re-bind runner
            // to pick up the new pane's worktree.
            rebindRunnerWorktree()
        }
    }

    func sidebarDidRequestSendInterrupt(agent: AgentInstance) {
        agentManager.sendInterrupt(to: agent)
    }

    func sidebarDidRequestKillAgent(agent: AgentInstance) {
        agentManager.killAgent(agent)
    }

    func sidebarDidRequestRenameSession(_ session: Session) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name for this session."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = session.name
        inputField.isEditable = true
        inputField.isSelectable = true
        inputField.placeholderString = "Session name"
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = inputField.stringValue.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                session.name = newName
                self?.sidebarView.reloadSessions()
            }
        }
    }

    // MARK: - Project helpers

    /// cd the focused pane of a session into the given project root path.
    func cdSessionToProjectRoot(_ session: Session, projectPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                let focusedID = session.focusedPaneID,
                let pane = self.splitContainerView.pane(for: focusedID),
                let tv = pane.terminalView,
                let surface = tv.surface
            else { return }
            let cmd = "cd \"\(projectPath)\"\r"
            cmd.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(cmd.utf8.count))
            }
        }
    }
}

// MARK: - GitPanelViewDelegate

extension MainWindowController: GitPanelViewDelegate {
    func gitPanelDidRequestOpenWorktree(path: String) {
        openWorktreeAsNewSession(path: path)
    }

    func gitPanelDidRequestOpenDiff(filePath: String, staged: Bool, repoRoot: String) {
        // Open the diff as a tab on the currently focused pane so it lives
        // alongside terminals and uses the same tab bar + shortcuts.
        guard let session = sessionManager.activeSession,
            let focusedID = session.focusedPaneID,
            let pane = splitContainerView.pane(for: focusedID)
        else { return }
        pane.addDiffTab(filePath: filePath, staged: staged, repoRoot: repoRoot)
    }

    func gitPanelDidRequestOpenCommit(hash: String, repoRoot: String) {
        guard let session = sessionManager.activeSession,
            let focusedID = session.focusedPaneID,
            let pane = splitContainerView.pane(for: focusedID)
        else { return }
        pane.addCommitDetailTab(hash: hash, repoRoot: repoRoot)
    }
}

// MARK: - RightSidebarViewDelegate

extension MainWindowController: RightSidebarViewDelegate {
    func rightSidebarDidRequestCollapse() {
        toggleRightSidebar()
    }
}

// MARK: - EditorSidebarViewDelegate

extension MainWindowController: EditorSidebarViewDelegate {
    func editorSidebarDidToggle(visible: Bool) {}

    func editorSidebarDidRequestToggleExpand() {
        guard let contentView = window?.contentView else { return }
        isEditorExpanded.toggle()
        editorSidebarView.setExpanded(isEditorExpanded)

        let targetWidth: CGFloat
        if isEditorExpanded {
            rightSidebarWidthBeforeExpand = rightSidebarWidth
            let leftEdge = isSidebarVisible ? sidebarWidth : 0
            let available = contentView.bounds.width - leftEdge
            // Use 60% of available space, leave room for the terminal
            targetWidth = min(available * 0.6, available - 200)
        } else {
            targetWidth = rightSidebarWidthBeforeExpand
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Animation.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            rightSidebarWidthConstraint.animator().constant = targetWidth
            rightSidebarWidth = targetWidth
            contentView.layoutSubtreeIfNeeded()
        }
    }
}

// MARK: - RunnerPanelViewDelegate

extension MainWindowController: RunnerPanelViewDelegate {
    /// Promote a running runner task into a full Ghostty pane so the user gets
    /// a real TUI / color / shell integration for dev servers, debuggers, etc.
    ///
    /// Flow:
    /// 1. Split the currently-focused pane vertically so the new pane gets
    ///    focus and lives next to where the user was working.
    /// 2. Register the command as pending initial input for the new paneID so
    ///    the `TerminalPane`/`GhosttyTerminalView` typing machinery feeds it
    ///    to the shell after the prompt has drawn (`GhosttyTerminalView`
    ///    defers the first PTY write ~0.3s to let the prompt paint first).
    /// 3. Refresh the session so `SplitContainerView.createPane` runs and
    ///    picks up the pending input.
    ///
    /// `RunnerPanelView.promoteClicked` is responsible for writing a
    /// breadcrumb into the log buffer and calling `runner.stop(...)` BEFORE
    /// invoking this delegate method, so the inline session is gone by the
    /// time the pane starts.
    func runnerPanelDidRequestOpenInPane(command: String, cwd: String) {
        guard let session = sessionManager.activeSession else { return }
        guard let newPaneID = session.splitFocusedPane(direction: .vertical) else { return }

        // Single PTY write: cd first so we land in the right dir even if the
        // shell spawned elsewhere, then run the user's command. Quote cwd to
        // handle spaces; backslash-escape embedded double quotes.
        let escapedCwd = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        let line = "cd \"\(escapedCwd)\" && \(command)\n"
        splitContainerView.registerInitialInput(line, for: newPaneID)

        displaySession(session)
        splitContainerView.focusPane(newPaneID)
    }
}

// MARK: - ContainerPanelViewDelegate

extension MainWindowController: ContainerPanelViewDelegate {
    func containerPanelDidRequestOpenContainer(id: String) {
        guard let session = sessionManager.activeSession,
            let focusedID = session.focusedPaneID,
            let pane = splitContainerView.pane(for: focusedID)
        else { return }
        pane.addContainerTab(id: id)
    }
}

// MARK: - Sidebar resize handle

private class SidebarResizeHandle: NSView {
    var onResize: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.x - dragStartX
        dragStartX = event.locationInWindow.x
        onResize?(delta)
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
