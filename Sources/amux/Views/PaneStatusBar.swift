import AppKit

class PaneStatusBar: NSView {
    private let processLabel = NSTextField(labelWithString: "")
    private let pathButton = NSButton()
    private let gitDirtyDot = NSView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let topBorder = NSView()

    static let barHeight: CGFloat = 22

    private var shellPid: pid_t?
    private var updateTimer: Timer?
    private var lastCwd: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        startPolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { updateTimer?.invalidate() }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.borderPrimary.cgColor
        addSubview(topBorder)

        // Process name
        configLabel(processLabel, font: font, color: dim)
        addSubview(processLabel)

        // Path (click to copy)
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathButton.title = ""
        pathButton.font = font
        pathButton.contentTintColor = Theme.tertiaryText
        pathButton.isBordered = false
        pathButton.bezelStyle = .accessoryBarAction
        pathButton.setButtonType(.momentaryChange)
        pathButton.target = self
        pathButton.action = #selector(copyPath)
        pathButton.alignment = .center
        if let cell = pathButton.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }
        addSubview(pathButton)

        // Git dirty dot
        gitDirtyDot.translatesAutoresizingMaskIntoConstraints = false
        gitDirtyDot.wantsLayer = true
        gitDirtyDot.layer?.cornerRadius = 2.5
        gitDirtyDot.layer?.backgroundColor = NSColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1.0).cgColor
        gitDirtyDot.isHidden = true
        addSubview(gitDirtyDot)

        // Branch icon
        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        branchIcon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Branch"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        branchIcon.contentTintColor = dim
        branchIcon.isHidden = true
        addSubview(branchIcon)

        // Branch name
        configLabel(branchLabel, font: font, color: dim)
        branchLabel.isHidden = true
        addSubview(branchLabel)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            processLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            processLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            processLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80),

            pathButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            pathButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathButton.leadingAnchor.constraint(greaterThanOrEqualTo: processLabel.trailingAnchor, constant: 12),
            pathButton.trailingAnchor.constraint(lessThanOrEqualTo: gitDirtyDot.leadingAnchor, constant: -12),
            pathButton.heightAnchor.constraint(equalToConstant: 16),

            gitDirtyDot.trailingAnchor.constraint(equalTo: branchIcon.leadingAnchor, constant: -4),
            gitDirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitDirtyDot.widthAnchor.constraint(equalToConstant: 5),
            gitDirtyDot.heightAnchor.constraint(equalToConstant: 5),

            branchIcon.trailingAnchor.constraint(equalTo: branchLabel.leadingAnchor, constant: -3),
            branchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 10),
            branchIcon.heightAnchor.constraint(equalToConstant: 10),

            branchLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
        ])
    }

    private func configLabel(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
    }

    // MARK: - Public

    func setShellPid(_ pid: pid_t?) {
        shellPid = pid
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        if shellPid == nil {
            // Try to find the shell by matching the user's default shell name.
            // This is more reliable than just picking the last child PID,
            // especially when multiple shells are running (e.g. fish + bash).
            let shellName = URL(fileURLWithPath: TerminalPane.userShell()).lastPathComponent
            let children = ProcessHelper.childPids()
            if let pid = children.first(where: { ProcessHelper.name(of: $0) == shellName }) {
                shellPid = pid
            } else if let pid = children.last {
                shellPid = pid
            }
        }

        guard let pid = shellPid else {
            processLabel.stringValue = "shell"
            pathButton.title = "~"
            hideGit()
            return
        }

        // Process: show foreground process if running something
        let shellName = ProcessHelper.name(of: pid) ?? "shell"
        if let fgPid = ProcessHelper.foregroundChild(of: pid),
           let fgName = ProcessHelper.name(of: fgPid) {
            processLabel.stringValue = fgName
        } else {
            processLabel.stringValue = shellName
        }

        // Path
        let cwd = ProcessHelper.cwd(of: pid)
        if let cwd = cwd {
            let home = NSHomeDirectory()
            pathButton.title = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            lastCwd = cwd
        } else {
            pathButton.title = "~"
            lastCwd = nil
        }

        // Git
        if let cwd = cwd, let branch = ProcessHelper.gitBranch(at: cwd) {
            branchLabel.stringValue = branch
            branchIcon.isHidden = false
            branchLabel.isHidden = false
            gitDirtyDot.isHidden = !ProcessHelper.gitIsDirty(at: cwd)
        } else {
            hideGit()
        }
    }

    private func hideGit() {
        branchLabel.stringValue = ""
        branchIcon.isHidden = true
        branchLabel.isHidden = true
        gitDirtyDot.isHidden = true
    }

    // MARK: - Actions

    @objc private func copyPath() {
        guard let cwd = lastCwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
        let original = pathButton.contentTintColor
        pathButton.contentTintColor = Theme.primaryText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pathButton.contentTintColor = original
        }
    }

    // MARK: - Polling

    private func startPolling() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}
