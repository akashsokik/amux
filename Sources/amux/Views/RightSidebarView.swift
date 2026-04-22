import AppKit

// MARK: - Right sidebar (tabbed: Editor + Git)
//
// Mirrors the left `SidebarView` pattern: an icon bar at the top toggles
// between Editor and Git content below. A single toolbar button expands or
// collapses the whole container.

enum RightSidebarMode {
    case editor
    case git
    case runner
}

protocol RightSidebarViewDelegate: AnyObject {
    func rightSidebarDidRequestCollapse()
}

final class RightSidebarView: NSView {
    weak var delegate: RightSidebarViewDelegate?

    // Shared chrome
    private var glassView: GlassBackgroundView?
    private var separatorLine: NSView!
    private var iconBar: NSView!
    private var iconBarSeparator: NSView!

    // Tab buttons
    private var editorButton: DimIconButton!
    private var gitButton: DimIconButton!
    private var runnerButton: DimIconButton!
    private var collapseButton: DimIconButton!

    // Hosted children
    let editorSidebarView: EditorSidebarView
    let gitPanelView: GitPanelView
    let runnerPanelView: RunnerPanelView

    private(set) var mode: RightSidebarMode = .git

    // MARK: - Init

    init(
        editorSidebarView: EditorSidebarView,
        gitPanelView: GitPanelView,
        runnerPanelView: RunnerPanelView
    ) {
        self.editorSidebarView = editorSidebarView
        self.gitPanelView = gitPanelView
        self.runnerPanelView = runnerPanelView
        super.init(frame: .zero)
        setupUI()
        applyMode()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Glass

    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        editorSidebarView.setGlassHidden(hidden)
        gitPanelView.setGlassHidden(hidden)
        runnerPanelView.setGlassHidden(hidden)
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

    // MARK: - Theme

    @objc private func themeDidChange() {
        applyGlassOrSolid()
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        editorButton.refreshDimState()
        gitButton.refreshDimState()
        runnerButton.refreshDimState()
        collapseButton.refreshDimState()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        setupSeparator()
        setupIconBar()
        setupChildren()
        setupConstraints()
        applyGlassOrSolid()
    }

    private func setupSeparator() {
        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)
    }

    private func setupIconBar() {
        iconBar = NSView()
        iconBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBar)

        gitButton = makeIconBarButton(symbol: "arrow.triangle.branch", action: #selector(gitButtonClicked))
        gitButton.isActiveState = true
        iconBar.addSubview(gitButton)

        editorButton = makeIconBarButton(symbol: "chevron.left.forwardslash.chevron.right", action: #selector(editorButtonClicked))
        iconBar.addSubview(editorButton)

        runnerButton = makeIconBarButton(symbol: "play.circle", action: #selector(runnerButtonClicked))
        iconBar.addSubview(runnerButton)

        collapseButton = makeIconBarButton(symbol: "chevron.right.2", action: #selector(collapseClicked))
        collapseButton.toolTip = "Collapse sidebar"
        iconBar.addSubview(collapseButton)

        iconBarSeparator = NSView()
        iconBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        iconBarSeparator.wantsLayer = true
        iconBarSeparator.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(iconBarSeparator)
    }

    private func makeIconBarButton(symbol: String, action: Selector) -> DimIconButton {
        let button = DimIconButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: symbol
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

    private func setupChildren() {
        // Children no longer draw their own chrome or reserve top space —
        // the container owns the toolbar clearance + icon bar. Small internal
        // padding keeps their top row off the icon-bar separator.
        editorSidebarView.translatesAutoresizingMaskIntoConstraints = false
        editorSidebarView.topContentInset = 4
        editorSidebarView.chromeHidden = true
        addSubview(editorSidebarView)

        gitPanelView.translatesAutoresizingMaskIntoConstraints = false
        gitPanelView.topContentInset = 10
        gitPanelView.chromeHidden = true
        addSubview(gitPanelView)

        runnerPanelView.translatesAutoresizingMaskIntoConstraints = false
        runnerPanelView.topContentInset = 10
        runnerPanelView.chromeHidden = true
        addSubview(runnerPanelView)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Left-edge separator
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),

            // Icon bar below titlebar/toolbar
            iconBar.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            iconBar.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor),
            iconBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconBar.heightAnchor.constraint(equalToConstant: 30),

            gitButton.leadingAnchor.constraint(equalTo: iconBar.leadingAnchor, constant: 10),
            gitButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            gitButton.widthAnchor.constraint(equalToConstant: 24),
            gitButton.heightAnchor.constraint(equalToConstant: 24),

            editorButton.leadingAnchor.constraint(equalTo: gitButton.trailingAnchor, constant: 6),
            editorButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            editorButton.widthAnchor.constraint(equalToConstant: 24),
            editorButton.heightAnchor.constraint(equalToConstant: 24),

            runnerButton.leadingAnchor.constraint(equalTo: editorButton.trailingAnchor, constant: 6),
            runnerButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            runnerButton.widthAnchor.constraint(equalToConstant: 24),
            runnerButton.heightAnchor.constraint(equalToConstant: 24),

            collapseButton.trailingAnchor.constraint(equalTo: iconBar.trailingAnchor, constant: -10),
            collapseButton.centerYAnchor.constraint(equalTo: iconBar.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            iconBarSeparator.topAnchor.constraint(equalTo: iconBar.bottomAnchor),
            iconBarSeparator.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor, constant: 12),
            iconBarSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            iconBarSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Editor + Git share the content region below the icon bar.
            editorSidebarView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            editorSidebarView.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor),
            editorSidebarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorSidebarView.bottomAnchor.constraint(equalTo: bottomAnchor),

            gitPanelView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            gitPanelView.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor),
            gitPanelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gitPanelView.bottomAnchor.constraint(equalTo: bottomAnchor),

            runnerPanelView.topAnchor.constraint(equalTo: iconBarSeparator.bottomAnchor),
            runnerPanelView.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor),
            runnerPanelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            runnerPanelView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Mode

    func setMode(_ newMode: RightSidebarMode) {
        mode = newMode
        applyMode()
    }

    private func applyMode() {
        editorButton.isActiveState = (mode == .editor)
        gitButton.isActiveState = (mode == .git)
        runnerButton.isActiveState = (mode == .runner)
        editorSidebarView.isHidden = (mode != .editor)
        gitPanelView.isHidden = (mode != .git)
        runnerPanelView.isHidden = (mode != .runner)
    }

    @objc private func editorButtonClicked() { setMode(.editor) }
    @objc private func gitButtonClicked() { setMode(.git) }
    @objc private func runnerButtonClicked() { setMode(.runner) }
    @objc private func collapseClicked() { delegate?.rightSidebarDidRequestCollapse() }
}
