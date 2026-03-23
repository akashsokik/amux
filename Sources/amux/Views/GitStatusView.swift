import AppKit

// MARK: - Git Status View

class GitStatusView: NSView {
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var headerLabel: NSTextField!
    private var aheadLabel: NSTextField!
    private var behindLabel: NSTextField!
    private var refreshButton: DimIconButton!
    private var emptyLabel: NSTextField!

    private var currentCwd: String?
    private var statusInfo: GitHelper.StatusInfo?

    /// Section keys used as root items in the outline view.
    private var visibleSections: [String] = []
    /// Files grouped by section key.
    private var sectionFiles: [String: [GitHelper.FileStatus]] = [:]

    private static let rowHeight: CGFloat = 22
    private static let sectionCellID = NSUserInterfaceItemIdentifier("GitStatusSectionCell")
    private static let fileCellID = NSUserInterfaceItemIdentifier("GitStatusFileCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(gitCommandDidFinish),
            name: GitHelper.commandDidFinishNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        headerLabel.font = Theme.Fonts.headline(size: 11)
        headerLabel.textColor = Theme.primaryText
        aheadLabel.font = Theme.Fonts.body(size: 10)
        aheadLabel.textColor = Theme.primary
        behindLabel.font = Theme.Fonts.body(size: 10)
        behindLabel.textColor = Theme.tertiaryText
        emptyLabel.font = Theme.Fonts.body(size: 12)
        emptyLabel.textColor = Theme.tertiaryText
        refreshButton.refreshDimState()
        outlineView.reloadData()
    }

    // MARK: - Auto-refresh

    @objc private func gitCommandDidFinish() {
        refresh(cwd: currentCwd)
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        // Header label (branch name)
        headerLabel = NSTextField(labelWithString: "")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = Theme.Fonts.headline(size: 11)
        headerLabel.textColor = Theme.primaryText
        headerLabel.backgroundColor = .clear
        headerLabel.isBezeled = false
        headerLabel.isEditable = false
        headerLabel.isSelectable = false
        headerLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(headerLabel)

        // Ahead badge
        aheadLabel = NSTextField(labelWithString: "")
        aheadLabel.translatesAutoresizingMaskIntoConstraints = false
        aheadLabel.font = Theme.Fonts.body(size: 10)
        aheadLabel.textColor = Theme.primary
        aheadLabel.backgroundColor = .clear
        aheadLabel.isBezeled = false
        aheadLabel.isEditable = false
        aheadLabel.isSelectable = false
        aheadLabel.isHidden = true
        addSubview(aheadLabel)

        // Behind badge
        behindLabel = NSTextField(labelWithString: "")
        behindLabel.translatesAutoresizingMaskIntoConstraints = false
        behindLabel.font = Theme.Fonts.body(size: 10)
        behindLabel.textColor = Theme.tertiaryText
        behindLabel.backgroundColor = .clear
        behindLabel.isBezeled = false
        behindLabel.isEditable = false
        behindLabel.isSelectable = false
        behindLabel.isHidden = true
        addSubview(behindLabel)

        // Refresh button
        let refreshImage = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        refreshButton = DimIconButton(image: refreshImage ?? NSImage(), target: self, action: #selector(refreshClicked))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.refreshDimState()
        addSubview(refreshButton)

        // Empty state label
        emptyLabel = NSTextField(labelWithString: "")
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
        outlineView.rowHeight = GitStatusView.rowHeight
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.selectionHighlightStyle = .none
        outlineView.indentationPerLevel = 12
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GitStatusColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

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
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            aheadLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            aheadLabel.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: 6),

            behindLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            behindLabel.leadingAnchor.constraint(equalTo: aheadLabel.trailingAnchor, constant: 4),

            refreshButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refreshButton.widthAnchor.constraint(equalToConstant: 20),
            refreshButton.heightAnchor.constraint(equalToConstant: 20),

            // Keep header label from overlapping the refresh button
            behindLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -4),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -4),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        refresh(cwd: currentCwd)
    }

    // MARK: - Public

    func refresh(cwd: String?) {
        currentCwd = cwd

        guard let cwd = cwd else {
            updateWithStatus(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = GitHelper.status(from: cwd)
            DispatchQueue.main.async {
                self?.updateWithStatus(info)
            }
        }
    }

    // MARK: - Private

    private func updateWithStatus(_ info: GitHelper.StatusInfo?) {
        statusInfo = info

        guard let info = info else {
            headerLabel.stringValue = ""
            aheadLabel.isHidden = true
            behindLabel.isHidden = true
            visibleSections = []
            sectionFiles = [:]
            outlineView.reloadData()
            scrollView.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = "Not a git repository"
            return
        }

        // Update header
        headerLabel.stringValue = info.branch

        // Ahead / behind badges
        if info.ahead > 0 {
            aheadLabel.stringValue = "+\(info.ahead)"
            aheadLabel.isHidden = false
        } else {
            aheadLabel.isHidden = true
        }

        if info.behind > 0 {
            behindLabel.stringValue = "-\(info.behind)"
            behindLabel.isHidden = false
        } else {
            behindLabel.isHidden = true
        }

        // Group files into sections
        var staged: [GitHelper.FileStatus] = []
        var modified: [GitHelper.FileStatus] = []
        var untracked: [GitHelper.FileStatus] = []

        for file in info.files {
            switch file.kind {
            case .staged, .renamed:
                staged.append(file)
            case .modified:
                modified.append(file)
            case .untracked:
                untracked.append(file)
            case .deleted:
                // deleted files keep their kind as-is from GitHelper;
                // staged deletes appear as .staged in GitHelper output,
                // working tree deletes as .modified -- but since GitHelper
                // already classifies them we put .deleted into modified section
                modified.append(file)
            }
        }

        var sections: [String] = []
        var files: [String: [GitHelper.FileStatus]] = [:]

        if !staged.isEmpty {
            sections.append("staged")
            files["staged"] = staged
        }
        if !modified.isEmpty {
            sections.append("modified")
            files["modified"] = modified
        }
        if !untracked.isEmpty {
            sections.append("untracked")
            files["untracked"] = untracked
        }

        visibleSections = sections
        sectionFiles = files

        if info.files.isEmpty {
            scrollView.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = "Working tree clean"
        } else {
            scrollView.isHidden = false
            emptyLabel.isHidden = true
        }

        outlineView.reloadData()

        // Expand all sections by default
        for section in visibleSections {
            outlineView.expandItem(section)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension GitStatusView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return visibleSections.count
        }
        if let section = item as? String {
            return sectionFiles[section]?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return visibleSections[index]
        }
        if let section = item as? String {
            return sectionFiles[section]![index]
        }
        fatalError("Unexpected outline item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is String
    }
}

// MARK: - NSOutlineViewDelegate

extension GitStatusView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? String {
            var cell = outlineView.makeView(
                withIdentifier: GitStatusView.sectionCellID,
                owner: self
            ) as? GitStatusSectionCellView

            if cell == nil {
                cell = GitStatusSectionCellView()
                cell?.identifier = GitStatusView.sectionCellID
            }

            cell?.configure(section: section)
            return cell
        }

        if let file = item as? GitHelper.FileStatus {
            var cell = outlineView.makeView(
                withIdentifier: GitStatusView.fileCellID,
                owner: self
            ) as? GitStatusFileCellView

            if cell == nil {
                cell = GitStatusFileCellView()
                cell?.identifier = GitStatusView.fileCellID
            }

            cell?.configure(file: file)
            return cell
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return GitStatusView.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = NSTableRowView()
        row.isEmphasized = false
        return row
    }
}

// MARK: - Section Header Cell

private class GitStatusSectionCellView: NSView {
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
        nameLabel.font = Theme.Fonts.label(size: 10)
        nameLabel.textColor = Theme.tertiaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(section: String) {
        let titles: [String: String] = [
            "staged": "STAGED",
            "modified": "MODIFIED",
            "untracked": "UNTRACKED",
        ]
        nameLabel.stringValue = titles[section] ?? section.uppercased()
        nameLabel.font = Theme.Fonts.label(size: 10)
        nameLabel.textColor = Theme.tertiaryText
    }
}

// MARK: - File Cell

private class GitStatusFileCellView: NSView {
    private let dotView = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        addSubview(dotView)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = Theme.Fonts.body(size: 12)
        pathLabel.textColor = Theme.secondaryText
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        addSubview(pathLabel)

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = Theme.Fonts.body(size: 10)
        statsLabel.backgroundColor = .clear
        statsLabel.isBezeled = false
        statsLabel.isEditable = false
        statsLabel.isSelectable = false
        statsLabel.alignment = .right
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(statsLabel)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),

            pathLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 4),
            statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(file: GitHelper.FileStatus) {
        pathLabel.stringValue = file.path
        pathLabel.font = Theme.Fonts.body(size: 12)
        pathLabel.textColor = Theme.secondaryText

        // Colored dot based on kind
        let dotColor: NSColor
        switch file.kind {
        case .staged, .renamed:
            dotColor = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1.0) // green
        case .modified:
            dotColor = NSColor(srgbRed: 0.90, green: 0.72, blue: 0.20, alpha: 1.0) // amber
        case .untracked:
            dotColor = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0) // grey
        case .deleted:
            dotColor = NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0) // red
        }
        dotView.layer?.backgroundColor = dotColor.cgColor

        // Diff stats
        let total = file.linesAdded + file.linesRemoved
        if total > 0 {
            let statsString = NSMutableAttributedString()
            let addedStr = NSAttributedString(
                string: "+\(file.linesAdded)",
                attributes: [
                    .foregroundColor: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1.0),
                    .font: Theme.Fonts.body(size: 10),
                ]
            )
            let separator = NSAttributedString(
                string: " ",
                attributes: [.font: Theme.Fonts.body(size: 10)]
            )
            let removedStr = NSAttributedString(
                string: "-\(file.linesRemoved)",
                attributes: [
                    .foregroundColor: NSColor(srgbRed: 0.90, green: 0.30, blue: 0.30, alpha: 1.0),
                    .font: Theme.Fonts.body(size: 10),
                ]
            )
            statsString.append(addedStr)
            statsString.append(separator)
            statsString.append(removedStr)
            statsLabel.attributedStringValue = statsString
            statsLabel.isHidden = false
        } else {
            statsLabel.stringValue = ""
            statsLabel.isHidden = true
        }
    }
}
