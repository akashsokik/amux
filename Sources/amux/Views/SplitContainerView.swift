import AppKit

protocol SplitContainerViewDelegate: AnyObject {
    func splitContainerView(_ view: SplitContainerView, didCreatePane pane: TerminalPane)
    func splitContainerView(_ view: SplitContainerView, paneProcessTerminated pane: TerminalPane)
    func splitContainerView(_ view: SplitContainerView, paneFocused pane: TerminalPane)
}

class SplitContainerView: NSView {
    private var splitTree: SplitTree?
    private var glassView: GlassBackgroundView?
    weak var containerDelegate: SplitContainerViewDelegate?
    weak var agentManager: AgentManager?

    /// Map pane IDs to TerminalPane views for the CURRENT session.
    private(set) var paneViews: [UUID: TerminalPane] = [:]
    /// Divider views keyed by the split container node ID.
    private var dividerViews: [UUID: DividerView] = [:]

    /// Text to feed into the shell of a not-yet-created pane, keyed by pane ID.
    /// Consumed by `createPane(id:)` on first creation, then removed. Used by
    /// "promote runner task to pane" so the controller can pre-register the
    /// command for the fresh pane before asking the tree to display.
    private var pendingInitialInputs: [UUID: String] = [:]

    /// Cache of pane views per session, so terminals survive session switches.
    private var sessionPaneCache: [UUID: [UUID: TerminalPane]] = [:]
    /// The session ID currently being displayed.
    private var currentSessionID: UUID?

    var focusedPaneID: UUID? {
        didSet { updateFocusIndicators() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        layer?.masksToBounds = true
        applyGlassOrSolid()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Set split tree

    func setSplitTree(_ tree: SplitTree, forSessionID sessionID: UUID) {
        let isSameSession = (currentSessionID == sessionID)
        print("[SplitContainer] setSplitTree session=\(sessionID) same=\(isSameSession) currentPanes=\(paneViews.keys.map { $0.uuidString.prefix(4) }) treeIDs=\(tree.allPaneIDs().map { $0.uuidString.prefix(4) })")

        // If switching to a different session, cache current panes and restore cached panes
        if let currentID = currentSessionID, currentID != sessionID {
            // Save current pane views to cache (keeps them alive)
            sessionPaneCache[currentID] = paneViews
            print("[SplitContainer] Cached \(paneViews.count) panes for session \(String(currentID.uuidString.prefix(4)))")

            // Detach current panes from view hierarchy (don't destroy)
            for (_, paneView) in paneViews {
                paneView.removeFromSuperview()
            }

            // Detach current dividers
            for (_, dividerView) in dividerViews {
                dividerView.removeFromSuperview()
            }
            dividerViews.removeAll()

            // Load cached panes for the new session
            paneViews = sessionPaneCache[sessionID] ?? [:]
            print("[SplitContainer] Restored \(paneViews.count) cached panes for session \(String(sessionID.uuidString.prefix(4)))")

            // Re-add cached panes as subviews
            for (_, paneView) in paneViews {
                if paneView.superview != self {
                    addSubview(paneView)
                }
            }
        }

        currentSessionID = sessionID
        self.splitTree = tree

        guard let root = tree.root else {
            // Tree is empty -- remove everything for this session
            for (_, paneView) in paneViews {
                paneView.removeFromSuperview()
            }
            paneViews.removeAll()
            for (_, dividerView) in dividerViews {
                dividerView.removeFromSuperview()
            }
            dividerViews.removeAll()
            return
        }

        // Only remove pane views that are NOT in the current tree.
        // This preserves existing terminal sessions (ghostty surfaces).
        let activePaneIDs = Set(root.allPaneIDs())
        let stalePaneIDs = paneViews.keys.filter { !activePaneIDs.contains($0) }
        for id in stalePaneIDs {
            paneViews[id]?.removeFromSuperview()
            paneViews.removeValue(forKey: id)
        }

        // Dividers change with tree structure -- recreate them
        for (_, dividerView) in dividerViews {
            dividerView.removeFromSuperview()
        }
        dividerViews.removeAll()

        // Create views for new panes and new dividers
        ensureViewsForNode(root)

        needsLayout = true
    }

    /// Clean up cached pane views when a session is deleted.
    func clearCachedPanes(forSessionID sessionID: UUID) {
        if let cached = sessionPaneCache.removeValue(forKey: sessionID) {
            for (_, paneView) in cached {
                paneView.removeFromSuperview()
            }
        }
    }

    /// Recursively ensure that views exist for every node in the tree.
    private func ensureViewsForNode(_ node: SplitNode) {
        switch node {
        case .leaf(let id):
            if paneViews[id] == nil {
                let pane = createPane(id: id)
                addSubview(pane)
            } else if paneViews[id]?.superview != self {
                addSubview(paneViews[id]!)
            }
        case .split(let container):
            if dividerViews[container.id] == nil {
                let divider = DividerView(splitNodeID: container.id, direction: container.direction)
                divider.delegate = self
                dividerViews[container.id] = divider
                addSubview(divider)
            } else {
                dividerViews[container.id]?.direction = container.direction
            }
            ensureViewsForNode(container.first)
            ensureViewsForNode(container.second)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let tree = splitTree, let root = tree.root else { return }

        // If a pane is zoomed, give it the full bounds
        if let zoomedID = tree.zoomedPaneID, let zoomedView = paneViews[zoomedID] {
            for (id, paneView) in paneViews {
                paneView.isHidden = (id != zoomedID)
            }
            for (_, dividerView) in dividerViews {
                dividerView.isHidden = true
            }
            zoomedView.frame = bounds
            return
        }

        // Normal layout
        for (_, paneView) in paneViews {
            paneView.isHidden = false
        }
        for (_, dividerView) in dividerViews {
            dividerView.isHidden = false
        }

        ensureViewsForNode(root)
        cleanUpStaleViews(root)
        layoutNode(root, in: bounds)
    }

    private func layoutNode(_ node: SplitNode, in rect: CGRect) {
        switch node {
        case .leaf(let id):
            if let paneView = paneViews[id] {
                paneView.frame = rect
            }

        case .split(let container):
            let dividerThickness = DividerView.hitTargetThickness
            let ratio = CGFloat(container.ratio)

            let firstRect: CGRect
            let secondRect: CGRect
            let dividerRect: CGRect

            switch container.direction {
            case .vertical:
                let availableWidth = rect.width - dividerThickness
                let firstWidth = floor(availableWidth * ratio)
                let secondWidth = availableWidth - firstWidth

                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                dividerRect = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: dividerThickness, height: rect.height)
                secondRect = CGRect(x: rect.minX + firstWidth + dividerThickness, y: rect.minY, width: secondWidth, height: rect.height)

            case .horizontal:
                let availableHeight = rect.height - dividerThickness
                let firstHeight = floor(availableHeight * ratio)
                let secondHeight = availableHeight - firstHeight

                firstRect = CGRect(x: rect.minX, y: rect.minY + secondHeight + dividerThickness, width: rect.width, height: firstHeight)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + secondHeight, width: rect.width, height: dividerThickness)
                secondRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: secondHeight)
            }

            if let dividerView = dividerViews[container.id] {
                dividerView.direction = container.direction
                dividerView.frame = dividerRect
                dividerView.needsDisplay = true
            }

            layoutNode(container.first, in: firstRect)
            layoutNode(container.second, in: secondRect)
        }
    }

    /// Remove views for panes and dividers that are no longer in the tree.
    private func cleanUpStaleViews(_ root: SplitNode) {
        let activePaneIDs = Set(root.allPaneIDs())
        let activeSplitIDs = collectSplitIDs(root)

        let stalePaneIDs = paneViews.keys.filter { !activePaneIDs.contains($0) }
        for id in stalePaneIDs {
            paneViews[id]?.removeFromSuperview()
            paneViews.removeValue(forKey: id)
        }

        let staleDividerIDs = dividerViews.keys.filter { !activeSplitIDs.contains($0) }
        for id in staleDividerIDs {
            dividerViews[id]?.removeFromSuperview()
            dividerViews.removeValue(forKey: id)
        }
    }

    private func collectSplitIDs(_ node: SplitNode) -> Set<UUID> {
        switch node {
        case .leaf:
            return []
        case .split(let container):
            var ids: Set<UUID> = [container.id]
            ids.formUnion(collectSplitIDs(container.first))
            ids.formUnion(collectSplitIDs(container.second))
            return ids
        }
    }

    // MARK: - Pane management

    func createPane(id: UUID) -> TerminalPane {
        print("[SplitContainer] CREATE pane \(String(id.uuidString.prefix(4)))")
        let initialInput = pendingInitialInputs.removeValue(forKey: id)
        let pane = TerminalPane(paneID: id, initialInput: initialInput)
        pane.isFocused = (id == focusedPaneID)
        pane.delegate = self
        paneViews[id] = pane
        containerDelegate?.splitContainerView(self, didCreatePane: pane)
        return pane
    }

    /// Register text to be typed into the shell of a pane that has not yet
    /// been created. Must be called BEFORE `setSplitTree(_:forSessionID:)` /
    /// `displaySession(_:)` triggers `createPane(id:)` for this pane.
    func registerInitialInput(_ text: String, for paneID: UUID) {
        pendingInitialInputs[paneID] = text
    }

    func removePane(id: UUID) {
        if let paneView = paneViews[id] {
            print("[SplitContainer] REMOVE pane \(String(id.uuidString.prefix(4)))")
            // The ghostty surface is freed in GhosttyTerminalView's deinit
            // when the view is deallocated after being removed from the hierarchy.
            paneView.removeFromSuperview()
            paneViews.removeValue(forKey: id)
        }
    }

    func pane(for id: UUID) -> TerminalPane? {
        return paneViews[id]
    }

    /// Look up a pane in both active views and the session cache (for inactive sessions).
    func paneIncludingCache(for id: UUID) -> TerminalPane? {
        if let pane = paneViews[id] { return pane }
        for (_, cached) in sessionPaneCache {
            if let pane = cached[id] { return pane }
        }
        return nil
    }

    func swapPanes(source: UUID, target: UUID) {
        guard let sourceView = paneViews[source],
              let targetView = paneViews[target] else { return }

        let sourceFrame = sourceView.frame
        sourceView.frame = targetView.frame
        targetView.frame = sourceFrame

        paneViews[source] = targetView
        paneViews[target] = sourceView

        splitTree?.swapPanes(a: source, b: target)
        needsLayout = true
    }

    // MARK: - Focus

    private func updateFocusIndicators() {
        for (id, paneView) in paneViews {
            paneView.isFocused = (id == focusedPaneID)
        }
    }

    func focusPane(_ id: UUID) {
        focusedPaneID = id
        paneViews[id]?.focus()
    }

    /// Iterate all active panes and feed their shell PIDs to the agent manager.
    func updateAgentManagerMappings() {
        guard let agentManager = agentManager,
              let sessionID = currentSessionID else { return }
        var entries: [AgentManager.ShellEntry] = []

        for (paneID, pane) in paneViews {
            // Feed all tab shell PIDs, not just the active one
            let tabPIDs = pane.allShellPIDs
            if tabPIDs.isEmpty {
                // Fallback: use the pane's single shellProcessID
                if let pid = pane.shellProcessID {
                    entries.append(.init(paneID: paneID, tabID: nil, sessionID: sessionID, shellPid: pid))
                }
            } else {
                for (tabID, pid) in tabPIDs {
                    entries.append(.init(paneID: paneID, tabID: tabID, sessionID: sessionID, shellPid: pid))
                }
            }
        }
        // Also update cached (inactive) session panes
        for (cachedSessionID, cachedPanes) in sessionPaneCache {
            guard cachedSessionID != currentSessionID else { continue }
            for (paneID, pane) in cachedPanes {
                let tabPIDs = pane.allShellPIDs
                if tabPIDs.isEmpty {
                    if let pid = pane.shellProcessID {
                        entries.append(.init(paneID: paneID, tabID: nil, sessionID: cachedSessionID, shellPid: pid))
                    }
                } else {
                    for (tabID, pid) in tabPIDs {
                        entries.append(.init(paneID: paneID, tabID: tabID, sessionID: cachedSessionID, shellPid: pid))
                    }
                }
            }
        }
        agentManager.shellEntries = entries
    }

    // MARK: - Dimension for divider drag

    private func containerDimension(for splitNodeID: UUID) -> CGFloat {
        guard let root = splitTree?.root else { return 1 }
        return dimensionForNode(root, splitNodeID: splitNodeID, in: bounds)
    }

    private func dimensionForNode(_ node: SplitNode, splitNodeID: UUID, in rect: CGRect) -> CGFloat {
        switch node {
        case .leaf:
            return 0
        case .split(let container):
            if container.id == splitNodeID {
                switch container.direction {
                case .vertical: return rect.width
                case .horizontal: return rect.height
                }
            }
            let dividerThickness = DividerView.hitTargetThickness
            let ratio = CGFloat(container.ratio)

            let firstRect: CGRect
            let secondRect: CGRect

            switch container.direction {
            case .vertical:
                let availableWidth = rect.width - dividerThickness
                let firstWidth = floor(availableWidth * ratio)
                let secondWidth = availableWidth - firstWidth
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                secondRect = CGRect(x: rect.minX + firstWidth + dividerThickness, y: rect.minY, width: secondWidth, height: rect.height)
            case .horizontal:
                let availableHeight = rect.height - dividerThickness
                let firstHeight = floor(availableHeight * ratio)
                let secondHeight = availableHeight - firstHeight
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
                secondRect = CGRect(x: rect.minX, y: rect.minY + firstHeight + dividerThickness, width: rect.width, height: secondHeight)
            }

            let r1 = dimensionForNode(container.first, splitNodeID: splitNodeID, in: firstRect)
            if r1 > 0 { return r1 }
            return dimensionForNode(container.second, splitNodeID: splitNodeID, in: secondRect)
        }
    }
}

// MARK: - DividerViewDelegate

extension SplitContainerView: DividerViewDelegate {
    func dividerView(_ divider: DividerView, didDragBy delta: CGFloat) {
        guard splitTree?.root != nil else { return }
        let dimension = containerDimension(for: divider.splitNodeID)
        guard dimension > 0 else { return }

        let ratioDelta = Double(delta / dimension)

        if var mutableRoot = splitTree?.root {
            adjustRatio(in: &mutableRoot, splitNodeID: divider.splitNodeID, delta: ratioDelta)
            splitTree?.root = mutableRoot
        }

        needsLayout = true
    }

    func dividerViewDidFinishDrag(_ divider: DividerView) {
        // Layout already updated during drag
    }

    private func adjustRatio(in node: inout SplitNode, splitNodeID: UUID, delta: Double) {
        switch node {
        case .leaf:
            return
        case .split(var container):
            if container.id == splitNodeID {
                let newRatio = min(0.9, max(0.1, container.ratio + delta))
                container.ratio = newRatio
                node = .split(container)
                return
            }
            adjustRatio(in: &container.first, splitNodeID: splitNodeID, delta: delta)
            adjustRatio(in: &container.second, splitNodeID: splitNodeID, delta: delta)
            node = .split(container)
        }
    }
}

// MARK: - TerminalPaneDelegate

extension SplitContainerView: TerminalPaneDelegate {
    func terminalPane(_ pane: TerminalPane, didUpdateTitle title: String) {
        // Could update sidebar or window title
    }

    func terminalPane(_ pane: TerminalPane, didUpdateCurrentDirectory directory: String?) {
        // Could be used for new pane creation in same directory
    }

    func terminalPaneProcessTerminated(_ pane: TerminalPane, exitCode: Int32?) {
        containerDelegate?.splitContainerView(self, paneProcessTerminated: pane)
    }

    func terminalPaneBell(_ pane: TerminalPane) {
        // Could flash the pane border or show activity in sidebar
    }

    func terminalPaneDidGainFocus(_ pane: TerminalPane) {
        focusedPaneID = pane.paneID
        containerDelegate?.splitContainerView(self, paneFocused: pane)
    }

    // MARK: - Tab Drag & Drop

    func terminalPane(_ pane: TerminalPane, didReceiveTabDrop info: TabDragInfo, atIndex index: Int) {
        // Exit zoom if active
        if splitTree?.zoomedPaneID != nil {
            splitTree?.zoomedPaneID = nil
        }

        // Same pane reorder
        if info.sourcePaneID == pane.paneID {
            guard let result = pane.extractTab(info.tabID) else { return }
            pane.insertTab(result.0, terminalView: result.1, at: index)
            return
        }

        // Cross-pane transfer
        guard let sourcePane = paneViews[info.sourcePaneID],
              let (tab, tv) = sourcePane.extractTab(info.tabID) else { return }
        pane.insertTab(tab, terminalView: tv, at: index)
    }

    func terminalPane(_ pane: TerminalPane, didReceiveEdgeDrop info: TabDragInfo, edge: DropEdge) {
        // Exit zoom if active
        if splitTree?.zoomedPaneID != nil {
            splitTree?.zoomedPaneID = nil
        }

        guard let sourcePane = paneViews[info.sourcePaneID],
              let (tab, tv) = sourcePane.extractTab(info.tabID) else { return }

        let direction: SplitDirection
        let position: SplitPosition
        switch edge {
        case .left:
            direction = .vertical
            position = .first
        case .right:
            direction = .vertical
            position = .second
        case .top:
            direction = .horizontal
            position = .first
        case .bottom:
            direction = .horizontal
            position = .second
        }

        guard let (_, newPaneID) = splitTree?.insert(
            splitting: pane.paneID,
            direction: direction,
            position: position
        ) else { return }

        // Create a new empty pane and insert the dragged tab into it
        let newPane = TerminalPane(paneID: newPaneID, skipInitialTab: true)
        newPane.isFocused = false
        newPane.delegate = self
        paneViews[newPaneID] = newPane
        addSubview(newPane)
        containerDelegate?.splitContainerView(self, didCreatePane: newPane)

        newPane.insertTab(tab, terminalView: tv, at: 0)

        if let sessionID = currentSessionID, let tree = splitTree {
            setSplitTree(tree, forSessionID: sessionID)
        }
        focusPane(newPaneID)
    }

    func terminalPaneDidBecomeEmpty(_ pane: TerminalPane) {
        let paneID = pane.paneID
        guard splitTree?.remove(paneID: paneID) != nil || splitTree?.root == nil else { return }

        pane.removeFromSuperview()
        paneViews.removeValue(forKey: paneID)

        if let sessionID = currentSessionID, let tree = splitTree {
            setSplitTree(tree, forSessionID: sessionID)
        }

        // Focus another pane if available
        if let firstID = splitTree?.allPaneIDs().first {
            focusPane(firstID)
        }
    }

    func terminalPane(_ pane: TerminalPane, canAcceptDrop info: TabDragInfo) -> Bool {
        // Reject if this is the only pane with only 1 tab
        if info.sourcePaneID == pane.paneID && pane.tabCount <= 1 {
            return false
        }
        // Reject if source pane has only 1 tab and only 1 pane in tree
        if let sourcePane = paneViews[info.sourcePaneID],
           sourcePane.tabCount <= 1,
           (splitTree?.allPaneIDs().count ?? 0) <= 1 {
            return false
        }
        return true
    }
}
