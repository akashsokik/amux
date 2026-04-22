import AppKit

// MARK: - Commit Detail Tab Content
//
// Shows one commit: header block (hash, author, date, full message) plus a
// clickable list of files changed. Clicking a file invokes `onRequestOpenFile`
// which the host pane uses to open a commit-scoped diff tab.
final class CommitDetailTabView: NSView {
    let commitHash: String
    let repoRoot: String

    /// Called when the user clicks a file in the changed-files list. The host
    /// pane should open a diff tab for that (path, commit) pair.
    var onRequestOpenFile: ((_ path: String, _ commitHash: String) -> Void)?

    private var detail: GitHelper.CommitDetail?

    // Chrome / top
    private var scrollView: NSScrollView!
    private var contentStack: NSStackView!

    // Header
    private var shortHashLabel: NSTextField!
    private var authorLabel: NSTextField!
    private var dateLabel: NSTextField!
    private var subjectLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var headerSeparator: NSView!

    // Files list
    private var filesHeaderLabel: NSTextField!
    private var filesStack: NSStackView!

    private var loadingLabel: NSTextField!

    // MARK: - Init

    init(hash: String, repoRoot: String) {
        self.commitHash = hash
        self.repoRoot = repoRoot
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

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func matches(hash: String) -> Bool {
        self.commitHash == hash
    }

    func reload() {
        loadingLabel.isHidden = false
        let h = commitHash
        let root = repoRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let d = GitHelper.commitDetail(from: root, hash: h)
            DispatchQueue.main.async {
                self?.detail = d
                self?.applyDetail()
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        let flipped = FlippedView()
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
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        loadingLabel = NSTextField(labelWithString: "Loading commit…")
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = Theme.Fonts.body(size: 12)
        loadingLabel.textColor = Theme.tertiaryText
        loadingLabel.backgroundColor = .clear
        loadingLabel.isBezeled = false
        contentStack.addArrangedSubview(loadingLabel)

        // Pre-create header + files placeholders; populated by applyDetail().
        subjectLabel = makeLabel(font: Theme.Fonts.headline(size: 16), color: Theme.primaryText, lines: 3)
        bodyLabel = makeLabel(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                              color: Theme.secondaryText, lines: 0)
        bodyLabel.lineBreakMode = .byWordWrapping

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.spacing = 10
        metaRow.alignment = .firstBaseline
        shortHashLabel = makeMetaChip(prefix: nil)
        authorLabel = makeMetaLabel()
        dateLabel = makeMetaLabel()
        metaRow.addArrangedSubview(shortHashLabel)
        metaRow.addArrangedSubview(authorLabel)
        metaRow.addArrangedSubview(dateLabel)

        headerSeparator = NSView()
        headerSeparator.wantsLayer = true
        headerSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        headerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        filesHeaderLabel = NSTextField(labelWithString: "FILES CHANGED")
        filesHeaderLabel.font = Theme.Fonts.label(size: 10)
        filesHeaderLabel.textColor = Theme.tertiaryText
        filesHeaderLabel.backgroundColor = .clear
        filesHeaderLabel.isBezeled = false

        filesStack = NSStackView()
        filesStack.orientation = .vertical
        filesStack.alignment = .leading
        filesStack.spacing = 0

        // Order: subject → meta → body → sep → files header → files
        contentStack.addArrangedSubview(subjectLabel)
        contentStack.addArrangedSubview(metaRow)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(headerSeparator)
        contentStack.addArrangedSubview(filesHeaderLabel)
        contentStack.addArrangedSubview(filesStack)

        // Width-constrain the long labels so they wrap inside the stack.
        subjectLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
        bodyLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
        headerSeparator.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
        filesStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true

        // Initially hide everything until data loads.
        subjectLabel.isHidden = true
        metaRow.isHidden = true
        bodyLabel.isHidden = true
        headerSeparator.isHidden = true
        filesHeaderLabel.isHidden = true
        filesStack.isHidden = true
    }

    private func makeLabel(font: NSFont, color: NSColor, lines: Int) -> NSTextField {
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = font
        tf.textColor = color
        tf.backgroundColor = .clear
        tf.isBezeled = false
        tf.isEditable = false
        tf.isSelectable = true
        tf.maximumNumberOfLines = lines
        tf.lineBreakMode = .byWordWrapping
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        return tf
    }

    private func makeMetaLabel() -> NSTextField {
        let tf = NSTextField(labelWithString: "")
        tf.font = Theme.Fonts.body(size: 11)
        tf.textColor = Theme.tertiaryText
        tf.backgroundColor = .clear
        tf.isBezeled = false
        tf.isEditable = false
        tf.isSelectable = true
        return tf
    }

    private func makeMetaChip(prefix: String?) -> NSTextField {
        let tf = NSTextField(labelWithString: "")
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.textColor = Theme.secondaryText
        tf.backgroundColor = .clear
        tf.isBezeled = false
        tf.isEditable = false
        tf.isSelectable = true
        return tf
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.background.cgColor
        headerSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        filesHeaderLabel.textColor = Theme.tertiaryText
        loadingLabel.textColor = Theme.tertiaryText
        subjectLabel.textColor = Theme.primaryText
        bodyLabel.textColor = Theme.secondaryText
        shortHashLabel.textColor = Theme.secondaryText
        authorLabel.textColor = Theme.tertiaryText
        dateLabel.textColor = Theme.tertiaryText
        applyDetail()
    }

    // MARK: - Apply

    private func applyDetail() {
        guard let d = detail else {
            loadingLabel.stringValue = "Commit not found."
            return
        }
        loadingLabel.isHidden = true

        subjectLabel.stringValue = d.subject
        subjectLabel.isHidden = false

        shortHashLabel.stringValue = d.shortHash
        authorLabel.stringValue = d.authorName
        dateLabel.stringValue = d.relativeDate
        (shortHashLabel.superview as? NSStackView)?.isHidden = false

        if d.body.isEmpty {
            bodyLabel.isHidden = true
        } else {
            bodyLabel.stringValue = d.body
            bodyLabel.isHidden = false
        }

        headerSeparator.isHidden = false
        filesHeaderLabel.isHidden = false
        filesStack.isHidden = false

        // Rebuild files list.
        filesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if d.files.isEmpty {
            let empty = NSTextField(labelWithString: "No file changes.")
            empty.font = Theme.Fonts.body(size: 12)
            empty.textColor = Theme.tertiaryText
            empty.backgroundColor = .clear
            empty.isBezeled = false
            empty.isEditable = false
            filesStack.addArrangedSubview(empty)
        } else {
            for file in d.files {
                let row = CommitFileRow(file: file)
                row.onClick = { [weak self] in
                    guard let self = self else { return }
                    self.onRequestOpenFile?(file.path, self.commitHash)
                }
                filesStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: filesStack.widthAnchor).isActive = true
            }
        }
    }
}

// MARK: - File row

private final class CommitFileRow: NSView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let hoverBg = NSView()
    private var trackingAreaRef: NSTrackingArea?

    init(file: GitHelper.FileStatus) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        hoverBg.translatesAutoresizingMaskIntoConstraints = false
        hoverBg.wantsLayer = true
        hoverBg.layer?.cornerRadius = Theme.CornerRadius.element
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverBg)

        let fileName = URL(fileURLWithPath: file.path).lastPathComponent
        let info = FileIconInfo.forFile(named: fileName)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(
            systemSymbolName: info.symbolName, accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        iconView.contentTintColor = info.color
        addSubview(iconView)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.stringValue = file.path
        pathLabel.toolTip = file.path
        pathLabel.font = Theme.Fonts.body(size: 12)
        pathLabel.textColor = Theme.secondaryText
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = Theme.Fonts.body(size: 10)
        statsLabel.backgroundColor = .clear
        statsLabel.isBezeled = false
        statsLabel.isEditable = false
        statsLabel.isSelectable = false
        addSubview(statsLabel)

        let total = file.linesAdded + file.linesRemoved
        if total > 0 {
            let combined = NSMutableAttributedString()
            combined.append(NSAttributedString(string: "+\(file.linesAdded)", attributes: [
                .foregroundColor: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1.0),
                .font: Theme.Fonts.body(size: 10),
            ]))
            combined.append(NSAttributedString(string: "  ", attributes: [.font: Theme.Fonts.body(size: 10)]))
            combined.append(NSAttributedString(string: "-\(file.linesRemoved)", attributes: [
                .foregroundColor: NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0),
                .font: Theme.Fonts.body(size: 10),
            ]))
            statsLabel.attributedStringValue = combined
            statsLabel.isHidden = false
        } else {
            statsLabel.isHidden = true
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),

            hoverBg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            hoverBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverBg.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -6),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverBg.layer?.backgroundColor = Theme.hoverBg.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Flipped view for top-left origin

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
