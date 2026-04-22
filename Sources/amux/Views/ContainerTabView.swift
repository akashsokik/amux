import AppKit

// MARK: - Container Tab Content
//
// Pane tab that shows inspect-level detail for a single container. Mirrors
// DiffTabView's role as a non-terminal tab: a thin top action bar hosts an
// "Open Terminal" button that drops `docker exec -it <id> /bin/sh` into a
// newly spawned terminal tab on the same pane.
final class ContainerTabView: NSView {
    let containerID: String

    /// Host invokes this to spawn a new terminal tab on the same pane,
    /// pre-typed with the supplied command (e.g. `docker exec -it <id> sh\n`).
    var onRequestOpenTerminal: ((_ command: String) -> Void)?

    private var detail: ContainerHelper.Detail?

    // Chrome
    private var actionBar: NSView!
    private var actionBarSeparator: NSView!
    private var titleLabel: NSTextField!
    private var openTerminalButton: GitPanelActionButton!

    // Content
    private var scrollView: NSScrollView!
    private var contentStack: NSStackView!
    private var loadingLabel: NSTextField!

    init(containerID: String) {
        self.containerID = containerID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    func matches(containerID: String) -> Bool {
        self.containerID == containerID
    }

    func reload() {
        loadingLabel.isHidden = false
        let id = containerID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let d = ContainerHelper.inspect(id)
            DispatchQueue.main.async {
                self?.detail = d
                self?.applyDetail()
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        setupActionBar()
        setupScroll()
        setupLoading()
    }

    private func setupActionBar() {
        actionBar = NSView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
        addSubview(actionBar)

        titleLabel = NSTextField(labelWithString: String(containerID.prefix(12)))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.Fonts.body(size: 12)
        titleLabel.textColor = Theme.secondaryText
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        actionBar.addSubview(titleLabel)

        openTerminalButton = GitPanelActionButton(title: "Open Terminal", symbolName: "terminal", style: .secondary)
        openTerminalButton.translatesAutoresizingMaskIntoConstraints = false
        openTerminalButton.target = self
        openTerminalButton.action = #selector(openTerminalClicked)
        actionBar.addSubview(openTerminalButton)

        actionBarSeparator = NSView()
        actionBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        actionBarSeparator.wantsLayer = true
        actionBarSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(actionBarSeparator)

        NSLayoutConstraint.activate([
            actionBar.topAnchor.constraint(equalTo: topAnchor),
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openTerminalButton.leadingAnchor, constant: -8),

            openTerminalButton.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -8),
            openTerminalButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            openTerminalButton.heightAnchor.constraint(equalToConstant: 22),

            actionBarSeparator.topAnchor.constraint(equalTo: actionBar.bottomAnchor),
            actionBarSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBarSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBarSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func setupScroll() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = ThinScroller()
        addSubview(scrollView)

        contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let flipped = ContainerTabFlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        scrollView.documentView = flipped

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: actionBarSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func setupLoading() {
        loadingLabel = NSTextField(labelWithString: "Loading container…")
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = Theme.Fonts.body(size: 12)
        loadingLabel.textColor = Theme.tertiaryText
        loadingLabel.backgroundColor = .clear
        loadingLabel.isBezeled = false
        loadingLabel.isEditable = false
        loadingLabel.isSelectable = false
        addSubview(loadingLabel)
        NSLayoutConstraint.activate([
            loadingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.background.cgColor
        actionBar.layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
        actionBarSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        titleLabel.textColor = Theme.secondaryText
        applyDetail()
    }

    @objc private func openTerminalClicked() {
        let cmd = "docker exec -it \(containerID) /bin/sh\n"
        onRequestOpenTerminal?(cmd)
    }

    // MARK: - Render

    private func applyDetail() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let d = detail else {
            loadingLabel.isHidden = false
            return
        }
        loadingLabel.isHidden = true

        let heading = d.name.isEmpty ? d.shortID : d.name
        titleLabel.stringValue = heading

        // Summary (no section title — always first, always present)
        var summary: [(String, String, Bool)] = []   // (key, value, mono?)
        summary.append(("ID", d.shortID, true))
        if !d.name.isEmpty { summary.append(("Name", d.name, false)) }
        summary.append(("Image", d.image, true))
        if !d.created.isEmpty { summary.append(("Created", Self.formatAbsoluteDate(d.created), false)) }
        if !d.platform.isEmpty { summary.append(("Platform", d.platform, true)) }
        if !d.statusText.isEmpty { summary.append(("Status", Self.formatStatus(d.statusText), false)) }
        addCard(title: nil, rows: summary)

        // Config
        var config: [(String, String, Bool)] = []
        if !d.command.isEmpty { config.append(("Command", d.command, true)) }
        if !d.entrypoint.isEmpty { config.append(("Entrypoint", d.entrypoint, true)) }
        if !d.workingDir.isEmpty { config.append(("Working Directory", d.workingDir, true)) }
        if !config.isEmpty { addCard(title: "Config", rows: config) }

        // Environment — sort + mask secrets.
        if !d.env.isEmpty {
            let rows = d.env
                .sorted { $0.0 < $1.0 }
                .map { (k, v) -> (String, String, Bool) in
                    (k, Self.maskIfSecret(key: k, value: v), true)
                }
            addCard(title: "Environment", rows: rows)
        }

        // Labels — strip long compose prefix, keep sorted.
        if !d.labels.isEmpty {
            let rows = d.labels
                .sorted { $0.0 < $1.0 }
                .map { (k, v) -> (String, String, Bool) in
                    (Self.shortenLabelKey(k), v, true)
                }
            addCard(title: "Labels", rows: rows)
        }

        // Ports
        if !d.exposedPorts.isEmpty || !d.publishedPorts.isEmpty {
            var rows: [(String, String, Bool)] = []
            for p in d.publishedPorts { rows.append(("Published", p, true)) }
            for p in d.exposedPorts { rows.append(("Exposed", p, true)) }
            addCard(title: "Ports", rows: rows)
        }

        // Mounts
        if !d.mounts.isEmpty {
            let rows = d.mounts.map { (m) -> (String, String, Bool) in
                let modeSuffix = m.mode.isEmpty ? "" : "   (\(m.mode))"
                return (m.destination, "← \(m.source)\(modeSuffix)", true)
            }
            addCard(title: "Mounts", rows: rows)
        }

        // Networks
        if !d.networks.isEmpty {
            let rows = d.networks.map { ("Network", $0, true) }
            addCard(title: "Networks", rows: rows)
        }
    }

    /// Arranges a card in the content stack, pinning its width to the stack
    /// so `NSStackView`'s `.leading` alignment doesn't collapse it to zero.
    private func addArrangedCard(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        let inset = contentStack.edgeInsets.left + contentStack.edgeInsets.right
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -inset).isActive = true
    }

    /// Adds one section: optional uppercase title label above a rounded card
    /// containing the rows. Each row is rendered as a two-column key/value.
    private func addCard(title: String?, rows: [(String, String, Bool)]) {
        if let title = title {
            addArrangedCard(makeSectionLabel(title))
        }
        addArrangedCard(makeCard(rows: rows))
    }

    private func makeSectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.label(size: 10)
        label.textColor = Theme.tertiaryText
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        // A slim wrapper so NSStackView can size it correctly at full width.
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 2),
            label.topAnchor.constraint(equalTo: wrap.topAnchor),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            wrap.heightAnchor.constraint(equalToConstant: 16),
        ])
        return wrap
    }

    /// Build a card containing a vertical list of key/value rows, separated by
    /// hairlines. Key column is fixed-width so values line up; values truncate
    /// with ellipsis but are selectable for copy.
    private func makeCard(rows: [(String, String, Bool)]) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = Theme.CornerRadius.element
        card.layer?.backgroundColor = Theme.surfaceContainerLow.withAlphaComponent(0.75).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.outlineVariant.cgColor

        var previous: NSView? = nil
        for (i, entry) in rows.enumerated() {
            let row = makeRow(key: entry.0, value: entry.1, monospaceValue: entry.2)
            card.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            ])
            if let prev = previous {
                row.topAnchor.constraint(equalTo: prev.bottomAnchor).isActive = true
                let div = NSView()
                div.translatesAutoresizingMaskIntoConstraints = false
                div.wantsLayer = true
                div.layer?.backgroundColor = Theme.outlineVariant.withAlphaComponent(0.5).cgColor
                card.addSubview(div)
                NSLayoutConstraint.activate([
                    div.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                    div.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                    div.bottomAnchor.constraint(equalTo: row.topAnchor),
                    div.heightAnchor.constraint(equalToConstant: 1),
                ])
            } else {
                row.topAnchor.constraint(equalTo: card.topAnchor).isActive = true
            }
            if i == rows.count - 1 {
                row.bottomAnchor.constraint(equalTo: card.bottomAnchor).isActive = true
            }
            previous = row
        }
        return card
    }

    /// Two-column row: key on the left (fixed proportion), value on the right
    /// left-aligned so columns stack cleanly. Value truncates tail but is
    /// selectable for copy-paste.
    private func makeRow(key: String, value: String, monospaceValue: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.font = Theme.Fonts.body(size: 11)
        keyLabel.textColor = Theme.tertiaryText
        keyLabel.backgroundColor = .clear
        keyLabel.isBezeled = false
        keyLabel.isEditable = false
        keyLabel.isSelectable = true
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.maximumNumberOfLines = 1
        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        container.addSubview(keyLabel)

        let valueLabel = NSTextField(labelWithString: value.isEmpty ? "—" : value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        if monospaceValue {
            valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        } else {
            valueLabel.font = Theme.Fonts.body(size: 11)
        }
        valueLabel.textColor = value.isEmpty ? Theme.quaternaryText : Theme.primaryText
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = true
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.toolTip = value
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(valueLabel)

        // Fixed-ratio key column (~35%) so labels line up across sections
        // and values start on a predictable column regardless of key length.
        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            keyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            keyLabel.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.35, constant: -14),

            valueLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    // MARK: - Formatters

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return f
    }()

    /// "2026-04-20T13:34:22.823Z" -> "Apr 20, 2026 at 13:34"
    fileprivate static func formatAbsoluteDate(_ raw: String) -> String {
        if let date = isoFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            return displayFormatter.string(from: date)
        }
        return raw
    }

    /// "Running since 2026-04-21T07:13:44.725Z" -> "Running since Apr 21 at 07:13 (2h ago)"
    fileprivate static func formatStatus(_ raw: String) -> String {
        let parts = raw.components(separatedBy: " ")
        if parts.count >= 3, parts[0] == "Running", parts[1] == "since",
           let date = isoFormatter.date(from: parts[2]) ?? ISO8601DateFormatter().date(from: parts[2]) {
            let pretty = displayFormatter.string(from: date)
            let interval = Date().timeIntervalSince(date)
            return "Running · \(pretty) (\(relativeAgo(interval: interval)))"
        }
        return raw
    }

    private static func relativeAgo(interval: TimeInterval) -> String {
        let s = Int(interval)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// Mask secret-looking values so they don't splash across the pane. Keeps
    /// enough prefix/suffix for recognition and puts the full value in a
    /// tooltip on the value label.
    fileprivate static func maskIfSecret(key: String, value: String) -> String {
        guard value.count > 12 else { return value }
        let upper = key.uppercased()
        let hints = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASS", "AUTH", "SIGNING"]
        guard hints.contains(where: { upper.contains($0) }) else { return value }
        let head = value.prefix(4)
        let tail = value.suffix(4)
        return "\(head)•••••••\(tail)"
    }

    /// `com.docker.compose.config-hash` -> `compose.config-hash`
    fileprivate static func shortenLabelKey(_ key: String) -> String {
        if key.hasPrefix("com.docker.compose.") {
            return "compose." + key.dropFirst("com.docker.compose.".count)
        }
        return key
    }
}

private final class ContainerTabFlippedView: NSView {
    override var isFlipped: Bool { true }
}
