import AppKit

// MARK: - Delegate Protocol

protocol AgentListViewDelegate: AnyObject {
    func agentListDidRequestFocusPane(paneID: UUID, sessionID: UUID)
    func agentListDidRequestSendInterrupt(agent: AgentInstance)
    func agentListDidRequestKillAgent(agent: AgentInstance)
}

// MARK: - Data Model

struct SessionGroup {
    let sessionID: UUID
    let sessionName: String
    var typeGroups: [TypeGroup]
}

struct TypeGroup {
    let type: AgentType
    var agents: [AgentInstance]
}

// MARK: - AgentListView

class AgentListView: NSView {
    weak var delegate: AgentListViewDelegate?
    private let agentManager: AgentManager
    private let sessionManager: SessionManager
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var sessionGroups: [SessionGroup] = []
    // Cached wrappers for stable NSOutlineView identity (prevents collapse on reload)
    private var cachedSessionWrappers: [SessionGroupWrapper] = []

    private static let sessionGroupCellID = NSUserInterfaceItemIdentifier("SessionGroupCell")
    private static let typeGroupCellID = NSUserInterfaceItemIdentifier("TypeGroupCell")
    private static let agentCellID = NSUserInterfaceItemIdentifier("AgentCell")

    init(agentManager: AgentManager, sessionManager: SessionManager) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        super.init(frame: .zero)
        setupUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(agentsDidChange),
            name: AgentManager.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )

        rebuildData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Notifications

    @objc private func agentsDidChange() {
        rebuildData()
    }

    @objc private func themeDidChange() {
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        outlineView.reloadData()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        // Empty state label
        emptyLabel = NSTextField(labelWithString: "No agents running")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.backgroundColor = .clear
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Outline view
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.selectionHighlightStyle = .none
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.backgroundColor = .clear
        outlineView.action = #selector(outlineRowClicked)
        outlineView.target = self
        outlineView.menu = createContextMenu()
        outlineView.indentationPerLevel = 0

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AgentColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // Scroll view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScroller = ThinScroller()
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Data

    private func rebuildData() {
        var groups: [UUID: SessionGroup] = [:]
        for agent in agentManager.allAgents {
            if groups[agent.sessionID] == nil {
                let name = sessionManager.sessions.first(where: { $0.id == agent.sessionID })?.name ?? "Unknown"
                groups[agent.sessionID] = SessionGroup(sessionID: agent.sessionID, sessionName: name, typeGroups: [])
            }
            var group = groups[agent.sessionID]!
            if let idx = group.typeGroups.firstIndex(where: { $0.type == agent.agentType }) {
                group.typeGroups[idx].agents.append(agent)
            } else {
                group.typeGroups.append(TypeGroup(type: agent.agentType, agents: [agent]))
            }
            groups[agent.sessionID] = group
        }
        sessionGroups = Array(groups.values).sorted { $0.sessionName < $1.sessionName }

        // Build stable wrappers -- reuse existing ones by session ID to preserve
        // NSOutlineView expand/collapse state (it uses object identity)
        let oldWrappersBySession = Dictionary(
            uniqueKeysWithValues: cachedSessionWrappers.map { ($0.group.sessionID, $0) }
        )
        var newWrappers: [SessionGroupWrapper] = []
        for group in sessionGroups {
            let sessionWrapper: SessionGroupWrapper
            if let existing = oldWrappersBySession[group.sessionID] {
                existing.group = group
                sessionWrapper = existing
            } else {
                sessionWrapper = SessionGroupWrapper(group: group, typeGroupWrappers: [])
            }
            // Rebuild type group wrappers, reusing by type
            let oldTypeByType = Dictionary(
                uniqueKeysWithValues: sessionWrapper.typeGroupWrappers.map { ($0.typeGroup.type, $0) }
            )
            var newTypeWrappers: [TypeGroupWrapper] = []
            for tg in group.typeGroups {
                let typeWrapper: TypeGroupWrapper
                if let existing = oldTypeByType[tg.type] {
                    existing.typeGroup = tg
                    existing.agentWrappers = tg.agents.map { AgentWrapper(agent: $0) }
                    typeWrapper = existing
                } else {
                    typeWrapper = TypeGroupWrapper(
                        typeGroup: tg,
                        parentSessionID: group.sessionID,
                        agentWrappers: tg.agents.map { AgentWrapper(agent: $0) }
                    )
                }
                newTypeWrappers.append(typeWrapper)
            }
            sessionWrapper.typeGroupWrappers = newTypeWrappers
            newWrappers.append(sessionWrapper)
        }
        cachedSessionWrappers = newWrappers

        outlineView.reloadData()
        // Expand all new groups (existing ones retain their state via identity)
        for wrapper in cachedSessionWrappers {
            if !outlineView.isItemExpanded(wrapper) {
                outlineView.expandItem(wrapper, expandChildren: true)
            }
        }
        emptyLabel.isHidden = !sessionGroups.isEmpty
        scrollView.isHidden = sessionGroups.isEmpty
    }

    // MARK: - Actions

    @objc private func outlineRowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let wrapper = item as? AgentWrapper {
            delegate?.agentListDidRequestFocusPane(
                paneID: wrapper.agent.paneID,
                sessionID: wrapper.agent.sessionID
            )
        }
    }

    // MARK: - Context Menu

    private func createContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func focusPaneClicked(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? AgentInstance else { return }
        delegate?.agentListDidRequestFocusPane(paneID: agent.paneID, sessionID: agent.sessionID)
    }

    @objc private func sendInterruptClicked(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? AgentInstance else { return }
        delegate?.agentListDidRequestSendInterrupt(agent: agent)
    }

    @objc private func killAgentClicked(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? AgentInstance else { return }
        delegate?.agentListDidRequestKillAgent(agent: agent)
    }
}

// MARK: - Wrapper classes for outline items

// NSOutlineView needs reference-type items for identity tracking.
private class SessionGroupWrapper {
    var group: SessionGroup
    var typeGroupWrappers: [TypeGroupWrapper]

    init(group: SessionGroup, typeGroupWrappers: [TypeGroupWrapper]) {
        self.group = group
        self.typeGroupWrappers = typeGroupWrappers
    }
}

private class TypeGroupWrapper {
    var typeGroup: TypeGroup
    let parentSessionID: UUID
    var agentWrappers: [AgentWrapper]

    init(typeGroup: TypeGroup, parentSessionID: UUID, agentWrappers: [AgentWrapper]) {
        self.typeGroup = typeGroup
        self.parentSessionID = parentSessionID
        self.agentWrappers = agentWrappers
    }
}

private class AgentWrapper {
    let agent: AgentInstance

    init(agent: AgentInstance) {
        self.agent = agent
    }
}

// MARK: - NSOutlineViewDataSource

extension AgentListView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sessionGroups.count
        }
        if let wrapper = item as? SessionGroupWrapper {
            return wrapper.typeGroupWrappers.count
        }
        if let wrapper = item as? TypeGroupWrapper {
            return wrapper.agentWrappers.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return cachedSessionWrappers[index]
        }
        if let wrapper = item as? SessionGroupWrapper {
            return wrapper.typeGroupWrappers[index]
        }
        if let wrapper = item as? TypeGroupWrapper {
            return wrapper.agentWrappers[index]
        }
        fatalError("Unexpected outline item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is SessionGroupWrapper || item is TypeGroupWrapper
    }
}

// MARK: - NSOutlineViewDelegate

extension AgentListView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let wrapper = item as? SessionGroupWrapper {
            var cell = outlineView.makeView(
                withIdentifier: Self.sessionGroupCellID, owner: self
            ) as? SessionGroupHeaderCell
            if cell == nil {
                cell = SessionGroupHeaderCell()
                cell?.identifier = Self.sessionGroupCellID
            }
            cell?.configure(name: wrapper.group.sessionName)
            return cell
        }
        if let wrapper = item as? TypeGroupWrapper {
            var cell = outlineView.makeView(
                withIdentifier: Self.typeGroupCellID, owner: self
            ) as? TypeGroupHeaderCell
            if cell == nil {
                cell = TypeGroupHeaderCell()
                cell?.identifier = Self.typeGroupCellID
            }
            cell?.configure(type: wrapper.typeGroup.type)
            return cell
        }
        if let wrapper = item as? AgentWrapper {
            var cell = outlineView.makeView(
                withIdentifier: Self.agentCellID, owner: self
            ) as? AgentCellView
            if cell == nil {
                cell = AgentCellView()
                cell?.identifier = Self.agentCellID
            }
            cell?.configure(agent: wrapper.agent)
            return cell
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is AgentWrapper {
            return 44
        }
        return 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = false
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return false
    }
}

// MARK: - NSMenuDelegate

extension AgentListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        guard let wrapper = item as? AgentWrapper else { return }
        let agent = wrapper.agent

        let focusItem = NSMenuItem(
            title: "Focus Pane",
            action: #selector(focusPaneClicked(_:)),
            keyEquivalent: ""
        )
        focusItem.target = self
        focusItem.representedObject = agent
        menu.addItem(focusItem)

        menu.addItem(NSMenuItem.separator())

        let interruptItem = NSMenuItem(
            title: "Send Interrupt (^C)",
            action: #selector(sendInterruptClicked(_:)),
            keyEquivalent: ""
        )
        interruptItem.target = self
        interruptItem.representedObject = agent
        menu.addItem(interruptItem)

        let killItem = NSMenuItem(
            title: "Kill Agent",
            action: #selector(killAgentClicked(_:)),
            keyEquivalent: ""
        )
        killItem.target = self
        killItem.representedObject = agent
        menu.addItem(killItem)
    }
}

// MARK: - Session Group Header Cell

private class SessionGroupHeaderCell: NSView {
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Theme.Fonts.headline(size: 11)
        nameLabel.textColor = Theme.primaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(name: String) {
        nameLabel.stringValue = name
        nameLabel.font = Theme.Fonts.headline(size: 11)
        nameLabel.textColor = Theme.primaryText
    }
}

// MARK: - Type Group Header Cell

private class TypeGroupHeaderCell: NSView {
    private let typeLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        typeLabel.font = Theme.Fonts.label(size: 10)
        typeLabel.textColor = Theme.tertiaryText
        typeLabel.backgroundColor = .clear
        typeLabel.isBezeled = false
        typeLabel.isEditable = false
        typeLabel.isSelectable = false
        typeLabel.lineBreakMode = .byTruncatingTail
        typeLabel.maximumNumberOfLines = 1
        addSubview(typeLabel)

        NSLayoutConstraint.activate([
            typeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            typeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            typeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(type: AgentType) {
        typeLabel.stringValue = type.displayName.uppercased()
        typeLabel.font = Theme.Fonts.label(size: 10)
        typeLabel.textColor = Theme.tertiaryText
    }
}

// MARK: - Agent Cell View

private class AgentCellView: NSView {
    private let highlightView = NSView()
    private let stateIndicator = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var attentionTintColor: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        wantsLayer = true

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.CornerRadius.element
        addSubview(highlightView)

        stateIndicator.translatesAutoresizingMaskIntoConstraints = false
        stateIndicator.wantsLayer = true
        stateIndicator.layer?.cornerRadius = 0
        addSubview(stateIndicator)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Theme.Fonts.body(size: 13)
        nameLabel.textColor = Theme.secondaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = Theme.Fonts.body(size: 11)
        durationLabel.textColor = Theme.tertiaryText
        durationLabel.backgroundColor = .clear
        durationLabel.isBezeled = false
        durationLabel.isEditable = false
        durationLabel.isSelectable = false
        durationLabel.alignment = .right
        durationLabel.maximumNumberOfLines = 1
        addSubview(durationLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Theme.Fonts.body(size: 11)
        subtitleLabel.textColor = Theme.tertiaryText
        subtitleLabel.backgroundColor = .clear
        subtitleLabel.isBezeled = false
        subtitleLabel.isEditable = false
        subtitleLabel.isSelectable = false
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            stateIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stateIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stateIndicator.widthAnchor.constraint(equalToConstant: 8),
            stateIndicator.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: stateIndicator.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: stateIndicator.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -8),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),

            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])

        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(agent: AgentInstance) {
        nameLabel.stringValue = agent.agentType.displayName
        nameLabel.font = Theme.Fonts.body(size: 13)
        nameLabel.textColor = Theme.secondaryText

        durationLabel.stringValue = agent.durationString
        durationLabel.font = Theme.Fonts.body(size: 11)
        durationLabel.textColor = Theme.tertiaryText

        let dotColor = stateColor(for: agent.state)
        stateIndicator.layer?.backgroundColor = dotColor.cgColor
        attentionTintColor = agent.state.isAttentionRequired ? dotColor : nil

        // Pulsing animation for attention-required states
        switch agent.state {
        case .needsInput, .needsPermission:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            stateIndicator.layer?.add(pulse, forKey: "pulse")
        default:
            stateIndicator.layer?.removeAnimation(forKey: "pulse")
        }

        // Subtitle
        switch agent.state {
        case .needsInput, .needsPermission:
            let warningColor: NSColor
            if agent.state == .needsPermission {
                warningColor = NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0)
            } else {
                warningColor = NSColor(srgbRed: 0.878, green: 0.706, blue: 0.278, alpha: 1.0)
            }
            subtitleLabel.stringValue = agent.notificationMessage ?? ""
            subtitleLabel.textColor = warningColor
        default:
            let dir = (agent.workingDirectory as NSString?)?.lastPathComponent ?? ""
            let paneShort = agent.paneID.uuidString.prefix(4)
            let tabShort = agent.tabID?.uuidString.prefix(4) ?? "0"
            subtitleLabel.stringValue = "\(dir)  [\(paneShort), \(tabShort)]"
            subtitleLabel.textColor = Theme.tertiaryText
        }

        updateBackground()
    }

    private func stateColor(for state: AgentState) -> NSColor {
        switch state {
        case .starting:
            return Theme.quaternaryText
        case .working:
            return NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)
        case .idle:
            return Theme.quaternaryText
        case .needsInput:
            return NSColor(srgbRed: 0.878, green: 0.706, blue: 0.278, alpha: 1.0)
        case .needsPermission:
            return NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0)
        case .exited:
            return Theme.quaternaryText.withAlphaComponent(0.4)
        }
    }

    private func updateBackground() {
        if isHovered {
            highlightView.layer?.backgroundColor = Theme.hoverBg.cgColor
        } else if let tint = attentionTintColor {
            highlightView.layer?.backgroundColor = tint.withAlphaComponent(0.1).cgColor
        } else {
            highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }
}
