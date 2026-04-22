import AppKit

// MARK: - Delegate

protocol RunnerPanelViewDelegate: AnyObject {
    /// Called when the user taps "Open in pane" for a running task.
    func runnerPanelDidRequestOpenInPane(command: String, cwd: String)
}

// MARK: - Runner Panel View
//
// Right-side panel that lists user-defined tasks for the active worktree and
// will later host run/stop controls and a log viewer. This skeleton only
// establishes the glass/solid chrome and empty-state label. List + log are
// added in later tasks.

final class RunnerPanelView: NSView {
    weak var delegate: RunnerPanelViewDelegate?

    /// Distance from the view's top to the first content row. Matches the
    /// convention used by GitPanelView / EditorSidebarView so the parent can
    /// slot this view under a shared header.
    var topContentInset: CGFloat = 10 {
        didSet { topInsetConstraint?.constant = topContentInset }
    }

    /// Hide glass when wrapped inside a parent that already draws chrome.
    var chromeHidden: Bool = false {
        didSet {
            if chromeHidden { glassView?.isHidden = true }
            applyGlassOrSolid()
        }
    }

    private(set) var store: RunnerTaskStore?
    private let runner = TaskRunner()

    private var glassView: GlassBackgroundView?
    private var emptyLabel: NSTextField!
    private var topInsetConstraint: NSLayoutConstraint?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    /// Hide glass layer during sidebar slide animations so blur artifacts don't linger.
    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    /// Bind the panel to a worktree (or clear it). Rebuilds the store when the
    /// path changes and refreshes the empty-state message.
    func setWorktree(_ path: String?) {
        if let p = path {
            if store?.worktreePath != p {
                store = RunnerTaskStore(worktreePath: p)
                store?.reload()
            }
        } else {
            store = nil
        }
        refreshEmptyState()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        emptyLabel = NSTextField(labelWithString: "Open a worktree to run tasks.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.backgroundColor = .clear
        addSubview(emptyLabel)

        let topC = emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)
        topInsetConstraint = topC
        NSLayoutConstraint.activate([
            topC,
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        applyGlassOrSolid()
        refreshEmptyState()
    }

    private func refreshEmptyState() {
        if store == nil {
            emptyLabel.stringValue = "Open a worktree to run tasks."
            emptyLabel.isHidden = false
        } else if store?.tasks.isEmpty == true {
            emptyLabel.stringValue = "No tasks detected. Tap + to add one, or create .amux/tasks.json."
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    // MARK: - Glass

    private func applyGlassOrSolid() {
        if Theme.useVibrancy && !chromeHidden {
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
        emptyLabel?.textColor = Theme.tertiaryText
        emptyLabel?.font = Theme.Fonts.body(size: 12)
    }
}
