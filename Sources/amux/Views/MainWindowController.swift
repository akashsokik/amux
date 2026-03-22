import AppKit
import CGhostty

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("sidebarToggle")
    static let flexSpace = NSToolbarItem.Identifier.flexibleSpace
    static let actions = NSToolbarItem.Identifier("actions")
}

class MainWindowController: NSWindowController {
    private(set) var sidebarView: SidebarView!
    private(set) var splitContainerView: SplitContainerView!
    private(set) var globalStatusBar: PaneStatusBar!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarLeadingConstraint: NSLayoutConstraint!
    private var resizeHandle: SidebarResizeHandle!

    private let sessionManager: SessionManager
    private var toolbarButtons: [NSButton] = []
    private var statusPollTimer: Timer?

    private(set) var isSidebarVisible = true
    private var sidebarWidth: CGFloat = 220
    private let minSidebarWidth: CGFloat = 150
    private let maxSidebarWidth: CGFloat = 400

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager

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
        window?.backgroundColor = Theme.background
        window?.contentView?.layer?.backgroundColor = Theme.background.cgColor
        for button in toolbarButtons {
            button.contentTintColor = Theme.secondaryText
        }
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
        window.appearance = NSAppearance(named: .darkAqua)
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

        sidebarView = SidebarView(sessionManager: sessionManager)
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.delegate = self
        contentView.addSubview(sidebarView)

        splitContainerView = SplitContainerView(frame: .zero)
        splitContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitContainerView)

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

        sidebarLeadingConstraint = sidebarView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: 0
        )
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(equalToConstant: sidebarWidth)

        NSLayoutConstraint.activate([
            sidebarLeadingConstraint,
            sidebarWidthConstraint,
            sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            resizeHandle.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -2),
            resizeHandle.topAnchor.constraint(equalTo: contentView.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 5),

            globalStatusBar.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            globalStatusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            globalStatusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            globalStatusBar.heightAnchor.constraint(equalToConstant: PaneStatusBar.barHeight),

            splitContainerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            splitContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitContainerView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            splitContainerView.bottomAnchor.constraint(equalTo: globalStatusBar.topAnchor),
        ])
    }

    // MARK: - Sidebar resize

    private func resizeSidebar(by delta: CGFloat) {
        let newWidth = (sidebarWidthConstraint.constant + delta)
            .clamped(to: minSidebarWidth...maxSidebarWidth)
        sidebarWidthConstraint.constant = newWidth
        sidebarWidth = newWidth
    }

    // MARK: - Sidebar toggle

    func toggleSidebar() {
        isSidebarVisible.toggle()

        let targetLeading: CGFloat = isSidebarVisible ? 0 : -sidebarWidth

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Animation.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true

            sidebarLeadingConstraint.animator().constant = targetLeading
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            if self.isSidebarVisible {
                self.sidebarView.reloadSessions()
            }
        })
    }

    // MARK: - Toolbar actions

    @objc private func toolbarToggleSidebar(_ sender: Any?) {
        toggleSidebar()
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
        // Update global status bar with focused pane's shell PID
        if let activeSession = sessionManager.activeSession,
           let focusedID = activeSession.focusedPaneID,
           let pane = splitContainerView.pane(for: focusedID) {
            if pane.shellProcessID == nil {
                pane.retryShellPidDiscovery()
            }
            globalStatusBar.setShellPid(pane.shellProcessID)
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
    private func makeToolbarButton(symbolName: String, accessibilityDescription: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.contentTintColor = Theme.secondaryText
        button.setFrameSize(NSSize(width: 30, height: 24))
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

        case .actions:
            let item = NSToolbarItem(itemIdentifier: .actions)
            item.isBordered = false
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 10
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

