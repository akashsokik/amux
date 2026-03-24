import AppKit
import CGhostty

// MARK: - Tab Model

struct PaneTab {
    let id: UUID
    var title: String = "Terminal"
}

// MARK: - Drop Edge

enum DropEdge {
    case left, right, top, bottom
}

// MARK: - Delegate

protocol TerminalPaneDelegate: AnyObject {
    func terminalPane(_ pane: TerminalPane, didUpdateTitle title: String)
    func terminalPane(_ pane: TerminalPane, didUpdateCurrentDirectory directory: String?)
    func terminalPaneProcessTerminated(_ pane: TerminalPane, exitCode: Int32?)
    func terminalPaneBell(_ pane: TerminalPane)
    func terminalPaneDidGainFocus(_ pane: TerminalPane)
    func terminalPane(_ pane: TerminalPane, didReceiveTabDrop info: TabDragInfo, atIndex index: Int)
    func terminalPane(_ pane: TerminalPane, didReceiveEdgeDrop info: TabDragInfo, edge: DropEdge)
    func terminalPaneDidBecomeEmpty(_ pane: TerminalPane)
    func terminalPane(_ pane: TerminalPane, canAcceptDrop info: TabDragInfo) -> Bool
}

/// TerminalPane wraps one or more GhosttyTerminalViews behind a tab bar.
/// The split tree still manages panes; tabs are internal to each pane.
class TerminalPane: NSView {
    let paneID: UUID
    weak var delegate: TerminalPaneDelegate?

    // MARK: - Status file

    private static let statusDir: String = {
        let dir = "/tmp/amux-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private(set) var statusFilePath: String?

    // MARK: - Tab state

    private(set) var tabs: [PaneTab] = []
    private(set) var activeTabID: UUID?
    private var terminalViewsByTab: [UUID: GhosttyTerminalView] = [:]

    // MARK: - Views

    private var glassView: GlassBackgroundView?
    private var tabBar: PaneTabBar!
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private var searchBar: PaneSearchBar?
    private var dropOverlay: NSView?

    // MARK: - Focus

    var isFocused: Bool = false {
        didSet { activeTerminalView?.isFocused = isFocused }
    }

    // MARK: - Title / directory (active tab)

    var title: String {
        get {
            guard let id = activeTabID,
                  let tab = tabs.first(where: { $0.id == id }) else { return "Terminal" }
            return tab.title
        }
        set {
            setTitle(newValue, forTabID: activeTabID)
        }
    }

    var currentDirectory: String? = NSHomeDirectory()

    /// PID of the shell process for this pane's active tab (for CWD polling).
    private var shellPid: pid_t?

    /// Shell PIDs for all tabs in this pane (tabID -> pid).
    private var shellPidsByTab: [UUID: pid_t] = [:]

    /// Public read-only access to the shell PID (used for status polling).
    var shellProcessID: pid_t? { shellPid }

    /// All shell PIDs across all tabs (for agent detection).
    var allShellPIDs: [(tabID: UUID, pid: pid_t)] {
        var result = shellPidsByTab.map { (tabID: $0.key, pid: $0.value) }
        // Backfill: if the active tab's PID isn't in shellPidsByTab
        // (e.g. first tab discovered before per-tab tracking), add it
        if let tabID = activeTabID, let pid = shellPid,
           shellPidsByTab[tabID] == nil {
            shellPidsByTab[tabID] = pid
            result.append((tabID: tabID, pid: pid))
        }
        return result
    }

    // MARK: - Terminal view accessors

    /// The active tab's terminal view (backward-compat with single-terminal callers).
    var terminalView: GhosttyTerminalView! {
        guard let id = activeTabID else { return nil }
        return terminalViewsByTab[id]
    }

    /// Every terminal view across all tabs (for lookup by surface).
    var allTerminalViews: [GhosttyTerminalView] {
        Array(terminalViewsByTab.values)
    }

    var tabCount: Int { tabs.count }

    private var activeTerminalView: GhosttyTerminalView? {
        guard let id = activeTabID else { return nil }
        return terminalViewsByTab[id]
    }

    // MARK: - Init

    init(paneID: UUID, skipInitialTab: Bool = false) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        setupTabBar()
        if !skipInitialTab {
            addInitialTab()
        }
        setupDropDestination()
        applyGlassOrSolid()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let path = statusFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy {
            layer?.backgroundColor = NSColor.clear.cgColor
            if glassView == nil {
                let gv = GlassBackgroundView(blending: .behindWindow)
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
            glassView?.setTint(Theme.background, opacity: 0.35)
        } else {
            layer?.backgroundColor = Theme.background.cgColor
            glassView?.isHidden = true
        }
    }

    @objc private func themeDidChange() {
        applyGlassOrSolid()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupTabBar() {
        tabBar = PaneTabBar(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        tabBar.ownerPaneID = paneID
        addSubview(tabBar)

        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeightConstraint,
        ])
    }

    private func addInitialTab() {
        let tabID = UUID()
        tabs.append(PaneTab(id: tabID))
        activeTabID = tabID

        let tv = makeTerminalView(tabID: tabID)
        addSubview(tv)
        refreshTabBar()
    }

    private func makeTerminalView(tabID: UUID) -> GhosttyTerminalView {
        let tv = GhosttyTerminalView(paneID: tabID)
        tv.delegate = self
        terminalViewsByTab[tabID] = tv
        return tv
    }

    private func withSurfaceEnvironment(forTabID tabID: UUID, _ body: () -> Void) {
        let statusPath = "\(TerminalPane.statusDir)/\(paneID.uuidString)"
        statusFilePath = statusPath
        setenv("AMUX_STATUS_FILE", statusPath, 1)
        setenv("AMUX_PANE_ID", paneID.uuidString, 1)
        setenv("AMUX_TAB_ID", tabID.uuidString, 1)
        body()
        unsetenv("AMUX_STATUS_FILE")
        unsetenv("AMUX_PANE_ID")
        unsetenv("AMUX_TAB_ID")
    }

    // MARK: - Tab Operations

    func addNewTab() {
        let tabID = UUID()
        let tab = PaneTab(id: tabID)

        // Insert after active tab
        if let activeID = activeTabID,
           let idx = tabs.firstIndex(where: { $0.id == activeID }) {
            tabs.insert(tab, at: idx + 1)
        } else {
            tabs.append(tab)
        }

        // Hide current terminal
        if let currentID = activeTabID {
            terminalViewsByTab[currentID]?.isHidden = true
            terminalViewsByTab[currentID]?.isFocused = false
        }

        // Create and show new terminal
        let tv = makeTerminalView(tabID: tabID)
        addSubview(tv)
        activeTabID = tabID

        // Create ghostty surface if window is available
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let ghosttyApp = appDelegate.ghosttyApp,
           let app = ghosttyApp.app {
            let pidsBefore = Set(ProcessHelper.childPids())
            withSurfaceEnvironment(forTabID: tabID) {
                tv.createSurface(app: app)
            }
            // Discover shell PID for the new tab (with retries for fish etc.)
            discoverShellPid(pidsBefore: pidsBefore, attempt: 0, forTabID: tabID)
        }

        tv.isFocused = isFocused
        layoutTerminalViews()
        refreshTabBar()

        if isFocused { tv.focus() }
    }

    func closeTab(_ tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        if let tv = terminalViewsByTab.removeValue(forKey: tabID) {
            tv.removeFromSuperview()
        }
        tabs.remove(at: idx)

        if tabs.isEmpty {
            // Last tab -- close the pane
            delegate?.terminalPaneProcessTerminated(self, exitCode: nil)
            return
        }

        // Switch to an adjacent tab if we closed the active one
        if activeTabID == tabID {
            let newIdx = min(idx, tabs.count - 1)
            switchToTab(tabs[newIdx].id)
        }

        refreshTabBar()
    }

    func closeActiveTab() {
        guard let id = activeTabID else { return }
        closeTab(id)
    }

    /// Close the tab whose terminal view matches (e.g. when its shell exits).
    func closeTab(for terminalView: GhosttyTerminalView) {
        guard let tabID = terminalViewsByTab.first(where: { $0.value === terminalView })?.key else { return }
        closeTab(tabID)
    }

    func switchToTab(_ tabID: UUID) {
        guard tabID != activeTabID, terminalViewsByTab[tabID] != nil else { return }

        // Hide current
        if let currentID = activeTabID {
            terminalViewsByTab[currentID]?.isHidden = true
            terminalViewsByTab[currentID]?.isFocused = false
        }

        activeTabID = tabID
        let tv = terminalViewsByTab[tabID]!
        tv.isHidden = false
        tv.isFocused = isFocused

        layoutTerminalViews()
        refreshTabBar()

        if isFocused { tv.focus() }

        if let tab = tabs.first(where: { $0.id == tabID }) {
            delegate?.terminalPane(self, didUpdateTitle: tab.title)
        }
    }

    func selectNextTab() {
        guard tabs.count > 1, let activeID = activeTabID,
              let idx = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        switchToTab(tabs[(idx + 1) % tabs.count].id)
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let activeID = activeTabID,
              let idx = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        switchToTab(tabs[(idx - 1 + tabs.count) % tabs.count].id)
    }

    // MARK: - Tab Transfer (Drag & Drop)

    /// Remove a tab without destroying its terminal view. Returns the tab model and view for re-insertion elsewhere.
    func extractTab(_ tabID: UUID) -> (PaneTab, GhosttyTerminalView)? {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let tv = terminalViewsByTab.removeValue(forKey: tabID) else { return nil }

        let tab = tabs[idx]
        tv.removeFromSuperview()
        tabs.remove(at: idx)

        if tabs.isEmpty {
            delegate?.terminalPaneDidBecomeEmpty(self)
            return (tab, tv)
        }

        // If we removed the active tab, switch to an adjacent one
        if activeTabID == tabID {
            let newIdx = min(idx, tabs.count - 1)
            switchToTab(tabs[newIdx].id)
        }

        refreshTabBar()
        return (tab, tv)
    }

    /// Insert an existing tab+view (from another pane) at the given index.
    func insertTab(_ tab: PaneTab, terminalView: GhosttyTerminalView, at index: Int) {
        // Hide current active view
        if let currentID = activeTabID {
            terminalViewsByTab[currentID]?.isHidden = true
            terminalViewsByTab[currentID]?.isFocused = false
        }

        let clampedIndex = min(index, tabs.count)
        tabs.insert(tab, at: clampedIndex)
        terminalViewsByTab[tab.id] = terminalView
        terminalView.delegate = self
        addSubview(terminalView)

        activeTabID = tab.id
        terminalView.isHidden = false
        terminalView.isFocused = isFocused

        layoutTerminalViews()
        refreshTabBar()

        if isFocused { terminalView.focus() }
    }

    // MARK: - Title / pwd helpers (called from AppDelegate callbacks)

    func setTitle(_ title: String, for terminalView: GhosttyTerminalView) {
        guard let tabID = terminalViewsByTab.first(where: { $0.value === terminalView })?.key else { return }
        setTitle(title, forTabID: tabID)
    }

    func setPwd(_ pwd: String, for terminalView: GhosttyTerminalView) {
        // Accept pwd from any terminal view belonging to this pane (same approach as setTitle)
        guard terminalViewsByTab.values.contains(where: { $0 === terminalView }) else { return }
        currentDirectory = pwd
        delegate?.terminalPane(self, didUpdateCurrentDirectory: pwd)
    }

    /// Poll the shell process for its current working directory.
    /// Falls back to stored currentDirectory if the shell PID is unknown.
    func queryShellCwd() -> String {
        if let pid = shellPid, let cwd = ProcessHelper.cwd(of: pid) {
            currentDirectory = cwd
            return cwd
        }
        // shellPid might be nil (e.g. fish shell spawns differently).
        // Try to discover it by scanning child processes with a matching name.
        if shellPid == nil {
            if discoverShellPidByName(), let pid = shellPid, let cwd = ProcessHelper.cwd(of: pid) {
                return cwd
            }
        }
        return currentDirectory ?? NSHomeDirectory()
    }

    private func setTitle(_ title: String, forTabID tabID: UUID?) {
        guard let tabID = tabID,
              let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[idx].title = title
        if tabID == activeTabID {
            delegate?.terminalPane(self, didUpdateTitle: title)
        }
        refreshTabBar()
    }

    // MARK: - Tab Bar

    private func refreshTabBar() {
        tabBarHeightConstraint.constant = PaneTabBar.barHeight
        tabBar.isHidden = false
        tabBar.updateTabs(tabs.map { (id: $0.id, title: $0.title) }, activeID: activeTabID)
        layoutTerminalViews()
    }

    // MARK: - Layout

    private func layoutTerminalViews() {
        let tabBarH: CGFloat = tabBar.isHidden ? 0 : PaneTabBar.barHeight
        let searchBarH: CGFloat = searchBar != nil ? PaneSearchBar.barHeight : 0
        let terminalFrame = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: bounds.height - tabBarH - searchBarH
        )

        for (id, tv) in terminalViewsByTab {
            tv.frame = terminalFrame
            tv.isHidden = (id != activeTabID)
        }
    }

    override func layout() {
        super.layout()
        layoutTerminalViews()
    }

    // MARK: - Surface Creation

    func createSurface(ghosttyApp: GhosttyApp) {
        guard let app = ghosttyApp.app else { return }
        for (tabID, tv) in terminalViewsByTab {
            withSurfaceEnvironment(forTabID: tabID) {
                tv.createSurface(app: app)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        if let appDelegate = NSApp.delegate as? AppDelegate,
           let ghosttyApp = appDelegate.ghosttyApp,
           let app = ghosttyApp.app {
            let pidsBefore = Set(ProcessHelper.childPids())
            for (tabID, tv) in terminalViewsByTab where tv.surface == nil {
                withSurfaceEnvironment(forTabID: tabID) {
                    tv.createSurface(app: app)
                }
            }
            // Discover the shell PID spawned by the new surface.
            // Use retries with increasing delays to handle shells like fish
            // that may take longer to appear in the process table.
            discoverShellPid(pidsBefore: pidsBefore, attempt: 0, forTabID: activeTabID)
        }
    }

    /// Attempt to discover the shell PID with retries.
    /// Fish shell can take longer to start than bash/zsh, so we retry
    /// at increasing intervals: 0.5s, 1.0s, 2.0s.
    private func discoverShellPid(pidsBefore: Set<pid_t>, attempt: Int, forTabID tabID: UUID?) {
        let delays: [TimeInterval] = [0.5, 1.0, 2.0]
        guard attempt < delays.count else {
            // All retries exhausted -- fall back to name-based matching
            discoverShellPidByName(forTabID: tabID)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self = self else { return }
            // Check if THIS tab's PID was already found (not the pane-global one)
            if let t = tabID, self.shellPidsByTab[t] != nil { return }
            if tabID == nil && self.shellPid != nil { return }

            // Try PID subtraction first (most reliable when it works)
            let pidsAfter = Set(ProcessHelper.childPids())
            let newPids = pidsAfter.subtracting(pidsBefore)

            // If multiple new PIDs, prefer the one matching the user's shell name
            let shellName = URL(fileURLWithPath: TerminalPane.userShell()).lastPathComponent
            let matched = newPids.first(where: { pid in
                ProcessHelper.name(of: pid) == shellName
            }) ?? newPids.first

            if let pid = matched {
                self.shellPid = pid
                if let t = tabID {
                    self.shellPidsByTab[t] = pid
                }
                if let cwd = ProcessHelper.cwd(of: pid) {
                    self.currentDirectory = cwd
                }
                return
            }

            // Try name-based matching as fallback before next retry
            if self.discoverShellPidByName(forTabID: tabID) { return }

            // Retry with next delay
            self.discoverShellPid(pidsBefore: pidsBefore, attempt: attempt + 1, forTabID: tabID)
        }
    }

    /// Try to find the shell PID by matching process names against the user's shell.
    @discardableResult
    private func discoverShellPidByName(forTabID tabID: UUID? = nil) -> Bool {
        let shellName = URL(fileURLWithPath: TerminalPane.userShell()).lastPathComponent
        let knownPids = Set(shellPidsByTab.values)
        let children = ProcessHelper.childPids()
        for pid in children {
            // Skip PIDs already claimed by other tabs
            guard !knownPids.contains(pid) else { continue }
            if let name = ProcessHelper.name(of: pid),
               name == shellName,
               let cwd = ProcessHelper.cwd(of: pid) {
                shellPid = pid
                if let t = tabID {
                    shellPidsByTab[t] = pid
                }
                currentDirectory = cwd
                return true
            }
        }
        return false
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        return true
    }

    func focus() {
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
        }
        isFocused = true
    }

    // MARK: - Font Size

    func increaseFontSize() { terminalView?.increaseFontSize() }
    func decreaseFontSize() { terminalView?.decreaseFontSize() }
    func resetFontSize() { terminalView?.resetFontSize() }


    // MARK: - Search

    func toggleSearch() {
        if searchBar != nil {
            dismissSearch()
        } else {
            showSearch()
        }
    }

    private func showSearch() {
        guard searchBar == nil else { return }
        let bar = PaneSearchBar(surface: terminalView?.surface)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.delegate = self
        addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: PaneSearchBar.barHeight),
        ])

        searchBar = bar
        layoutTerminalViews()
        bar.activate()
    }

    private func dismissSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        layoutTerminalViews()
        terminalView?.focus()
    }

    func showSearchWithNeedle(_ needle: String?) {
        if searchBar == nil {
            showSearch()
        }
        if let needle = needle, !needle.isEmpty {
            searchBar?.setSearchText(needle)
        }
    }

    func updateSearchTotal(_ total: Int) {
        searchBar?.updateTotal(total)
    }

    func updateSearchSelected(_ selected: Int) {
        searchBar?.updateSelected(selected)
    }

    // MARK: - Edge Drop Destination

    private func setupDropDestination() {
        registerForDraggedTypes([.tabDrag])
    }

    private func decodeDragInfo(from draggingInfo: NSDraggingInfo) -> TabDragInfo? {
        guard let data = draggingInfo.draggingPasteboard.data(forType: .tabDrag) else { return nil }
        return try? JSONDecoder().decode(TabDragInfo.self, from: data)
    }

    private func dropEdge(for point: NSPoint) -> DropEdge? {
        let tabBarH: CGFloat = tabBar.isHidden ? 0 : PaneTabBar.barHeight
        let contentRect = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: bounds.height - tabBarH
        )
        let local = point
        guard contentRect.contains(local) else { return nil }

        let relX = (local.x - contentRect.minX) / contentRect.width
        let relY = (local.y - contentRect.minY) / contentRect.height

        let edgeThreshold: CGFloat = 0.25

        // Check edges: prioritize whichever axis is further from center
        let distLeft = relX
        let distRight = 1 - relX
        let distBottom = relY
        let distTop = 1 - relY

        let minDist = min(distLeft, distRight, distBottom, distTop)
        guard minDist < edgeThreshold else { return nil }

        if minDist == distLeft { return .left }
        if minDist == distRight { return .right }
        if minDist == distBottom { return .bottom }
        return .top
    }

    private func showDropOverlay(for edge: DropEdge) {
        let tabBarH: CGFloat = tabBar.isHidden ? 0 : PaneTabBar.barHeight
        let contentRect = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: bounds.height - tabBarH
        )

        let overlayRect: NSRect
        switch edge {
        case .left:
            overlayRect = NSRect(x: contentRect.minX, y: contentRect.minY,
                                 width: contentRect.width / 2, height: contentRect.height)
        case .right:
            overlayRect = NSRect(x: contentRect.midX, y: contentRect.minY,
                                 width: contentRect.width / 2, height: contentRect.height)
        case .top:
            overlayRect = NSRect(x: contentRect.minX, y: contentRect.midY,
                                 width: contentRect.width, height: contentRect.height / 2)
        case .bottom:
            overlayRect = NSRect(x: contentRect.minX, y: contentRect.minY,
                                 width: contentRect.width, height: contentRect.height / 2)
        }

        if dropOverlay == nil {
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            addSubview(overlay)
            dropOverlay = overlay
        }
        dropOverlay?.frame = overlayRect
        dropOverlay?.isHidden = false
    }

    private func hideDropOverlay() {
        dropOverlay?.isHidden = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let info = decodeDragInfo(from: sender),
              delegate?.terminalPane(self, canAcceptDrop: info) == true else {
            return []
        }
        let local = convert(sender.draggingLocation, from: nil)
        if let edge = dropEdge(for: local) {
            showDropOverlay(for: edge)
            return .move
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let info = decodeDragInfo(from: sender),
              delegate?.terminalPane(self, canAcceptDrop: info) == true else {
            hideDropOverlay()
            return []
        }
        let local = convert(sender.draggingLocation, from: nil)
        if let edge = dropEdge(for: local) {
            showDropOverlay(for: edge)
            return .move
        }
        hideDropOverlay()
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropOverlay()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropOverlay()
        guard let info = decodeDragInfo(from: sender),
              delegate?.terminalPane(self, canAcceptDrop: info) == true else {
            return false
        }
        let local = convert(sender.draggingLocation, from: nil)
        guard let edge = dropEdge(for: local) else { return false }
        delegate?.terminalPane(self, didReceiveEdgeDrop: info, edge: edge)
        return true
    }

    // MARK: - Shell Detection

    static func userShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize > 0 else { return "/bin/zsh" }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0,
              result != nil else { return "/bin/zsh" }
        return String(cString: pwd.pw_shell)
    }
}

// MARK: - GhosttyTerminalViewDelegate

extension TerminalPane: GhosttyTerminalViewDelegate {
    func terminalViewDidUpdateTitle(_ view: GhosttyTerminalView, title: String) {
        setTitle(title, for: view)
    }

    func terminalViewDidUpdatePwd(_ view: GhosttyTerminalView, pwd: String) {
        setPwd(pwd, for: view)
    }

    func terminalViewProcessTerminated(_ view: GhosttyTerminalView) {
        closeTab(for: view)
    }

    func terminalViewBell(_ view: GhosttyTerminalView) {
        delegate?.terminalPaneBell(self)
    }

    func terminalViewDidGainFocus(_ view: GhosttyTerminalView) {
        isFocused = true
        delegate?.terminalPaneDidGainFocus(self)
    }
}

// MARK: - PaneTabBarDelegate

extension TerminalPane: PaneTabBarDelegate {
    func tabBar(_ tabBar: PaneTabBar, didSelectTab tabID: UUID) {
        switchToTab(tabID)
    }

    func tabBar(_ tabBar: PaneTabBar, didCloseTab tabID: UUID) {
        closeTab(tabID)
    }

    func tabBarDidRequestNewTab(_ tabBar: PaneTabBar) {
        addNewTab()
    }

    func tabBar(_ tabBar: PaneTabBar, didReceiveDroppedTab info: TabDragInfo, atIndex index: Int) {
        delegate?.terminalPane(self, didReceiveTabDrop: info, atIndex: index)
    }

    func tabBar(_ tabBar: PaneTabBar, canAcceptDrop info: TabDragInfo) -> Bool {
        return delegate?.terminalPane(self, canAcceptDrop: info) ?? false
    }
}

// MARK: - PaneSearchBarDelegate

extension TerminalPane: PaneSearchBarDelegate {
    func searchBarDidDismiss(_ searchBar: PaneSearchBar) {
        dismissSearch()
    }
}
