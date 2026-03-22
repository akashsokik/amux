import AppKit
import CGhostty

class AppDelegate: NSObject, NSApplicationDelegate {
    private var sessionManager: SessionManager!
    private var windowController: MainWindowController!
    private(set) var ghosttyApp: GhosttyApp?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        // Initialize ThemeManager before GhosttyApp so colors are ready
        _ = ThemeManager.shared

        // Set Ghostty resources dir BEFORE init so shell integration loads for all shells
        setupGhosttyResourcesDir()
        setupAmuxShellIntegration()

        // Initialize the Ghostty library first
        let app = GhosttyApp()
        if !app.isReady {
            print("[AppDelegate] FATAL: Failed to initialize Ghostty library")
            NSApp.terminate(nil)
            return
        }
        app.delegate = self
        self.ghosttyApp = app

        sessionManager = SessionManager.restore() ?? SessionManager()
        windowController = MainWindowController(sessionManager: sessionManager)
        windowController.splitContainerView.containerDelegate = self

        setupMenuBar()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)

        // Activate the app and bring to front
        NSApp.activate(ignoringOtherApps: true)

        if let session = sessionManager.activeSession {
            windowController.displaySession(session)
        }

        // Focus the first terminal pane after a brief delay for layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self,
                  let session = self.sessionManager.activeSession,
                  let focusedID = session.focusedPaneID,
                  let pane = self.windowController.splitContainerView.pane(for: focusedID) else { return }
            pane.focus()
        }
    }

    /// Set GHOSTTY_RESOURCES_DIR so the Ghostty library can find shell integration
    /// scripts for bash, zsh, fish, etc. Without this, OSC 7 (CWD reporting) and
    /// OSC 133 (prompt marking) won't work in any shell.
    private func setupGhosttyResourcesDir() {
        // Don't override if already set (e.g. user has Ghostty installed)
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] != nil { return }

        // Try app bundle Resources/ghostty (production .app bundle)
        if let resourcePath = Bundle.main.resourcePath {
            let ghosttyDir = (resourcePath as NSString).appendingPathComponent("ghostty")
            let shellIntegDir = (ghosttyDir as NSString).appendingPathComponent("shell-integration")
            if FileManager.default.fileExists(atPath: shellIntegDir) {
                setenv("GHOSTTY_RESOURCES_DIR", ghosttyDir, 1)
                return
            }
        }

        // Fallback: try executable-relative paths (for SPM dev builds)
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidates = [
                execURL.appendingPathComponent("../Resources/ghostty").path,
                execURL.deletingLastPathComponent()
                    .appendingPathComponent("Resources/ghostty").path,
            ]
            for path in candidates {
                let shellIntegDir = (path as NSString).appendingPathComponent("shell-integration")
                if FileManager.default.fileExists(atPath: shellIntegDir) {
                    setenv("GHOSTTY_RESOURCES_DIR", path, 1)
                    return
                }
            }
        }
    }

    /// Set environment variables so amux shell integration scripts are loaded
    /// automatically by bash, zsh, and fish when a new terminal surface spawns.
    private func setupAmuxShellIntegration() {
        // Locate the shell-integration directory
        var shellIntegDir: String?

        // Try app bundle Resources/shell-integration (production .app bundle)
        if let resourcePath = Bundle.main.resourcePath {
            let candidate = (resourcePath as NSString).appendingPathComponent("shell-integration")
            if FileManager.default.fileExists(atPath: candidate) {
                shellIntegDir = candidate
            }
        }

        // Fallback: try executable-relative paths (for SPM dev builds)
        if shellIntegDir == nil, let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidates = [
                execURL.appendingPathComponent("../Resources/shell-integration").path,
                execURL.deletingLastPathComponent()
                    .appendingPathComponent("Resources/shell-integration").path,
            ]
            for path in candidates {
                if FileManager.default.fileExists(atPath: path) {
                    shellIntegDir = path
                    break
                }
            }
        }

        guard let shellIntegDir = shellIntegDir else {
            print("[AppDelegate] Warning: could not find amux shell-integration directory")
            return
        }

        // Fish: auto-loads from XDG_DATA_DIRS. The fish scripts live at
        // shell-integration/fish/vendor_conf.d/amux.fish, and fish looks for
        // <dir>/fish/vendor_conf.d/*.fish in each XDG_DATA_DIRS entry.
        // Append our shell-integration dir to XDG_DATA_DIRS.
        let currentXDG = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"] ?? ""
        if !currentXDG.contains(shellIntegDir) {
            if currentXDG.isEmpty {
                setenv("XDG_DATA_DIRS", shellIntegDir, 1)
            } else {
                setenv("XDG_DATA_DIRS", "\(currentXDG):\(shellIntegDir)", 1)
            }
        }

        // Bash: source via BASH_ENV (only if not already set)
        let bashScript = (shellIntegDir as NSString).appendingPathComponent("amux.bash")
        if ProcessInfo.processInfo.environment["BASH_ENV"] == nil,
           FileManager.default.fileExists(atPath: bashScript) {
            setenv("BASH_ENV", bashScript, 1)
        }

        // Zsh: set AMUX_ZSH_SCRIPT so our .zshenv / .zshrc integration can source it
        let zshScript = (shellIntegDir as NSString).appendingPathComponent("amux.zsh")
        if FileManager.default.fileExists(atPath: zshScript) {
            setenv("AMUX_ZSH_SCRIPT", zshScript, 1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager.save()

        // Clean up per-pane status files
        let statusDir = "/tmp/amux-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: statusDir)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About amux", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit amux", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Session menu
        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")

        let newSessionItem = NSMenuItem(title: "New Session", action: #selector(newSession(_:)), keyEquivalent: "T")
        newSessionItem.keyEquivalentModifierMask = [.command, .shift]
        newSessionItem.target = self
        sessionMenu.addItem(newSessionItem)

        let closeSessionItem = NSMenuItem(title: "Close Session", action: #selector(closeSession(_:)), keyEquivalent: "W")
        closeSessionItem.keyEquivalentModifierMask = [.command, .shift]
        closeSessionItem.target = self
        sessionMenu.addItem(closeSessionItem)

        let renameSessionItem = NSMenuItem(title: "Rename Session", action: #selector(renameSession(_:)), keyEquivalent: "N")
        renameSessionItem.keyEquivalentModifierMask = [.command, .shift]
        renameSessionItem.target = self
        sessionMenu.addItem(renameSessionItem)

        sessionMenu.addItem(NSMenuItem.separator())

        let nextSessionItem = NSMenuItem(title: "Next Session", action: #selector(nextSession(_:)), keyEquivalent: "")
        nextSessionItem.target = self
        sessionMenu.addItem(nextSessionItem)

        let prevSessionItem = NSMenuItem(title: "Previous Session", action: #selector(previousSession(_:)), keyEquivalent: "")
        prevSessionItem.target = self
        sessionMenu.addItem(prevSessionItem)

        sessionMenu.addItem(NSMenuItem.separator())

        for i in 1...9 {
            let item = NSMenuItem(
                title: "Session \(i)",
                action: #selector(switchToSessionByNumber(_:)),
                keyEquivalent: "\(i)"
            )
            item.tag = i
            item.target = self
            sessionMenu.addItem(item)
        }

        sessionMenuItem.submenu = sessionMenu
        mainMenu.addItem(sessionMenuItem)

        // Pane menu
        let paneMenuItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTabItem.target = self
        paneMenu.addItem(newTabItem)

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        closeTabItem.target = self
        paneMenu.addItem(closeTabItem)

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = self
        paneMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        prevTabItem.target = self
        paneMenu.addItem(prevTabItem)

        paneMenu.addItem(NSMenuItem.separator())

        let splitVItem = NSMenuItem(title: "Split Vertical", action: #selector(splitVertical(_:)), keyEquivalent: "d")
        splitVItem.target = self
        paneMenu.addItem(splitVItem)

        let splitHItem = NSMenuItem(title: "Split Horizontal", action: #selector(splitHorizontal(_:)), keyEquivalent: "D")
        splitHItem.keyEquivalentModifierMask = [.command, .shift]
        splitHItem.target = self
        paneMenu.addItem(splitHItem)

        paneMenu.addItem(NSMenuItem.separator())

        let navUpItem = NSMenuItem(title: "Navigate Up", action: #selector(navigateUp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        navUpItem.keyEquivalentModifierMask = [.command, .shift]
        navUpItem.target = self
        paneMenu.addItem(navUpItem)

        let navDownItem = NSMenuItem(title: "Navigate Down", action: #selector(navigateDown(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        navDownItem.keyEquivalentModifierMask = [.command, .shift]
        navDownItem.target = self
        paneMenu.addItem(navDownItem)

        let navLeftItem = NSMenuItem(title: "Navigate Left", action: #selector(navigateLeft(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        navLeftItem.keyEquivalentModifierMask = [.command, .shift]
        navLeftItem.target = self
        paneMenu.addItem(navLeftItem)

        let navRightItem = NSMenuItem(title: "Navigate Right", action: #selector(navigateRight(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        navRightItem.keyEquivalentModifierMask = [.command, .shift]
        navRightItem.target = self
        paneMenu.addItem(navRightItem)

        paneMenu.addItem(NSMenuItem.separator())

        let resizeUpItem = NSMenuItem(title: "Resize Up", action: #selector(resizeUp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        resizeUpItem.keyEquivalentModifierMask = [.control, .option]
        resizeUpItem.target = self
        paneMenu.addItem(resizeUpItem)

        let resizeDownItem = NSMenuItem(title: "Resize Down", action: #selector(resizeDown(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        resizeDownItem.keyEquivalentModifierMask = [.control, .option]
        resizeDownItem.target = self
        paneMenu.addItem(resizeDownItem)

        let resizeLeftItem = NSMenuItem(title: "Resize Left", action: #selector(resizeLeft(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        resizeLeftItem.keyEquivalentModifierMask = [.control, .option]
        resizeLeftItem.target = self
        paneMenu.addItem(resizeLeftItem)

        let resizeRightItem = NSMenuItem(title: "Resize Right", action: #selector(resizeRight(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        resizeRightItem.keyEquivalentModifierMask = [.control, .option]
        resizeRightItem.target = self
        paneMenu.addItem(resizeRightItem)

        paneMenu.addItem(NSMenuItem.separator())

        let zoomItem = NSMenuItem(title: "Zoom Pane", action: #selector(zoomPane(_:)), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command, .shift]
        zoomItem.target = self
        paneMenu.addItem(zoomItem)

        let equalizeItem = NSMenuItem(title: "Equalize Panes", action: #selector(equalizePanes(_:)), keyEquivalent: "=")
        equalizeItem.keyEquivalentModifierMask = [.command, .option]
        equalizeItem.target = self
        paneMenu.addItem(equalizeItem)

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "\\")
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(NSMenuItem.separator())
        let increaseFontItem = NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSize(_:)), keyEquivalent: "+")
        increaseFontItem.target = self
        viewMenu.addItem(increaseFontItem)
        // Hidden Cmd+= alternative so users don't need Shift for zoom in
        let increaseFontAltItem = NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSize(_:)), keyEquivalent: "=")
        increaseFontAltItem.target = self
        increaseFontAltItem.isHidden = true
        increaseFontAltItem.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(increaseFontAltItem)
        let decreaseFontItem = NSMenuItem(title: "Decrease Font Size", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        decreaseFontItem.target = self
        viewMenu.addItem(decreaseFontItem)
        let resetFontItem = NSMenuItem(title: "Reset Font Size", action: #selector(resetFontSize(_:)), keyEquivalent: "0")
        resetFontItem.target = self
        viewMenu.addItem(resetFontItem)

        viewMenu.addItem(NSMenuItem.separator())
        let commandPaletteItem = NSMenuItem(title: "Command Palette", action: #selector(showCommandPalette(_:)), keyEquivalent: "p")
        commandPaletteItem.target = self
        viewMenu.addItem(commandPaletteItem)

        viewMenu.addItem(NSMenuItem.separator())
        let findItem = NSMenuItem(title: "Find in Terminal", action: #selector(findInTerminal(_:)), keyEquivalent: "f")
        findItem.target = self
        viewMenu.addItem(findItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Theme menu
        let themeMenuItem = NSMenuItem()
        let themeMenu = NSMenu(title: "Theme")
        for theme in ThemeManager.shared.available {
            let item = NSMenuItem(
                title: theme.name,
                action: #selector(switchTheme(_:)),
                keyEquivalent: ""
            )
            item.representedObject = theme.id
            item.target = self
            if theme.id == ThemeManager.shared.current.id {
                item.state = .on
            }
            themeMenu.addItem(item)
        }
        themeMenuItem.submenu = themeMenu
        mainMenu.addItem(themeMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - App Actions

    @objc private func showCommandPalette(_ sender: Any?) {
        guard let window = windowController.window else { return }
        let palette = CommandPaletteController.shared
        if palette.isVisible { palette.dismiss(); return }

        palette.commands = [
            PaletteCommand(name: "New Tab", shortcut: "Cmd+T", icon: "plus.square") { [weak self] in self?.newTab(nil) },
            PaletteCommand(name: "Close Tab", shortcut: "Cmd+W", icon: "xmark.square") { [weak self] in self?.closeTab(nil) },
            PaletteCommand(name: "Next Tab", shortcut: "Cmd+Shift+]", icon: "arrow.right.square") { [weak self] in self?.nextTab(nil) },
            PaletteCommand(name: "Previous Tab", shortcut: "Cmd+Shift+[", icon: "arrow.left.square") { [weak self] in self?.previousTab(nil) },
            PaletteCommand(name: "New Session", shortcut: "Cmd+Shift+T", icon: "terminal") { [weak self] in self?.newSession(nil) },
            PaletteCommand(name: "Close Session", shortcut: "Cmd+Shift+W", icon: "xmark.circle") { [weak self] in self?.closeSession(nil) },
            PaletteCommand(name: "Rename Session", shortcut: "Cmd+Shift+N", icon: "pencil") { [weak self] in self?.renameSession(nil) },
            PaletteCommand(name: "Next Session", shortcut: "", icon: "arrow.right") { [weak self] in self?.nextSession(nil) },
            PaletteCommand(name: "Previous Session", shortcut: "", icon: "arrow.left") { [weak self] in self?.previousSession(nil) },
            PaletteCommand(name: "Split Vertical", shortcut: "Cmd+D", icon: "rectangle.split.1x2") { [weak self] in self?.splitVertical(nil) },
            PaletteCommand(name: "Split Horizontal", shortcut: "Cmd+Shift+D", icon: "rectangle.split.2x1") { [weak self] in self?.splitHorizontal(nil) },
            PaletteCommand(name: "Zoom Pane", shortcut: "Cmd+Shift+Enter", icon: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.zoomPane(nil) },
            PaletteCommand(name: "Equalize Panes", shortcut: "Ctrl+Opt+=", icon: "equal.square") { [weak self] in self?.equalizePanes(nil) },
            PaletteCommand(name: "Navigate Up", shortcut: "Cmd+Shift+Up", icon: "arrow.up") { [weak self] in self?.navigateUp(nil) },
            PaletteCommand(name: "Navigate Down", shortcut: "Cmd+Shift+Down", icon: "arrow.down") { [weak self] in self?.navigateDown(nil) },
            PaletteCommand(name: "Navigate Left", shortcut: "Cmd+Shift+Left", icon: "arrow.left") { [weak self] in self?.navigateLeft(nil) },
            PaletteCommand(name: "Navigate Right", shortcut: "Cmd+Shift+Right", icon: "arrow.right") { [weak self] in self?.navigateRight(nil) },
            PaletteCommand(name: "Toggle Sidebar", shortcut: "Cmd+\\", icon: "sidebar.left") { [weak self] in self?.toggleSidebar(nil) },
            PaletteCommand(name: "Increase Font Size", shortcut: "Cmd++", icon: "plus.magnifyingglass") { [weak self] in self?.increaseFontSize(nil) },
            PaletteCommand(name: "Decrease Font Size", shortcut: "Cmd+-", icon: "minus.magnifyingglass") { [weak self] in self?.decreaseFontSize(nil) },
            PaletteCommand(name: "Reset Font Size", shortcut: "Cmd+0", icon: "1.magnifyingglass") { [weak self] in self?.resetFontSize(nil) },
            PaletteCommand(name: "Find in Terminal", shortcut: "Cmd+F", icon: "magnifyingglass") { [weak self] in self?.findInTerminal(nil) },
        ] + ThemeManager.shared.available.map { [weak self] theme in
            PaletteCommand(name: "Theme: \(theme.name)", shortcut: "", icon: "paintpalette") {
                self?.applyThemeAndUpdateMenu(theme)
            }
        } + StatusBarConfig.shared.registeredSegments.map { info in
            let enabled = StatusBarConfig.shared.isEnabled(info.id)
            return PaletteCommand(
                name: "Status Bar: \(info.label)",
                shortcut: "",
                icon: enabled ? "checkmark.circle.fill" : "circle"
            ) {
                StatusBarConfig.shared.toggle(info.id)
            }
        }
        palette.show(in: window)
    }

    @objc private func switchTheme(_ sender: NSMenuItem) {
        guard let themeID = sender.representedObject as? String,
              let theme = ThemeManager.shared.available.first(where: { $0.id == themeID }) else { return }
        applyThemeAndUpdateMenu(theme)
    }

    private func applyThemeAndUpdateMenu(_ theme: ThemeDefinition) {
        ThemeManager.shared.applyTheme(theme)
        // Update terminal background to match new theme
        ghosttyApp?.updateTerminalBackground()
        // Update checkmarks in the Theme menu
        guard let mainMenu = NSApp.mainMenu else { return }
        for menuItem in mainMenu.items {
            guard menuItem.submenu?.title == "Theme" else { continue }
            for item in menuItem.submenu?.items ?? [] {
                item.state = (item.representedObject as? String) == theme.id ? .on : .off
            }
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    // MARK: - Session Actions

    @objc private func newSession(_ sender: Any?) {
        let session = sessionManager.createSession()
        windowController.displaySession(session)
        sessionManager.save()
    }

    @objc private func closeSession(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }

        let paneIDs = session.splitTree.allPaneIDs()
        for paneID in paneIDs {
            windowController.splitContainerView.removePane(id: paneID)
        }
        windowController.splitContainerView.clearCachedPanes(forSessionID: session.id)

        sessionManager.deleteSession(id: session.id)
        sessionManager.save()

        if let activeSession = sessionManager.activeSession {
            windowController.displaySession(activeSession)
        } else {
            NSApp.terminate(nil)
        }
    }

    @objc private func renameSession(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = session.name
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                sessionManager.renameSession(id: session.id, name: newName)
                sessionManager.save()
            }
        }
    }

    @objc private func nextSession(_ sender: Any?) {
        sessionManager.nextSession()
        if let session = sessionManager.activeSession {
            windowController.displaySession(session)
        }
        sessionManager.save()
    }

    @objc private func previousSession(_ sender: Any?) {
        sessionManager.previousSession()
        if let session = sessionManager.activeSession {
            windowController.displaySession(session)
        }
        sessionManager.save()
    }

    @objc private func switchToSessionByNumber(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        guard index >= 0, index < sessionManager.sessions.count else { return }
        sessionManager.switchToSession(at: index)
        if let session = sessionManager.activeSession {
            windowController.displaySession(session)
        }
        sessionManager.save()
    }

    // MARK: - Tab Actions

    @objc private func newTab(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.addNewTab()
    }

    @objc private func closeTab(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.closeActiveTab()
        // If last tab, pane fires terminalPaneProcessTerminated via delegate cascade
    }

    @objc private func nextTab(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.selectNextTab()
    }

    @objc private func previousTab(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.selectPreviousTab()
    }

    // MARK: - Pane Actions

    @objc private func splitVertical(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        if let _ = session.splitFocusedPane(direction: .vertical) {
            windowController.displaySession(session)
            sessionManager.save()
        }
    }

    @objc private func splitHorizontal(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        if let _ = session.splitFocusedPane(direction: .horizontal) {
            windowController.displaySession(session)
            sessionManager.save()
        }
    }

    @objc private func navigateUp(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.moveFocus(.up)
        if let id = session.focusedPaneID {
            windowController.splitContainerView.focusPane(id)
        }
    }

    @objc private func navigateDown(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.moveFocus(.down)
        if let id = session.focusedPaneID {
            windowController.splitContainerView.focusPane(id)
        }
    }

    @objc private func navigateLeft(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.moveFocus(.left)
        if let id = session.focusedPaneID {
            windowController.splitContainerView.focusPane(id)
        }
    }

    @objc private func navigateRight(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.moveFocus(.right)
        if let id = session.focusedPaneID {
            windowController.splitContainerView.focusPane(id)
        }
    }

    @objc private func resizeUp(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.resizeFocusedPane(direction: .horizontal, delta: -0.05)
        windowController.splitContainerView.needsLayout = true
    }

    @objc private func resizeDown(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.resizeFocusedPane(direction: .horizontal, delta: 0.05)
        windowController.splitContainerView.needsLayout = true
    }

    @objc private func resizeLeft(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.resizeFocusedPane(direction: .vertical, delta: -0.05)
        windowController.splitContainerView.needsLayout = true
    }

    @objc private func resizeRight(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.resizeFocusedPane(direction: .vertical, delta: 0.05)
        windowController.splitContainerView.needsLayout = true
    }

    @objc private func zoomPane(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.toggleZoom()
        windowController.splitContainerView.needsLayout = true
    }

    @objc private func equalizePanes(_ sender: Any?) {
        guard let session = sessionManager.activeSession else { return }
        session.splitTree.equalize()
        windowController.splitContainerView.needsLayout = true
    }

    // MARK: - View Actions

    @objc private func toggleSidebar(_ sender: Any?) {
        windowController.toggleSidebar()
    }

    @objc private func findInTerminal(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.toggleSearch()
    }

    @objc private func increaseFontSize(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID else { return }
        windowController.splitContainerView.pane(for: focusedID)?.increaseFontSize()
    }

    @objc private func decreaseFontSize(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID else { return }
        windowController.splitContainerView.pane(for: focusedID)?.decreaseFontSize()
    }

    @objc private func resetFontSize(_ sender: Any?) {
        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID else { return }
        windowController.splitContainerView.pane(for: focusedID)?.resetFontSize()
    }
}

// MARK: - SplitContainerViewDelegate

extension AppDelegate: SplitContainerViewDelegate {
    func splitContainerView(_ view: SplitContainerView, didCreatePane pane: TerminalPane) {
        // Surface creation happens automatically via viewDidMoveToWindow
    }

    func splitContainerView(_ view: SplitContainerView, paneFocused pane: TerminalPane) {
        guard let session = sessionManager.activeSession else { return }
        session.focusedPaneID = pane.paneID
        let cwd = pane.queryShellCwd()
        windowController.updateSidebarFileTree(path: cwd)
        windowController.updateSidebarGitViews(cwd: cwd)
    }

    func splitContainerView(_ view: SplitContainerView, paneProcessTerminated pane: TerminalPane) {
        // When a shell exits, close that pane
        guard let session = sessionManager.activeSession else { return }
        let paneID = pane.paneID

        view.removePane(id: paneID)

        session.focusedPaneID = paneID
        let sessionHasPanes = session.closeFocusedPane()
        if sessionHasPanes {
            windowController.displaySession(session)
        } else {
            view.clearCachedPanes(forSessionID: session.id)
            sessionManager.deleteSession(id: session.id)
            if let activeSession = sessionManager.activeSession {
                windowController.displaySession(activeSession)
            } else {
                NSApp.terminate(nil)
            }
        }
        sessionManager.save()
    }
}

// MARK: - GhosttyAppDelegate

extension AppDelegate: GhosttyAppDelegate {
    func ghosttyApp(_ app: GhosttyApp, closeSurface surfaceView: GhosttyTerminalView, processAlive: Bool) {
        guard let pane = findPane(for: surfaceView) else { return }
        pane.closeTab(for: surfaceView)
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetTitle surfaceView: GhosttyTerminalView, title: String) {
        guard let pane = findPane(for: surfaceView) else { return }
        pane.setTitle(title, for: surfaceView)
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetPwd surfaceView: GhosttyTerminalView, pwd: String) {
        guard let pane = findPane(for: surfaceView) else { return }
        pane.setPwd(pwd, for: surfaceView)

        if let session = sessionManager.activeSession,
           session.focusedPaneID == pane.paneID {
            windowController.updateSidebarFileTree(path: pwd)
            windowController.updateSidebarGitViews(cwd: pwd)
            windowController.globalStatusBar.updateFromPane(
                cwd: pwd,
                shellPid: pane.shellProcessID
            )
        }
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidRequestSplit surfaceView: GhosttyTerminalView, direction: ghostty_action_split_direction_e) {
        guard let session = sessionManager.activeSession else { return }
        let splitDir: SplitDirection = (direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT) ? .vertical : .horizontal
        if let _ = session.splitFocusedPane(direction: splitDir) {
            windowController.displaySession(session)
            sessionManager.save()
        }
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetCellSize surfaceView: GhosttyTerminalView, width: UInt32, height: UInt32) {
        // Could be used for step-resize in the future
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceNeedsRender surfaceView: GhosttyTerminalView) {
        // Ghostty's render system handles this via the Metal layer directly.
        // We just need to mark the view as needing display.
        surfaceView.needsDisplay = true
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetMouseShape surfaceView: GhosttyTerminalView, shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            cursor = .resizeUpDown
        default:
            cursor = .iBeam
        }
        surfaceView.window?.invalidateCursorRects(for: surfaceView)
        cursor.set()
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceCommandFinished surfaceView: GhosttyTerminalView, exitCode: Int, durationNanos: UInt64) {
        guard let pane = findPane(for: surfaceView) else { return }

        // Update session status indicator -- match by focusedPaneID or any pane in the split tree
        let newStatus: PaneStatus = (exitCode == 0 || exitCode == -1) ? .success : .error
        let owningSession = sessionManager.sessions.first(where: {
            $0.focusedPaneID == pane.paneID || $0.splitTree.allPaneIDs().contains(pane.paneID)
        })
        if let session = owningSession {
            session.paneStatus = newStatus
            if windowController.isSidebarVisible {
                windowController.sidebarView.reloadSessions()
            }
        }

        // Notify sidebar git views to refresh
        NotificationCenter.default.post(name: GitHelper.commandDidFinishNotification, object: nil)

        let durationSecs = Double(durationNanos) / 1_000_000_000
        // Only send notifications for commands that ran longer than 5 seconds
        guard durationSecs >= 5 else { return }

        // Only notify if the pane is NOT focused (background command)
        if let session = sessionManager.activeSession,
           session.focusedPaneID == pane.paneID,
           NSApp.isActive {
            return
        }

        let title = pane.title
        let duration = Int(durationSecs)
        let body: String
        if exitCode == 0 || exitCode == -1 {
            body = "\"\(title)\" completed after \(duration)s"
        } else {
            body = "\"\(title)\" failed (exit \(exitCode)) after \(duration)s"
        }

        let notification = NSUserNotification()
        notification.title = "Command Finished"
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidRequestSearch surfaceView: GhosttyTerminalView, needle: String?) {
        guard let pane = findPane(for: surfaceView) else { return }
        pane.showSearchWithNeedle(needle)
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetSearchTotal surfaceView: GhosttyTerminalView, total: Int) {
        guard let pane = findPane(for: surfaceView) else { return }
        pane.updateSearchTotal(total)
    }

    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetSearchSelected surfaceView: GhosttyTerminalView, selected: Int) {
        guard let pane = findPane(for: surfaceView) else { return }
        pane.updateSearchSelected(selected)
    }

    // MARK: - Helper

    /// Find the TerminalPane that contains the given GhosttyTerminalView.
    private func findPane(for surfaceView: GhosttyTerminalView) -> TerminalPane? {
        return windowController.splitContainerView.paneViews.values.first {
            $0.allTerminalViews.contains(where: { $0 === surfaceView })
        }
    }
}
