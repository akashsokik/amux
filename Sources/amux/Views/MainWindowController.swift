import AppKit
import CGhostty

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("sidebarToggle")
    static let flexSpace = NSToolbarItem.Identifier.flexibleSpace
    static let editorToggle = NSToolbarItem.Identifier("editorToggle")
    static let actions = NSToolbarItem.Identifier("actions")
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

    // Editor sidebar (right side, mirrors left sidebar pattern)
    private(set) var editorSidebarView: EditorSidebarView!
    private var editorSidebarWidthConstraint: NSLayoutConstraint!
    private var editorSidebarTrailingConstraint: NSLayoutConstraint!
    private var editorResizeHandle: SidebarResizeHandle!

    private(set) var isEditorSidebarVisible = false
    private(set) var isEditorExpanded = false
    private var editorSidebarWidth: CGFloat = 420
    private var editorSidebarWidthBeforeExpand: CGFloat = 420
    private let minEditorSidebarWidth: CGFloat = 250
    private let maxEditorSidebarWidth: CGFloat = 500

    private let sessionManager: SessionManager
    private(set) var agentManager: AgentManager
    private var toolbarButtons: [ToolbarIconButton] = []
    private var toolbarEditorDropdown: EditorDropdownButton?
    private var statusPollTimer: Timer?

    private(set) var isSidebarVisible = true
    private var sidebarWidth: CGFloat = 220
    private let minSidebarWidth: CGFloat = 150
    private let maxSidebarWidth: CGFloat = 400

    init(sessionManager: SessionManager, agentManager: AgentManager) {
        self.sessionManager = sessionManager
        self.agentManager = agentManager

        let window = MainWindowController.createWindow()
        super.init(window: window)

        setupToolbar()
        setupViews()

        if let activeSession = sessionManager.activeSession {
            displaySession(activeSession)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )

        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollSessionStatuses()
        }
    }

    deinit {
        statusPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        window?.appearance = NSAppearance(named: ThemeManager.shared.current.isLight ? .aqua : .darkAqua)
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
        window.appearance = NSAppearance(named: ThemeManager.shared.current.isLight ? .aqua : .darkAqua)
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

        sidebarView = SidebarView(sessionManager: sessionManager, agentManager: agentManager)
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

        editorSidebarView = EditorSidebarView(frame: .zero)
        editorSidebarView.translatesAutoresizingMaskIntoConstraints = false
        editorSidebarView.delegate = self
        contentView.addSubview(editorSidebarView)

        editorResizeHandle = SidebarResizeHandle()
        editorResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        editorResizeHandle.onResize = { [weak self] delta in
            self?.resizeEditorSidebar(by: -delta)
        }
        contentView.addSubview(editorResizeHandle)

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

        // Right editor sidebar constraints (trailing edge, slides right to hide)
        editorSidebarTrailingConstraint = editorSidebarView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: editorSidebarWidth
        )
        editorSidebarWidthConstraint = editorSidebarView.widthAnchor.constraint(equalToConstant: editorSidebarWidth)
        // Allow the width to yield to window size rather than forcing the window to grow
        editorSidebarWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Left sidebar
            sidebarLeadingConstraint,
            sidebarWidthConstraint,
            sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Left resize handle
            resizeHandle.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -2),
            resizeHandle.topAnchor.constraint(equalTo: contentView.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 5),

            // Right editor sidebar
            editorSidebarTrailingConstraint,
            editorSidebarWidthConstraint,
            editorSidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            editorSidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Right resize handle
            editorResizeHandle.trailingAnchor.constraint(equalTo: editorSidebarView.leadingAnchor, constant: 2),
            editorResizeHandle.topAnchor.constraint(equalTo: contentView.topAnchor),
            editorResizeHandle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            editorResizeHandle.widthAnchor.constraint(equalToConstant: 5),

            // Titlebar glass: spans the toolbar strip above the split container
            tbGlass.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            tbGlass.trailingAnchor.constraint(equalTo: editorSidebarView.leadingAnchor),
            tbGlass.topAnchor.constraint(equalTo: contentView.topAnchor),
            tbGlass.bottomAnchor.constraint(equalTo: layoutGuide.topAnchor),

            // Split container: between the two sidebars
            splitContainerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            splitContainerView.trailingAnchor.constraint(equalTo: editorSidebarView.leadingAnchor),
            splitContainerView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            splitContainerView.bottomAnchor.constraint(equalTo: globalStatusBar.topAnchor),

            // Status bar: between the two sidebars
            globalStatusBar.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            globalStatusBar.trailingAnchor.constraint(equalTo: editorSidebarView.leadingAnchor),
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

    // MARK: - Editor sidebar resize

    private func resizeEditorSidebar(by delta: CGFloat) {
        let newWidth = (editorSidebarWidthConstraint.constant + delta)
            .clamped(to: minEditorSidebarWidth...maxEditorSidebarWidth)
        editorSidebarWidthConstraint.constant = newWidth
        editorSidebarWidth = newWidth
    }

    // MARK: - Editor sidebar toggle (mirrors left sidebar pattern)

    func toggleEditorSidebar() {
        isEditorSidebarVisible.toggle()

        // Clamp width so the sidebar never overflows the window
        if isEditorSidebarVisible, let contentView = window?.contentView {
            let leftEdge: CGFloat = isSidebarVisible ? sidebarWidth : 0
            let minTerminalWidth: CGFloat = 200
            let available = contentView.bounds.width - leftEdge - minTerminalWidth
            let clamped = editorSidebarWidth.clamped(to: minEditorSidebarWidth...max(minEditorSidebarWidth, available))
            editorSidebarWidthConstraint.constant = clamped
            editorSidebarWidth = clamped
        }

        // Mirror of left sidebar: 0 = visible, +editorSidebarWidth = off-screen right
        let targetTrailing: CGFloat = isEditorSidebarVisible ? 0 : editorSidebarWidth

        GhosttyTerminalView.deferSurfaceResize = true
        if Theme.useVibrancy { editorSidebarView.setGlassHidden(true) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Animation.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)

            editorSidebarTrailingConstraint.animator().constant = targetTrailing
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            GhosttyTerminalView.deferSurfaceResize = false
            self.splitContainerView.needsLayout = true
            if Theme.useVibrancy { self.editorSidebarView.setGlassHidden(false) }
        })
    }

    // MARK: - Sidebar toggle

    func toggleSidebar() {
        isSidebarVisible.toggle()

        let targetLeading: CGFloat = isSidebarVisible ? 0 : -sidebarWidth

        GhosttyTerminalView.deferSurfaceResize = true
        if Theme.useVibrancy { sidebarView.setGlassHidden(true) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Animation.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)

            sidebarLeadingConstraint.animator().constant = targetLeading
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: {
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
        toggleEditorSidebar()
    }

    @objc private func toolbarNewSession(_ sender: Any?) {
        let session = sessionManager.createSession()
        displaySession(session)
        if isSidebarVisible {
            sidebarView.reloadSessions()
        }
    }

    @objc private func toolbarSplitVertical(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        if let _ = session.splitFocusedPane(direction: .vertical) {
            displaySession(session)
        }
    }

    @objc private func toolbarSplitHorizontal(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        if let _ = session.splitFocusedPane(direction: .horizontal) {
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
           let pane = splitContainerView.pane(for: focusedID) {
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
                candidateIDs = [focusedID] + session.splitTree.allPaneIDs().filter { $0 != focusedID }
            } else {
                candidateIDs = session.splitTree.allPaneIDs()
            }

            // Find a pane with a status file
            var statusPath: String?
            for id in candidateIDs {
                guard let scv = splitContainerView,
                      let pane = scv.paneIncludingCache(for: id),
                      let path = pane.statusFilePath else { continue }
                statusPath = path
                break
            }

            guard let statusPath = statusPath else { continue }

            let fileStatus = (try? String(contentsOfFile: statusPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if fileStatus == "running"
                && session.paneStatus != .running
                && session.paneStatus != .success
                && session.paneStatus != .error {
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
        guard isSidebarVisible else { return }
        sidebarView.updateGitViews(cwd: cwd)
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
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    private func makeToolbarButton(symbolName: String, accessibilityDescription: String, action: Selector) -> ToolbarIconButton {
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

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarToggle:
            let item = NSToolbarItem(itemIdentifier: .sidebarToggle)
            item.view = makeToolbarButton(symbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar", action: #selector(toolbarToggleSidebar(_:)))
            item.isBordered = false
            item.label = "Sidebar"
            return item

        case .editorToggle:
            let item = NSToolbarItem(itemIdentifier: .editorToggle)
            item.view = makeToolbarButton(symbolName: "sidebar.right", accessibilityDescription: "Toggle Editor Sidebar", action: #selector(toolbarToggleEditorSidebar(_:)))
            item.isBordered = false
            item.label = "Editor"
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
                      let cwd = pane.currentDirectory else { return }
                ExternalEditorHelper.openIn(filePath: cwd, bundleID: bundleID)
            }
            editorDropdown.heightAnchor.constraint(equalToConstant: 22).isActive = true
            toolbarEditorDropdown = editorDropdown

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.addArrangedSubview(editorDropdown)
            stack.addArrangedSubview(makeToolbarButton(symbolName: "rectangle.split.1x2", accessibilityDescription: "Split Horizontal", action: #selector(toolbarSplitHorizontal(_:))))
            stack.addArrangedSubview(makeToolbarButton(symbolName: "rectangle.split.2x1", accessibilityDescription: "Split Vertical", action: #selector(toolbarSplitVertical(_:))))
            stack.addArrangedSubview(makeToolbarButton(symbolName: "plus", accessibilityDescription: "New Session", action: #selector(toolbarNewSession(_:))))
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
            .editorToggle,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .sidebarToggle,
            .flexSpace,
            .actions,
            .editorToggle,
        ]
    }
}

// MARK: - SidebarViewDelegate

extension MainWindowController: SidebarViewDelegate {
    func sidebarDidSelectSession(_ session: Session) {
        sessionManager.switchToSession(id: session.id)
        displaySession(session)
    }

    func sidebarDidRequestNewSession() {
        let session = sessionManager.createSession()
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
              let pane = splitContainerView.pane(for: activeID) else { return nil }
        return pane.queryShellCwd()
    }

    func sidebarDidRequestOpenWorktree(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let session = sessionManager.createSession(name: name)
        displaySession(session)
        sidebarView.reloadSessions()
        // cd into the worktree after the shell spawns
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                  let focusedID = session.focusedPaneID,
                  let pane = self.splitContainerView.pane(for: focusedID),
                  let tv = pane.terminalView,
                  let surface = tv.surface else { return }
            let cmd = "cd \"\(path)\"\r"
            cmd.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(cmd.utf8.count))
            }
        }
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
            editorSidebarWidthBeforeExpand = editorSidebarWidth
            let leftEdge = isSidebarVisible ? sidebarWidth : 0
            let available = contentView.bounds.width - leftEdge
            // Use 60% of available space, leave room for the terminal
            targetWidth = min(available * 0.6, available - 200)
        } else {
            targetWidth = editorSidebarWidthBeforeExpand
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Animation.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            editorSidebarWidthConstraint.animator().constant = targetWidth
            editorSidebarWidth = targetWidth
            contentView.layoutSubtreeIfNeeded()
        }
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
