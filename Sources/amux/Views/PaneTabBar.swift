import AppKit

// MARK: - Pasteboard Type & Drag Info

extension NSPasteboard.PasteboardType {
    static let tabDrag = NSPasteboard.PasteboardType("com.amux.tab-drag")
}

struct TabDragInfo: Codable {
    let tabID: UUID
    let sourcePaneID: UUID
}

// MARK: - Tab Bar Delegate

protocol PaneTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: PaneTabBar, didSelectTab tabID: UUID)
    func tabBar(_ tabBar: PaneTabBar, didCloseTab tabID: UUID)
    func tabBarDidRequestNewTab(_ tabBar: PaneTabBar)
    func tabBar(_ tabBar: PaneTabBar, didReceiveDroppedTab info: TabDragInfo, atIndex index: Int)
    func tabBar(_ tabBar: PaneTabBar, canAcceptDrop info: TabDragInfo) -> Bool
}

// MARK: - Tab Bar

class PaneTabBar: NSView {
    weak var delegate: PaneTabBarDelegate?
    var ownerPaneID: UUID = UUID()

    private var scrollView: NSScrollView!
    private var tabContainer: NSView!
    private var addButton: NSButton!
    private var insertionIndicator: NSView!

    private var tabItemViews: [PaneTabItemView] = []

    static let barHeight: CGFloat = 28

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

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
        addButton.contentTintColor = Theme.tertiaryText
        for item in tabItemViews {
            item.refreshTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.surfaceContainerLow.cgColor

        // Horizontal scroll for tab overflow
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.horizontalScroller = ThinScroller()
        addSubview(scrollView)

        tabContainer = NSView(frame: .zero)
        scrollView.documentView = tabContainer

        // Add tab button
        addButton = NSButton()
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = ""
        addButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New Tab"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )
        addButton.imagePosition = .imageOnly
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.contentTintColor = Theme.tertiaryText
        addButton.target = self
        addButton.action = #selector(addButtonClicked)
        if let cell = addButton.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }
        addSubview(addButton)

        // Insertion indicator for drag-and-drop
        insertionIndicator = NSView()
        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.isHidden = true
        addSubview(insertionIndicator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        registerForDraggedTypes([.tabDrag])
    }

    // MARK: - Update

    func updateTabs(_ tabs: [(id: UUID, title: String)], activeID: UUID?) {
        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        for tab in tabs {
            let item = PaneTabItemView(tabID: tab.id, title: tab.title)
            item.isActive = (tab.id == activeID)
            item.showCloseButton = tabs.count > 1
            item.sourcePaneID = ownerPaneID
            item.delegate = self
            tabContainer.addSubview(item)
            tabItemViews.append(item)
        }

        layoutTabItems()
    }

    // MARK: - Layout

    private func layoutTabItems() {
        var x: CGFloat = 4
        let y: CGFloat = 2
        let height = bounds.height - 4

        for item in tabItemViews {
            let width = item.intrinsicContentSize.width
            item.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 2
        }

        tabContainer.frame = NSRect(
            x: 0, y: 0,
            width: max(x + 2, scrollView.bounds.width),
            height: max(bounds.height - 1, 0)
        )
    }

    override func layout() {
        super.layout()
        layoutTabItems()
    }

    // MARK: - Actions

    @objc private func addButtonClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    // MARK: - Drop Destination

    private func decodeDragInfo(from draggingInfo: NSDraggingInfo) -> TabDragInfo? {
        guard let data = draggingInfo.draggingPasteboard.data(forType: .tabDrag) else { return nil }
        return try? JSONDecoder().decode(TabDragInfo.self, from: data)
    }

    private func insertionIndex(for point: NSPoint) -> Int {
        let localPoint = tabContainer.convert(point, from: self)
        for (i, item) in tabItemViews.enumerated() {
            if localPoint.x < item.frame.midX {
                return i
            }
        }
        return tabItemViews.count
    }

    private func showInsertionIndicator(at index: Int) {
        let x: CGFloat
        if index < tabItemViews.count {
            x = tabItemViews[index].frame.minX - 1
        } else if let last = tabItemViews.last {
            x = last.frame.maxX + 1
        } else {
            x = 1
        }
        let converted = convert(NSPoint(x: x, y: 0), from: tabContainer)
        insertionIndicator.frame = NSRect(x: converted.x, y: 2, width: 2, height: bounds.height - 4)
        insertionIndicator.isHidden = false
    }

    private func hideInsertionIndicator() {
        insertionIndicator.isHidden = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let info = decodeDragInfo(from: sender),
              delegate?.tabBar(self, canAcceptDrop: info) == true else {
            return []
        }
        let idx = insertionIndex(for: sender.draggingLocation)
        showInsertionIndicator(at: idx)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let info = decodeDragInfo(from: sender),
              delegate?.tabBar(self, canAcceptDrop: info) == true else {
            hideInsertionIndicator()
            return []
        }
        let idx = insertionIndex(for: sender.draggingLocation)
        showInsertionIndicator(at: idx)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideInsertionIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideInsertionIndicator()
        guard let info = decodeDragInfo(from: sender),
              delegate?.tabBar(self, canAcceptDrop: info) == true else {
            return false
        }
        let idx = insertionIndex(for: sender.draggingLocation)
        delegate?.tabBar(self, didReceiveDroppedTab: info, atIndex: idx)
        return true
    }
}

// MARK: - PaneTabItemViewDelegate

extension PaneTabBar: PaneTabItemViewDelegate {
    func tabItemDidSelect(_ item: PaneTabItemView) {
        delegate?.tabBar(self, didSelectTab: item.tabID)
    }

    func tabItemDidClose(_ item: PaneTabItemView) {
        delegate?.tabBar(self, didCloseTab: item.tabID)
    }
}

// MARK: - Tab Item Delegate

protocol PaneTabItemViewDelegate: AnyObject {
    func tabItemDidSelect(_ item: PaneTabItemView)
    func tabItemDidClose(_ item: PaneTabItemView)
}

// MARK: - Tab Item View

class PaneTabItemView: NSView {
    let tabID: UUID
    var sourcePaneID: UUID = UUID()
    weak var delegate: PaneTabItemViewDelegate?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let highlightView = NSView()
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?

    var title: String {
        didSet { titleLabel.stringValue = title }
    }

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    var showCloseButton: Bool = true {
        didSet { updateAppearance() }
    }

    private var isHovered: Bool = false {
        didSet { updateAppearance() }
    }

    init(tabID: UUID, title: String) {
        self.tabID = tabID
        self.title = title
        super.init(frame: .zero)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        wantsLayer = true

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.CornerRadius.element
        addSubview(highlightView)

        iconView.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Terminal"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        let colorIndex = abs(tabID.hashValue) % Session.palette.count
        iconView.contentTintColor = NSColor(hexString: Session.palette[colorIndex]) ?? Theme.quaternaryText
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = Theme.Fonts.label(size: 12)
        titleLabel.textColor = Theme.tertiaryText
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        closeButton.title = ""
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        )
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.tertiaryText
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        if let cell = closeButton.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }
        addSubview(closeButton)

        updateAppearance()
    }

    private static let minTabWidth: CGFloat = 120
    private static let maxTitleWidth: CGFloat = 120

    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 5

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let clampedTitle = min(titleWidth, PaneTabItemView.maxTitleWidth)
        let icon = PaneTabItemView.iconSize + PaneTabItemView.iconGap
        let natural: CGFloat
        if showCloseButton {
            // padding(8) + icon + title + gap(4) + close(14) + padding(6)
            natural = 8 + icon + clampedTitle + 4 + 14 + 6
        } else {
            // padding(8) + icon + title + padding(8)
            natural = 8 + icon + clampedTitle + 8
        }
        return NSSize(width: max(natural, PaneTabItemView.minTabWidth), height: 24)
    }

    override func layout() {
        super.layout()
        highlightView.frame = bounds

        let icoS = PaneTabItemView.iconSize
        let icoGap = PaneTabItemView.iconGap
        let iconX: CGFloat = 8
        iconView.frame = NSRect(
            x: iconX,
            y: (bounds.height - icoS) / 2,
            width: icoS,
            height: icoS
        )

        let titleX = iconX + icoS + icoGap

        if showCloseButton {
            let closeSize: CGFloat = 14
            let closeX = bounds.width - 6 - closeSize
            closeButton.frame = NSRect(
                x: closeX,
                y: (bounds.height - closeSize) / 2,
                width: closeSize,
                height: closeSize
            )

            let titleWidth = closeX - titleX - 4
            let titleH = titleLabel.intrinsicContentSize.height
            titleLabel.frame = NSRect(
                x: titleX,
                y: (bounds.height - titleH) / 2,
                width: max(0, titleWidth),
                height: titleH
            )
        } else {
            closeButton.frame = .zero
            let titleWidth = bounds.width - titleX - 8
            let titleH = titleLabel.intrinsicContentSize.height
            titleLabel.frame = NSRect(
                x: titleX,
                y: (bounds.height - titleH) / 2,
                width: max(0, titleWidth),
                height: titleH
            )
        }
    }

    private func updateAppearance() {
        if isActive {
            highlightView.layer?.backgroundColor = Theme.surfaceContainerHigh.cgColor
            titleLabel.textColor = Theme.primaryText
        } else if isHovered {
            highlightView.layer?.backgroundColor = Theme.hoverBg.cgColor
            titleLabel.textColor = Theme.secondaryText
        } else {
            highlightView.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = Theme.tertiaryText
        }

        if showCloseButton {
            closeButton.alphaValue = (isActive || isHovered) ? 1 : 0
        } else {
            closeButton.alphaValue = 0
        }
    }

    func refreshTheme() {
        closeButton.contentTintColor = Theme.tertiaryText
        updateAppearance()
    }

    // MARK: - Mouse & Drag Source

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        delegate?.tabItemDidSelect(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        guard sqrt(dx * dx + dy * dy) > 4 else { return }

        dragOrigin = nil // prevent re-triggering

        let info = TabDragInfo(tabID: tabID, sourcePaneID: sourcePaneID)
        guard let data = try? JSONEncoder().encode(info) else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .tabDrag)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        image.unlockFocus()
        return image
    }

    @objc private func closeClicked() {
        delegate?.tabItemDidClose(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

// MARK: - NSDraggingSource

extension PaneTabItemView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        return .move
    }
}
