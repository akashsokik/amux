import AppKit

// MARK: - File Tree Node

class FileTreeNode {
    let url: URL
    let isDirectory: Bool
    var children: [FileTreeNode]?

    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
    }

    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            children = []
            return
        }

        children = urls.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }.map { FileTreeNode(url: $0) }
    }
}

// MARK: - FileTreeView Delegate

protocol FileTreeViewDelegate: AnyObject {
    func fileTreeView(_ view: FileTreeView, didSelectFileAt path: String)
}

// MARK: - File Tree View

class FileTreeView: NSView {
    weak var delegate: FileTreeViewDelegate?
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var rootNode: FileTreeNode?
    private var headerLabel: NSTextField!
    private var refreshButton: DimIconButton!
    private var currentPath: String?

    private static let rowHeight: CGFloat = 22
    private static let cellID = NSUserInterfaceItemIdentifier("FileTreeCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func themeDidChange() {
        headerLabel.font = Theme.Fonts.headline(size: 11)
        headerLabel.textColor = Theme.primaryText
        refreshButton.refreshDimState()
        outlineView.reloadData()
    }

    @objc private func refreshClicked() {
        guard let path = currentPath else { return }
        currentPath = nil
        setRootPath(path)
    }

    private func setupUI() {
        wantsLayer = true

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

        refreshButton = DimIconButton()
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )
        refreshButton.imagePosition = .imageOnly
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "Refresh file tree"
        refreshButton.refreshDimState()
        addSubview(refreshButton)

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = FileTreeView.rowHeight
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.selectionHighlightStyle = .none
        outlineView.indentationPerLevel = 16
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
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
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -4),

            refreshButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refreshButton.widthAnchor.constraint(equalToConstant: 18),
            refreshButton.heightAnchor.constraint(equalToConstant: 18),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public

    func setRootPath(_ path: String?) {
        guard let path = path else {
            rootNode = nil
            currentPath = nil
            headerLabel.stringValue = ""
            outlineView.reloadData()
            return
        }

        // Skip reload if same path
        if path == currentPath { return }
        currentPath = path

        let url = URL(fileURLWithPath: path)
        rootNode = FileTreeNode(url: url)
        rootNode?.loadChildrenIfNeeded()
        headerLabel.stringValue = url.lastPathComponent.uppercased()
        outlineView.reloadData()

        if let root = rootNode {
            outlineView.expandItem(root)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension FileTreeView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNode?.children?.count ?? 0
        }
        guard let node = item as? FileTreeNode else { return 0 }
        node.loadChildrenIfNeeded()
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!.children![index]
        }
        return (item as! FileTreeNode).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? FileTreeNode)?.isDirectory ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension FileTreeView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        var cell = outlineView.makeView(
            withIdentifier: FileTreeView.cellID,
            owner: self
        ) as? FileTreeCellView

        if cell == nil {
            cell = FileTreeCellView()
            cell?.identifier = FileTreeView.cellID
        }

        cell?.configure(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return FileTreeView.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = NSTableRowView()
        row.isEmphasized = false
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let node = outlineView.item(atRow: selectedRow) as? FileTreeNode,
              !node.isDirectory else { return }
        delegate?.fileTreeView(self, didSelectFileAt: node.url.path)
    }
}

// MARK: - File Tree Cell View

private class FileTreeCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        iconView.alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        iconView.alphaValue = 0.5
    }

    private func setupSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Theme.Fonts.body(size: 12)
        nameLabel.textColor = Theme.secondaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(node: FileTreeNode) {
        nameLabel.stringValue = node.name

        let info: FileIconInfo
        if node.isDirectory {
            info = FileIconInfo.directory
        } else {
            info = FileIconInfo.forFile(named: node.name)
        }
        iconView.image = NSImage(
            systemSymbolName: info.symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        iconView.contentTintColor = info.color
        iconView.alphaValue = 0.5
        nameLabel.textColor = node.isDirectory ? Theme.secondaryText : Theme.tertiaryText
    }
}
