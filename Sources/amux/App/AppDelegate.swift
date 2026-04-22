import AppKit
import CGhostty
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var sessionManager: SessionManager!
    private var windowController: MainWindowController!
    private(set) var ghosttyApp: GhosttyApp?
    private(set) var agentManager: AgentManager!
    private var agentSocketServer: AgentSocketServer!

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start new terminals in home directory, not wherever the app was launched from
        FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())

        // Only request notifications when running as a proper .app bundle
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        Theme.registerFonts()
        // Initialize ThemeManager before GhosttyApp so colors are ready
        _ = ThemeManager.shared

        // Set Ghostty resources dir BEFORE init so shell integration loads for all shells
        setupGhosttyResourcesDir()
        setupAmuxShellIntegration()
        setupClaudeCodeHooks()
        setupCodexHooks()

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

        agentManager = AgentManager(sessionManager: sessionManager)

        agentSocketServer = AgentSocketServer()
        agentSocketServer.onEvent = { [weak self] paneID, tabID, event, data in
            self?.agentManager.handleHookEvent(paneID: paneID, tabID: tabID, event: event, data: data)
        }
        agentSocketServer.start()
        agentManager.startPolling()

        windowController = MainWindowController(sessionManager: sessionManager, agentManager: agentManager)
        windowController.splitContainerView.containerDelegate = self
        windowController.splitContainerView.agentManager = agentManager

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

        // Set socket path for agent hook communication
        setenv("AMUX_SOCKET_PATH", AgentSocketServer.defaultPath, 1)
        NSLog("[amux] AMUX_SOCKET_PATH=%@", AgentSocketServer.defaultPath)

        // Set AMUX_AGENT_HOOKS_DIR so shell integration scripts can prepend to PATH.
        if let resourcePath = Bundle.main.resourcePath {
            NSLog("[amux] Bundle.main.resourcePath=%@", resourcePath)
            let agentHooksDir = (resourcePath as NSString).appendingPathComponent("agent-hooks")
            let exists = FileManager.default.fileExists(atPath: agentHooksDir)
            NSLog("[amux] agent-hooks dir=%@ exists=%d", agentHooksDir, exists)
            if exists {
                setenv("AMUX_AGENT_HOOKS_DIR", agentHooksDir, 1)
            }
        } else {
            NSLog("[amux] Bundle.main.resourcePath is nil!")
        }
        // Fallback for dev builds
        if ProcessInfo.processInfo.environment["AMUX_AGENT_HOOKS_DIR"] == nil,
           let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidates = [
                execURL.appendingPathComponent("../Resources/agent-hooks").path,
                execURL.deletingLastPathComponent().appendingPathComponent("Resources/agent-hooks").path,
            ]
            for hookPath in candidates {
                let exists = FileManager.default.fileExists(atPath: hookPath)
                NSLog("[amux] fallback agent-hooks=%@ exists=%d", hookPath, exists)
                if exists {
                    setenv("AMUX_AGENT_HOOKS_DIR", hookPath, 1)
                    break
                }
            }
        }

        // Log final state
        NSLog("[amux] Final AMUX_ZSH_SCRIPT=%@", String(cString: getenv("AMUX_ZSH_SCRIPT") ?? strdup("(not set)")))
        NSLog("[amux] Final AMUX_AGENT_HOOKS_DIR=%@", String(cString: getenv("AMUX_AGENT_HOOKS_DIR") ?? strdup("(not set)")))
        NSLog("[amux] Final AMUX_SOCKET_PATH=%@", String(cString: getenv("AMUX_SOCKET_PATH") ?? strdup("(not set)")))
    }

    /// Ensure Claude Code global hooks point to amux's agent-hook script so we receive
    /// lifecycle events (PreToolUse, PostToolUse, Stop, Notification) from every session.
    private func setupClaudeCodeHooks() {
        guard let hookScript = locateAgentHookScript() else {
            NSLog("[amux] Could not locate amux-agent-hook.sh, skipping Claude Code hooks setup")
            return
        }

        let claudeDir = NSHomeDirectory() + "/.claude"
        let settingsPath = claudeDir + "/settings.json"
        let fm = FileManager.default

        // Ensure ~/.claude exists
        if !fm.fileExists(atPath: claudeDir) {
            try? fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }

        // Read existing settings or start fresh
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Build the hook entry for our script
        let hookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": hookScript,
                    "timeout": 5
                ] as [String: Any]
            ]
        ]

        let events = ["PreToolUse", "PostToolUse", "Stop", "Notification", "PermissionRequest", "UserPromptSubmit"]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in events {
            if let existing = hooks[event] as? [[String: Any]] {
                // Check if our hook is already registered
                let alreadyRegistered = existing.contains { entry in
                    guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return entryHooks.contains { ($0["command"] as? String)?.contains("amux-agent-hook") == true }
                }
                if alreadyRegistered { continue }
                // Append our hook alongside existing ones
                hooks[event] = existing + [hookEntry]
            } else {
                hooks[event] = [hookEntry]
            }
            changed = true
        }

        guard changed else {
            NSLog("[amux] Claude Code hooks already configured")
            return
        }

        settings["hooks"] = hooks

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              var jsonString = String(data: data, encoding: .utf8) else {
            NSLog("[amux] Failed to serialize Claude Code settings")
            return
        }

        // Ensure trailing newline
        if !jsonString.hasSuffix("\n") { jsonString += "\n" }

        do {
            try jsonString.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            NSLog("[amux] Configured Claude Code hooks -> %@", hookScript)
        } catch {
            NSLog("[amux] Failed to write Claude Code settings: %@", error.localizedDescription)
        }
    }

    private func setupCodexHooks() {
        guard let hookScript = locateAgentHookScript() else {
            NSLog("[amux] Could not locate amux-agent-hook.sh, skipping Codex hooks setup")
            return
        }

        let codexDir = NSHomeDirectory() + "/.codex"
        let configPath = codexDir + "/config.toml"
        let hooksPath = codexDir + "/hooks.json"
        let fm = FileManager.default

        // Ensure ~/.codex exists
        if !fm.fileExists(atPath: codexDir) {
            try? fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        }

        // Enable codex_hooks feature in config.toml
        var configContents = ""
        if let data = fm.contents(atPath: configPath), let str = String(data: data, encoding: .utf8) {
            configContents = str
        }

        if !configContents.contains("codex_hooks") {
            // Append to existing [features] section or create one
            if configContents.contains("[features]") {
                configContents = configContents.replacingOccurrences(
                    of: "[features]",
                    with: "[features]\ncodex_hooks = true"
                )
            } else {
                if !configContents.hasSuffix("\n") && !configContents.isEmpty { configContents += "\n" }
                configContents += "\n[features]\ncodex_hooks = true\n"
            }
            try? configContents.write(toFile: configPath, atomically: true, encoding: .utf8)
            NSLog("[amux] Enabled codex_hooks feature in config.toml")
        }

        // Build hooks.json
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": hookScript,
            "statusMessage": "amux hook",
            "timeout": 5
        ]
        let matcherBlock: [String: Any] = [
            "matcher": "",
            "hooks": [hookEntry]
        ]
        let events = ["SessionStart", "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"]

        // Read existing hooks.json or start fresh
        var hooksRoot: [String: Any] = [:]
        if let data = fm.contents(atPath: hooksPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hooksRoot = json
        }

        var hooks = hooksRoot["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in events {
            if let existing = hooks[event] as? [[String: Any]] {
                let alreadyRegistered = existing.contains { entry in
                    guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return entryHooks.contains { ($0["command"] as? String)?.contains("amux-agent-hook") == true }
                }
                if alreadyRegistered { continue }
                hooks[event] = existing + [matcherBlock]
            } else {
                hooks[event] = [matcherBlock]
            }
            changed = true
        }

        guard changed else {
            NSLog("[amux] Codex hooks already configured")
            return
        }

        hooksRoot["hooks"] = hooks

        guard let data = try? JSONSerialization.data(withJSONObject: hooksRoot, options: [.prettyPrinted, .sortedKeys]),
              var jsonString = String(data: data, encoding: .utf8) else {
            NSLog("[amux] Failed to serialize Codex hooks")
            return
        }

        if !jsonString.hasSuffix("\n") { jsonString += "\n" }

        do {
            try jsonString.write(toFile: hooksPath, atomically: true, encoding: .utf8)
            NSLog("[amux] Configured Codex hooks -> %@", hookScript)
        } catch {
            NSLog("[amux] Failed to write Codex hooks: %@", error.localizedDescription)
        }
    }

    private func locateAgentHookScript() -> String? {
        let fm = FileManager.default

        // Try app bundle first
        if let resourcePath = Bundle.main.resourcePath {
            let path = (resourcePath as NSString).appendingPathComponent("agent-hooks/amux-agent-hook.sh")
            if fm.fileExists(atPath: path) { return path }
        }

        // Fallback for dev builds
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidates = [
                execURL.appendingPathComponent("../Resources/agent-hooks/amux-agent-hook.sh").path,
                execURL.deletingLastPathComponent().appendingPathComponent("Resources/agent-hooks/amux-agent-hook.sh").path,
            ]
            for path in candidates {
                if fm.fileExists(atPath: path) { return path }
            }
        }

        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentManager.stopPolling()
        agentSocketServer.stop()

        sessionManager.save()

        // Clean up per-pane status files
        let statusDir = "/tmp/amux-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: statusDir)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Quit amux?"
        alert.informativeText = "All terminal sessions will be closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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

        for preset in PaneLayoutPreset.allCases {
            paneMenu.addItem(makePaneLayoutMenuItem(for: preset))
        }

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

        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "b")
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)

        let toggleEditorItem = NSMenuItem(title: "Toggle Editor Sidebar", action: #selector(toggleEditorSidebar(_:)), keyEquivalent: "\\")
        toggleEditorItem.keyEquivalentModifierMask = [.command]
        toggleEditorItem.target = self
        viewMenu.addItem(toggleEditorItem)

        let toggleGitPanelItem = NSMenuItem(title: "Toggle Git Panel", action: #selector(toggleGitPanel(_:)), keyEquivalent: "g")
        toggleGitPanelItem.keyEquivalentModifierMask = [.command, .shift]
        toggleGitPanelItem.target = self
        viewMenu.addItem(toggleGitPanelItem)

        let toggleRightSidebarItem = NSMenuItem(title: "Toggle Right Sidebar", action: #selector(toggleRightSidebar(_:)), keyEquivalent: "/")
        toggleRightSidebarItem.keyEquivalentModifierMask = [.command]
        toggleRightSidebarItem.target = self
        viewMenu.addItem(toggleRightSidebarItem)

        let saveEditorItem = NSMenuItem(title: "Save Editor File", action: #selector(saveEditorFile(_:)), keyEquivalent: "s")
        saveEditorItem.keyEquivalentModifierMask = [.command, .shift]
        saveEditorItem.target = self
        viewMenu.addItem(saveEditorItem)

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

        viewMenu.addItem(NSMenuItem.separator())

        let glassItem = NSMenuItem(
            title: "Glassmorphism",
            action: #selector(toggleGlassmorphism(_:)),
            keyEquivalent: ""
        )
        glassItem.target = self
        glassItem.state = ThemeManager.shared.glassmorphismEnabled ? .on : .off
        viewMenu.addItem(glassItem)

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

    private func makePaneLayoutMenuItem(for preset: PaneLayoutPreset) -> NSMenuItem {
        let item = NSMenuItem(
            title: preset.menuTitle,
            action: #selector(applyPaneLayoutPresetFromMenu(_:)),
            keyEquivalent: preset.keyEquivalent
        )
        item.keyEquivalentModifierMask = preset.modifierMask
        item.representedObject = preset.rawValue
        item.target = self
        return item
    }

    private func applyPaneLayoutPreset(_ preset: PaneLayoutPreset) {
        guard let session = sessionManager.activeSession else { return }
        guard session.applyLayoutPreset(preset) else {
            NSSound.beep()
            return
        }

        windowController.displaySession(session)
        sessionManager.save()
    }

    @objc private func applyPaneLayoutPresetFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = PaneLayoutPreset(rawValue: rawValue) else { return }
        applyPaneLayoutPreset(preset)
    }

    @objc private func showCommandPalette(_ sender: Any?) {
        guard let window = windowController.window else { return }
        let palette = CommandPaletteController.shared
        if palette.isVisible { palette.dismiss(); return }

        palette.commands = [
            PaletteCommand(category: "Tabs", name: "New Tab", shortcut: "Cmd+T", icon: "plus.square") { [weak self] in self?.newTab(nil) },
            PaletteCommand(category: "Tabs", name: "Close Tab", shortcut: "Cmd+W", icon: "xmark.square") { [weak self] in self?.closeTab(nil) },
            PaletteCommand(category: "Tabs", name: "Next Tab", shortcut: "Cmd+Shift+]", icon: "arrow.right.square") { [weak self] in self?.nextTab(nil) },
            PaletteCommand(category: "Tabs", name: "Previous Tab", shortcut: "Cmd+Shift+[", icon: "arrow.left.square") { [weak self] in self?.previousTab(nil) },
            PaletteCommand(category: "Sessions", name: "New Session", shortcut: "Cmd+Shift+T", icon: "terminal") { [weak self] in self?.newSession(nil) },
            PaletteCommand(category: "Sessions", name: "Close Session", shortcut: "Cmd+Shift+W", icon: "xmark.circle") { [weak self] in self?.closeSession(nil) },
            PaletteCommand(category: "Sessions", name: "Rename Session", shortcut: "Cmd+Shift+N", icon: "pencil") { [weak self] in self?.renameSession(nil) },
            PaletteCommand(category: "Sessions", name: "Next Session", shortcut: "", icon: "arrow.right") { [weak self] in self?.nextSession(nil) },
            PaletteCommand(category: "Sessions", name: "Previous Session", shortcut: "", icon: "arrow.left") { [weak self] in self?.previousSession(nil) },
            PaletteCommand(category: "Panes", name: "Split Vertical", shortcut: "Cmd+D", icon: "rectangle.split.1x2") { [weak self] in self?.splitVertical(nil) },
            PaletteCommand(category: "Panes", name: "Split Horizontal", shortcut: "Cmd+Shift+D", icon: "rectangle.split.2x1") { [weak self] in self?.splitHorizontal(nil) },
        ] + PaneLayoutPreset.allCases.map { [weak self] preset in
            PaletteCommand(
                category: "Layouts",
                name: preset.menuTitle,
                shortcut: preset.shortcutLabel,
                icon: preset.icon
            ) {
                self?.applyPaneLayoutPreset(preset)
            }
        } + [
            PaletteCommand(category: "Panes", name: "Zoom Pane", shortcut: "Cmd+Shift+Enter", icon: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.zoomPane(nil) },
            PaletteCommand(category: "Panes", name: "Equalize Panes", shortcut: "Cmd+Opt+=", icon: "equal.square") { [weak self] in self?.equalizePanes(nil) },
            PaletteCommand(category: "Navigation", name: "Navigate Up", shortcut: "Cmd+Shift+Up", icon: "arrow.up") { [weak self] in self?.navigateUp(nil) },
            PaletteCommand(category: "Navigation", name: "Navigate Down", shortcut: "Cmd+Shift+Down", icon: "arrow.down") { [weak self] in self?.navigateDown(nil) },
            PaletteCommand(category: "Navigation", name: "Navigate Left", shortcut: "Cmd+Shift+Left", icon: "arrow.left") { [weak self] in self?.navigateLeft(nil) },
            PaletteCommand(category: "Navigation", name: "Navigate Right", shortcut: "Cmd+Shift+Right", icon: "arrow.right") { [weak self] in self?.navigateRight(nil) },
            PaletteCommand(category: "View", name: "Toggle Sidebar", shortcut: "Cmd+B", icon: "sidebar.left") { [weak self] in self?.toggleSidebar(nil) },
            PaletteCommand(category: "View", name: "Toggle Editor Sidebar", shortcut: "Cmd+\\", icon: "sidebar.right") { [weak self] in self?.toggleEditorSidebar(nil) },
            PaletteCommand(category: "View", name: "Toggle Git Panel", shortcut: "Cmd+Shift+G", icon: "arrow.triangle.branch") { [weak self] in self?.toggleGitPanel(nil) },
            PaletteCommand(category: "View", name: "Toggle Right Sidebar", shortcut: "Cmd+/", icon: "sidebar.right") { [weak self] in self?.toggleRightSidebar(nil) },
            PaletteCommand(category: "View", name: "Increase Font Size", shortcut: "Cmd++", icon: "plus.magnifyingglass") { [weak self] in self?.increaseFontSize(nil) },
            PaletteCommand(category: "View", name: "Decrease Font Size", shortcut: "Cmd+-", icon: "minus.magnifyingglass") { [weak self] in self?.decreaseFontSize(nil) },
            PaletteCommand(category: "View", name: "Reset Font Size", shortcut: "Cmd+0", icon: "1.magnifyingglass") { [weak self] in self?.resetFontSize(nil) },
            PaletteCommand(category: "Search", name: "Find in Terminal", shortcut: "Cmd+F", icon: "magnifyingglass") { [weak self] in self?.findInTerminal(nil) },
        ] + [
            PaletteCommand(
                category: "Theme",
                name: "Toggle Dark/Light Mode",
                shortcut: "",
                icon: ThemeManager.shared.current.isLight ? "moon" : "sun.max"
            ) { [weak self] in
                self?.toggleAppearance(nil)
            },
            PaletteCommand(
                category: "Theme",
                name: "Toggle Glassmorphism",
                shortcut: "",
                icon: ThemeManager.shared.glassmorphismEnabled ? "checkmark.circle.fill" : "circle"
            ) { [weak self] in
                self?.toggleGlassmorphism(nil)
            },
        ] + ThemeManager.shared.available.filter({ !$0.isLight }).map { [weak self] theme in
            let isCurrent = ThemeManager.shared.current.familyName == theme.familyName
            return PaletteCommand(category: "Theme", name: "Theme: \(theme.name)", shortcut: "", icon: isCurrent ? "checkmark.circle.fill" : "paintpalette") {
                // Apply the dark or light variant depending on current appearance preference
                let target = ThemeManager.shared.current.isLight ? (theme.companion ?? theme) : theme
                self?.applyThemeAndUpdateMenu(target)
            }
        } + StatusBarConfig.shared.registeredSegments.map { info in
            let enabled = StatusBarConfig.shared.isEnabled(info.id)
            return PaletteCommand(
                category: "Status Bar",
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

    @objc private func toggleAppearance(_ sender: Any?) {
        ThemeManager.shared.toggleAppearance()
        ghosttyApp?.updateTerminalBackground()
        // Update checkmarks in the Theme menu
        guard let mainMenu = NSApp.mainMenu else { return }
        for menuItem in mainMenu.items {
            guard menuItem.submenu?.title == "Theme" else { continue }
            for item in menuItem.submenu?.items ?? [] {
                item.state = (item.representedObject as? String) == ThemeManager.shared.current.id ? .on : .off
            }
        }
    }

    @objc private func toggleGlassmorphism(_ sender: Any?) {
        ThemeManager.shared.toggleGlassmorphism()
        ghosttyApp?.updateTerminalBackground()
        // Update checkmark in View menu
        if let mainMenu = NSApp.mainMenu {
            for menuItem in mainMenu.items {
                guard menuItem.submenu?.title == "View" else { continue }
                for item in menuItem.submenu?.items ?? [] where item.title == "Glassmorphism" {
                    item.state = ThemeManager.shared.glassmorphismEnabled ? .on : .off
                }
            }
        }
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
        if windowController.isEditorSidebarVisible,
           windowController.editorSidebarView.hasOpenTabs,
           windowController.editorSidebarView.handlesTabShortcuts(in: windowController.window) {
            windowController.editorSidebarView.closeCurrentTab()
            return
        }

        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.closeActiveTab()
    }

    @objc private func nextTab(_ sender: Any?) {
        if windowController.isEditorSidebarVisible,
           windowController.editorSidebarView.hasOpenTabs,
           windowController.editorSidebarView.handlesTabShortcuts(in: windowController.window) {
            windowController.editorSidebarView.selectNextTab()
            return
        }

        guard let session = sessionManager.activeSession,
              let focusedID = session.focusedPaneID,
              let pane = windowController.splitContainerView.pane(for: focusedID) else { return }
        pane.selectNextTab()
    }

    @objc private func previousTab(_ sender: Any?) {
        if windowController.isEditorSidebarVisible,
           windowController.editorSidebarView.hasOpenTabs,
           windowController.editorSidebarView.handlesTabShortcuts(in: windowController.window) {
            windowController.editorSidebarView.selectPreviousTab()
            return
        }

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

    @objc private func toggleEditorSidebar(_ sender: Any?) {
        windowController.toggleEditorSidebar()
    }

    @objc private func toggleGitPanel(_ sender: Any?) {
        windowController.toggleGitPanel()
    }

    @objc private func toggleRightSidebar(_ sender: Any?) {
        windowController.toggleRightSidebar()
    }

    @objc private func saveEditorFile(_ sender: Any?) {
        guard windowController.isEditorSidebarVisible else { return }
        windowController.editorSidebarView.saveActiveTab()
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

        let content = UNMutableNotificationContent()
        content.title = "Command Finished"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
