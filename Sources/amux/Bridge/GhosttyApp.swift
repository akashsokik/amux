import AppKit
import CGhostty

/// Protocol for objects that need to respond to Ghostty runtime events.
protocol GhosttyAppDelegate: AnyObject {
    /// Called when a surface requests to be closed.
    func ghosttyApp(_ app: GhosttyApp, closeSurface surfaceView: GhosttyTerminalView, processAlive: Bool)

    /// Called when a surface's title changes.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetTitle surfaceView: GhosttyTerminalView, title: String)

    /// Called when a surface's working directory changes.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetPwd surfaceView: GhosttyTerminalView, pwd: String)

    /// Called when the terminal requests a new split.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidRequestSplit surfaceView: GhosttyTerminalView, direction: ghostty_action_split_direction_e)

    /// Called when a surface's cell size is known.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetCellSize surfaceView: GhosttyTerminalView, width: UInt32, height: UInt32)

    /// Called when a render is requested.
    func ghosttyApp(_ app: GhosttyApp, surfaceNeedsRender surfaceView: GhosttyTerminalView)

    /// Called when the mouse shape should change.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetMouseShape surfaceView: GhosttyTerminalView, shape: ghostty_action_mouse_shape_e)

    /// Called when a command finishes in a terminal surface.
    func ghosttyApp(_ app: GhosttyApp, surfaceCommandFinished surfaceView: GhosttyTerminalView, exitCode: Int, durationNanos: UInt64)

    /// Called when the terminal requests search to start.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidRequestSearch surfaceView: GhosttyTerminalView, needle: String?)

    /// Called when the search total count changes.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetSearchTotal surfaceView: GhosttyTerminalView, total: Int)

    /// Called when the selected search match changes.
    func ghosttyApp(_ app: GhosttyApp, surfaceDidSetSearchSelected surfaceView: GhosttyTerminalView, selected: Int)
}

/// Manages the ghostty_app_t lifecycle and runtime callbacks.
/// There should be exactly one instance of this for the entire application.
final class GhosttyApp {
    /// The underlying ghostty app handle.
    private(set) var app: ghostty_app_t?

    /// The ghostty config handle.
    private(set) var config: ghostty_config_t?

    /// Delegate for receiving ghostty runtime events.
    weak var delegate: GhosttyAppDelegate?

    /// Whether the app initialized successfully.
    var isReady: Bool { app != nil }

    init() {
        // Initialize ghostty global state. This must be called before anything else.
        // We pass 0 args since we handle CLI ourselves.
        let initResult = ghostty_init(0, nil)
        guard initResult == GHOSTTY_SUCCESS else {
            print("[GhosttyApp] ghostty_init failed with code \(initResult)")
            return
        }

        // Create and load configuration
        guard let cfg = ghostty_config_new() else {
            print("[GhosttyApp] ghostty_config_new failed")
            return
        }

        // Load default config files (e.g. ~/.config/ghostty/config)
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)

        // Override terminal background to match the app theme
        GhosttyApp.applyThemeOverrides(cfg)

        ghostty_config_finalize(cfg)
        self.config = cfg

        // Log any config diagnostics
        let diagCount = ghostty_config_diagnostics_count(cfg)
        if diagCount > 0 {
            for i in 0..<diagCount {
                let diag = ghostty_config_get_diagnostic(cfg, i)
                let msg = String(cString: diag.message)
                print("[GhosttyApp] config warning: \(msg)")
            }
        }

        // Build the runtime configuration with our callback functions.
        var runtimeCfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                GhosttyApp.wakeupCallback(userdata)
            },
            action_cb: { app, target, action in
                GhosttyApp.actionCallback(app!, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyApp.readClipboardCallback(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                // For now we just confirm automatically
                GhosttyApp.confirmReadClipboardCallback(userdata, string: str, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyApp.writeClipboardCallback(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyApp.closeSurfaceCallback(userdata, processAlive: processAlive)
            }
        )

        // Create the ghostty app
        guard let ghosttyApp = ghostty_app_new(&runtimeCfg, cfg) else {
            print("[GhosttyApp] ghostty_app_new failed")
            ghostty_config_free(cfg)
            self.config = nil
            return
        }

        self.app = ghosttyApp

        // Set initial focus state
        ghostty_app_set_focus(ghosttyApp, NSApp.isActive)

        // Observe app activation changes
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app = app {
            ghostty_app_free(app)
        }
        if let config = config {
            ghostty_config_free(config)
        }
    }

    /// Tick the ghostty app - processes pending events, drives rendering.
    func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Notifications

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard let app = app else { return }
        ghostty_app_set_focus(app, true)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard let app = app else { return }
        ghostty_app_set_focus(app, false)
    }

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        guard let app = app else { return }
        ghostty_app_keyboard_changed(app)
    }

    // MARK: - Theme Overrides

    /// Write a temporary config file that sets the terminal background to match the app theme,
    /// then load it so it overrides the user's default ghostty config.
    private static func applyThemeOverrides(_ cfg: ghostty_config_t) {
        let tmpPath = writeBackgroundOverrideFile()
        ghostty_config_load_file(cfg, tmpPath)
    }

    /// Write the current theme background to the override config file. Returns the path.
    private static func writeBackgroundOverrideFile() -> String {
        let bg = Theme.background
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))

        let overrideConfig = "background = \(hex)\n"
        let tmpPath = NSTemporaryDirectory() + "amux-ghostty-overrides.conf"
        try? overrideConfig.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        return tmpPath
    }

    /// Update the terminal background color at runtime to match the current theme.
    func updateTerminalBackground() {
        guard let app = app else { return }

        // Build a new config with the updated background
        guard let newCfg = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newCfg)
        ghostty_config_load_recursive_files(newCfg)

        let tmpPath = GhosttyApp.writeBackgroundOverrideFile()
        ghostty_config_load_file(newCfg, tmpPath)
        ghostty_config_finalize(newCfg)

        ghostty_app_update_config(app, newCfg)
        ghostty_config_free(newCfg)
    }

    // MARK: - Static Callbacks

    /// Helper to extract GhosttyApp from userdata
    private static func appFromUserdata(_ userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
        guard let userdata = userdata else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Helper to extract GhosttyTerminalView from surface userdata
    private static func surfaceViewFromUserdata(_ userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let userdata = userdata else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Helper to extract GhosttyTerminalView from a surface handle
    private static func surfaceView(from surface: ghostty_surface_t?) -> GhosttyTerminalView? {
        guard let surface = surface else { return nil }
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Helper to get GhosttyApp from a ghostty_app_t
    private static func app(from ghosttyApp: ghostty_app_t) -> GhosttyApp? {
        guard let ud = ghostty_app_userdata(ghosttyApp) else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: - Wakeup

    private static func wakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
        guard let app = appFromUserdata(userdata) else { return }
        // Wakeup can be called from any thread. Schedule tick on main thread.
        DispatchQueue.main.async {
            app.tick()
        }
    }

    // MARK: - Action Callback

    private static func actionCallback(
        _ ghosttyApp: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let app = self.app(from: ghosttyApp) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            // A surface needs to render
            switch target.tag {
            case GHOSTTY_TARGET_SURFACE:
                guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
                app.delegate?.ghosttyApp(app, surfaceNeedsRender: surfaceView)
            default:
                break
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            if let titlePtr = action.action.set_title.title {
                let title = String(cString: titlePtr)
                app.delegate?.ghosttyApp(app, surfaceDidSetTitle: surfaceView, title: title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            if let pwdPtr = action.action.pwd.pwd {
                let pwd = String(cString: pwdPtr)
                app.delegate?.ghosttyApp(app, surfaceDidSetPwd: surfaceView, pwd: pwd)
            }
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            app.delegate?.ghosttyApp(app, surfaceDidRequestSplit: surfaceView, direction: action.action.new_split)
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            let cs = action.action.cell_size
            app.delegate?.ghosttyApp(app, surfaceDidSetCellSize: surfaceView, width: cs.width, height: cs.height)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            app.delegate?.ghosttyApp(app, surfaceDidSetMouseShape: surfaceView, shape: action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            // Handle mouse visibility (hide cursor while typing)
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            if !visible {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            // The terminal wants to close the window
            return true

        case GHOSTTY_ACTION_QUIT:
            NSApplication.shared.terminate(nil)
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_OPEN_CONFIG:
            // Open the ghostty config file
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE:
            return true

        case GHOSTTY_ACTION_SIZE_LIMIT:
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return true

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return true

        case GHOSTTY_ACTION_KEY_TABLE:
            return true

        case GHOSTTY_ACTION_SECURE_INPUT:
            return true

        case GHOSTTY_ACTION_PRESENT_TERMINAL:
            return true

        case GHOSTTY_ACTION_NEW_WINDOW:
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            return true

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            return true

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            return true

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            return true

        case GHOSTTY_ACTION_CLOSE_TAB:
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return true }
            let info = action.action.command_finished
            app.delegate?.ghosttyApp(
                app,
                surfaceCommandFinished: surfaceView,
                exitCode: Int(info.exit_code),
                durationNanos: info.duration
            )
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            return true

        case GHOSTTY_ACTION_FLOAT_WINDOW:
            return true

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            return true

        case GHOSTTY_ACTION_PROMPT_TITLE:
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Handle child process exiting - the close_surface callback handles cleanup
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            if let urlPtr = action.action.open_url.url {
                let len = Int(action.action.open_url.len)
                let data = Data(bytes: urlPtr, count: len)
                let urlStr = String(data: data, encoding: .utf8) ?? String(cString: urlPtr)
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            }
            return true

        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            let needle: String?
            if let needlePtr = action.action.start_search.needle {
                needle = String(cString: needlePtr)
            } else {
                needle = nil
            }
            app.delegate?.ghosttyApp(app, surfaceDidRequestSearch: surfaceView, needle: needle)
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            let total = Int(action.action.search_total.total)
            app.delegate?.ghosttyApp(app, surfaceDidSetSearchTotal: surfaceView, total: total)
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            guard let surfaceView = surfaceView(from: target.target.surface) else { return false }
            let selected = Int(action.action.search_selected.selected)
            app.delegate?.ghosttyApp(app, surfaceDidSetSearchSelected: surfaceView, selected: selected)
            return true

        default:
            // Unknown or unimplemented action
            return false
        }
    }

    // MARK: - Clipboard Callbacks

    private static func readClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        let surfaceView = surfaceViewFromUserdata(userdata)
        guard let surface = surfaceView?.surface else { return false }

        let pasteboard = NSPasteboard.general
        guard let str = pasteboard.string(forType: .string) else { return false }

        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }

    private static func confirmReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let surfaceView = surfaceViewFromUserdata(userdata)
        guard let surface = surfaceView?.surface else { return }
        guard let string = string else { return }

        // For now, auto-confirm clipboard requests
        ghostty_surface_complete_clipboard_request(surface, string, state, true)
    }

    private static func writeClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content = content, len > 0 else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        for i in 0..<len {
            let item = content[i]
            guard let dataPtr = item.data else { continue }
            let mime = item.mime.map { String(cString: $0) } ?? ""
            let str = String(cString: dataPtr)

            switch mime {
            case "text/plain", "":
                pasteboard.setString(str, forType: .string)
            default:
                // Skip HTML and other non-text representations
                break
            }
        }
    }

    // MARK: - Close Surface Callback

    private static func closeSurfaceCallback(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let surfaceView = surfaceViewFromUserdata(userdata) else { return }
        guard let surface = surfaceView.surface else { return }
        guard let ghosttyApp = ghostty_surface_app(surface) else { return }
        guard let app = self.app(from: ghosttyApp) else { return }

        DispatchQueue.main.async {
            app.delegate?.ghosttyApp(app, closeSurface: surfaceView, processAlive: processAlive)
        }
    }
}
