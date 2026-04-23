import AppKit

protocol SidebarViewDelegate: AnyObject {
    // Sessions (called from within projects panel)
    func sidebarDidSelectSession(_ session: Session)
    func sidebarDidRequestNewSession()
    func sidebarDidRequestDeleteSession(_ session: Session)
    func sidebarDidRequestRenameSession(_ session: Session)
    // Current directory
    func sidebarCurrentDirectory() -> String?
    // File tree
    func sidebarDidSelectFile(path: String)
    // Agents
    func sidebarDidRequestFocusAgentPane(paneID: UUID, tabID: UUID?, sessionID: UUID)
    func sidebarDidRequestSendInterrupt(agent: AgentInstance)
    func sidebarDidRequestKillAgent(agent: AgentInstance)
    // Projects
    func sidebarDidSelectProject(_ project: Project)
    func sidebarDidRequestAddProject()
    func sidebarDidRequestDeleteProject(_ project: Project)
    func sidebarDidRequestRenameProject(_ project: Project)
    func sidebarDidRequestOpenProjectFolder(_ project: Project)
}

enum SidebarMode {
    case projects
    case agents
    case fileTree
}

class SidebarView: NSView {
    weak var delegate: SidebarViewDelegate?
    private var sessionManager: SessionManager!

    private var separatorLine: NSView!

    // Glass background (vibrancy)
    private var glassView: GlassBackgroundView?

    // Icon tab bar
    private var iconBar: NSView!
    private var iconBarSeparator: NSView!

    // File tree
    private var fileTreeView: FileTreeView!
    private var fileTreeButton: DimIconButton!

    // Agents
    private var agentsButton: DimIconButton!
    private var agentListView: AgentListView!
    private var agentsBadge: NSView!
    private var agentManager: AgentManager!

    // Projects
    private var projectsButton: DimIconButton!
    private var projectListView: ProjectListView!
    private var projectManager: ProjectManager!

    private(set) var mode: SidebarMode = .projects

    init(sessionManager: SessionManager, agentManager: AgentManager, projectManager: ProjectManager)
    {
        self.sessionManager = sessionManager
        self.agentManager = agentManager
        self.projectManager = projectManager
        super.init(frame: .zero)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(attentionCountDidChange),
            name: AgentManager.attentionCountDidChangeNotification, object: nil
        )
        attentionCountDidChange()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        applyGlassOrSolid()
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        projectsButton.isActiveState = mode == .projects
        agentsButton.isActiveState = mode == .agents
        fileTreeButton.isActiveState = mode == .fileTree
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    /// Temporarily hide/show the glass backdrop (used during sidebar slide animations
    /// to prevent the NSVisualEffectView blur from creating a trailing shadow artifact).
    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy {
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

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        setupIconBar()
        setupFileTree()
        setupAgentListView()
        setupProjectListView()
        setupSeparatorLine()
        setupConstraints()
        applyGlassOrSolid()
        setMode(.projects)
    }

    private func setupIconBar() {
        iconBar = NSView()
        iconBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBar)

        projectsButton = makeIconBarButton(
            symbolName: "square.stack.3d.up", action: #selector(projectsButtonClicked))
        projectsButton.isActiveState = true
        projectsButton.toolTip = "Projects"
        iconBar.addSubview(projectsButton)

        agentsButton = makeIconBarButton(
            symbolName: "command.square", action: #selector(agentsButtonClicked))
        agentsButton.toolTip = "Agents"
        iconBar.addSubview(agentsButton)

        fileTreeButton = makeIconBarButton(
            symbolName: "folder", action: #selector(fileTreeButtonClicked))
        fileTreeButton.toolTip = "Files"
        iconBar.addSubview(fileTreeButton)

        agentsBadge = NSView()
        agentsBadge.translatesAutoresizingMaskIntoConstraints = false
        agentsBadge.wantsLayer = true
        agentsBadge.layer?.backgroundColor =
            NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0).cgColor
        agentsBadge.layer?.cornerRadius = 4
        agentsBadge.isHidden = true
        iconBar.addSubview(agentsBadge)

        NSLayoutConstraint.activate([
            projectsButton.leadingAnchor.constraint(equalTo: iconBar.leadingAnchor, constant: 14),
            projectsButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            projectsButton.widthAnchor.constraint(equalToConstant: 24),
            projectsButton.heightAnchor.constraint(equalToConstant: 24),

            agentsButton.leadingAnchor.constraint(
                equalTo: projectsButton.trailingAnchor, constant: 6),
            agentsButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            agentsButton.widthAnchor.constraint(equalToConstant: 24),
            agentsButton.heightAnchor.constraint(equalToConstant: 24),

            fileTreeButton.leadingAnchor.constraint(
                equalTo: agentsButton.trailingAnchor, constant: 6),
            fileTreeButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            fileTreeButton.widthAnchor.constraint(equalToConstant: 24),
            fileTreeButton.heightAnchor.constraint(equalToConstant: 24),

            agentsBadge.widthAnchor.constraint(equalToConstant: 8),
            agentsBadge.heightAnchor.constraint(equalToConstant: 8),
            agentsBadge.topAnchor.constraint(equalTo: agentsButton.topAnchor, constant: -1),
            agentsBadge.trailingAnchor.constraint(
                equalTo: agentsButton.trailingAnchor, constant: 3),
        ])

        iconBarSeparator = NSView()
        iconBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        iconBarSeparator.wantsLayer = true
        iconBarSeparator.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(iconBarSeparator)
    }

    private func makeIconBarButton(symbolName: String, action: Selector) -> DimIconButton {
        let button = DimIconButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: symbolName
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.refreshDimState()
        return button
    }

    private func setupFileTree() {
        fileTreeView = FileTreeView(frame: .zero)
        fileTreeView.translatesAutoresizingMaskIntoConstraints = false
        fileTreeView.isHidden = true
        fileTreeView.delegate = self
        addSubview(fileTreeView)
    }

    private func setupAgentListView() {
        agentListView = AgentListView(
            agentManager: agentManager, sessionManager: sessionManager,
            projectManager: projectManager)
        agentListView.translatesAutoresizingMaskIntoConstraints = false
        agentListView.isHidden = true
        agentListView.delegate = self
        addSubview(agentListView)
    }

    private func setupProjectListView() {
        projectListView = ProjectListView(
            projectManager: projectManager, sessionManager: sessionManager)
        projectListView.translatesAutoresizingMaskIntoConstraints = false
        projectListView.isHidden = true
        projectListView.delegate = self
        addSubview(projectListView)
    }

    private func setupSeparatorLine() {
        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)
    }

    private func setupConstraints() {
        let contentTrailing = separatorLine.leadingAnchor

        NSLayoutConstraint.activate([
            // Icon bar below titlebar
            iconBar.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            iconBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconBar.trailingAnchor.constraint(equalTo: contentTrailing),
            iconBar.heightAnchor.constraint(equalToConstant: 30),

            iconBarSeparator.topAnchor.constraint(equalTo: iconBar.bottomAnchor),
            iconBarSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconBarSeparator.trailingAnchor.constraint(equalTo: contentTrailing, constant: -12),
            iconBarSeparator.heightAnchor.constraint(equalToConstant: 1),

            // File tree (toggled via isHidden)
            fileTreeView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            fileTreeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileTreeView.trailingAnchor.constraint(equalTo: contentTrailing),
            fileTreeView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Agent list view (toggled via isHidden)
            agentListView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            agentListView.leadingAnchor.constraint(equalTo: leadingAnchor),
            agentListView.trailingAnchor.constraint(equalTo: contentTrailing),
            agentListView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Project list view (toggled via isHidden)
            projectListView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            projectListView.leadingAnchor.constraint(equalTo: leadingAnchor),
            projectListView.trailingAnchor.constraint(equalTo: contentTrailing),
            projectListView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Right edge separator
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Mode Switching

    @objc private func fileTreeButtonClicked() { setMode(.fileTree) }
    @objc private func agentsButtonClicked() { setMode(.agents) }
    @objc private func projectsButtonClicked() { setMode(.projects) }

    @objc private func attentionCountDidChange() {
        let count = agentManager.attentionCount
        agentsBadge.isHidden = count == 0
    }

    private func setMode(_ newMode: SidebarMode) {
        mode = newMode
        projectsButton.isActiveState = mode == .projects
        agentsButton.isActiveState = mode == .agents
        fileTreeButton.isActiveState = mode == .fileTree

        projectListView.isHidden = mode != .projects
        agentListView.isHidden = mode != .agents
        fileTreeView.isHidden = mode != .fileTree

        if mode == .fileTree {
            fileTreeView.setRootPath(delegate?.sidebarCurrentDirectory())
        } else if mode == .projects {
            projectListView.reloadProjects()
        }
    }

    // MARK: - Public API

    /// Called externally when the active pane changes or its pwd updates.
    func updateFileTreePath(_ path: String?) {
        guard mode == .fileTree else { return }
        fileTreeView.setRootPath(path)
    }

    func reloadSessions() {
        if mode == .projects {
            projectListView.reloadSessions()
        }
    }

    func reloadProjects() {
        if mode == .projects {
            projectListView.reloadProjects()
        }
    }
}

// MARK: - FileTreeViewDelegate

extension SidebarView: FileTreeViewDelegate {
    func fileTreeView(_ view: FileTreeView, didSelectFileAt path: String) {
        delegate?.sidebarDidSelectFile(path: path)
    }
}

// MARK: - AgentListViewDelegate

extension SidebarView: AgentListViewDelegate {
    func agentListDidRequestFocusPane(paneID: UUID, tabID: UUID?, sessionID: UUID) {
        delegate?.sidebarDidRequestFocusAgentPane(
            paneID: paneID, tabID: tabID, sessionID: sessionID)
    }
    func agentListDidRequestSendInterrupt(agent: AgentInstance) {
        delegate?.sidebarDidRequestSendInterrupt(agent: agent)
    }
    func agentListDidRequestKillAgent(agent: AgentInstance) {
        delegate?.sidebarDidRequestKillAgent(agent: agent)
    }
}

// MARK: - ProjectListViewDelegate

extension SidebarView: ProjectListViewDelegate {
    func projectListDidSelectProject(_ project: Project) {
        delegate?.sidebarDidSelectProject(project)
    }
    func projectListDidRequestAddProject() {
        delegate?.sidebarDidRequestAddProject()
    }
    func projectListDidRequestDeleteProject(_ project: Project) {
        delegate?.sidebarDidRequestDeleteProject(project)
    }
    func projectListDidRequestRenameProject(_ project: Project) {
        delegate?.sidebarDidRequestRenameProject(project)
    }
    func projectListDidRequestOpenFolder(_ project: Project) {
        delegate?.sidebarDidRequestOpenProjectFolder(project)
    }

}
