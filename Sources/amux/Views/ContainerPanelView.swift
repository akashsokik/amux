import AppKit

protocol ContainerPanelViewDelegate: AnyObject {
    func containerPanelDidRequestOpenContainer(id: String)
}

final class ContainerPanelView: NSView {
    weak var delegate: ContainerPanelViewDelegate?

    private var separatorLine: NSView!
    private var glassView: GlassBackgroundView?
    private var unavailableLabel: NSTextField!

    private var splitView: NSSplitView!
    private var containersHeader: SectionHeaderView!
    private var imagesHeader: SectionHeaderView!
    private var containersTable: HoverTableView!
    private var imagesTable: HoverTableView!
    private var containersScroll: NSScrollView!
    private var imagesScroll: NSScrollView!

    private var containers: [ContainerHelper.Container] = []
    private var images: [ContainerHelper.Image] = []
    private var containersCollapsed = false
    private var imagesCollapsed = false
    private var didSetInitialSplitPosition = false
    private var lastExpandedDividerPosition: CGFloat?
    private var isLoading = false

    private var topInsetConstraint: NSLayoutConstraint?
    var topContentInset: CGFloat = 44 {
        didSet { topInsetConstraint?.constant = topContentInset }
    }

    var chromeHidden: Bool = false {
        didSet {
            separatorLine?.isHidden = chromeHidden
            if chromeHidden { glassView?.isHidden = true }
        }
    }

    private static let containerCellID = NSUserInterfaceItemIdentifier("CPContainerCell")
    private static let imageCellID = NSUserInterfaceItemIdentifier("CPImageCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let containers = ContainerHelper.listContainers()
            let images = ContainerHelper.listImages()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.containers = containers ?? []
                self.images = images ?? []
                self.containersHeader.setCount(self.containers.count)
                self.imagesHeader.setCount(self.images.count)
                self.containersTable.reloadData()
                self.imagesTable.reloadData()
                let dockerMissing = containers == nil && images == nil
                self.unavailableLabel.isHidden = !dockerMissing
                self.splitView.isHidden = dockerMissing
            }
        }
    }

    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)

        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        addSubview(splitView)

        let containersContainer = NSView()
        containersContainer.translatesAutoresizingMaskIntoConstraints = false
        containersHeader = SectionHeaderView(title: "CONTAINERS")
        containersHeader.translatesAutoresizingMaskIntoConstraints = false
        containersHeader.configureActions([
            SectionHeaderView.Action(symbol: "arrow.clockwise", tooltip: "Refresh", handler: { [weak self] in self?.refresh() }),
        ])
        containersHeader.onToggle = { [weak self] in self?.toggleContainersCollapsed() }
        containersContainer.addSubview(containersHeader)
        containersTable = makeTable()
        containersScroll = makeScroll(table: containersTable)
        containersContainer.addSubview(containersScroll)

        NSLayoutConstraint.activate([
            containersHeader.topAnchor.constraint(equalTo: containersContainer.topAnchor),
            containersHeader.leadingAnchor.constraint(equalTo: containersContainer.leadingAnchor),
            containersHeader.trailingAnchor.constraint(equalTo: containersContainer.trailingAnchor),
            containersHeader.heightAnchor.constraint(equalToConstant: 26),
            containersScroll.topAnchor.constraint(equalTo: containersHeader.bottomAnchor),
            containersScroll.leadingAnchor.constraint(equalTo: containersContainer.leadingAnchor),
            containersScroll.trailingAnchor.constraint(equalTo: containersContainer.trailingAnchor),
            containersScroll.bottomAnchor.constraint(equalTo: containersContainer.bottomAnchor),
        ])

        let imagesContainer = NSView()
        imagesContainer.translatesAutoresizingMaskIntoConstraints = false
        imagesHeader = SectionHeaderView(title: "IMAGES")
        imagesHeader.translatesAutoresizingMaskIntoConstraints = false
        imagesHeader.configureActions([
            SectionHeaderView.Action(symbol: "arrow.clockwise", tooltip: "Refresh", handler: { [weak self] in self?.refresh() }),
        ])
        imagesHeader.onToggle = { [weak self] in self?.toggleImagesCollapsed() }
        imagesContainer.addSubview(imagesHeader)
        imagesTable = makeTable()
        imagesScroll = makeScroll(table: imagesTable)
        imagesContainer.addSubview(imagesScroll)

        NSLayoutConstraint.activate([
            imagesHeader.topAnchor.constraint(equalTo: imagesContainer.topAnchor),
            imagesHeader.leadingAnchor.constraint(equalTo: imagesContainer.leadingAnchor),
            imagesHeader.trailingAnchor.constraint(equalTo: imagesContainer.trailingAnchor),
            imagesHeader.heightAnchor.constraint(equalToConstant: 26),
            imagesScroll.topAnchor.constraint(equalTo: imagesHeader.bottomAnchor),
            imagesScroll.leadingAnchor.constraint(equalTo: imagesContainer.leadingAnchor),
            imagesScroll.trailingAnchor.constraint(equalTo: imagesContainer.trailingAnchor),
            imagesScroll.bottomAnchor.constraint(equalTo: imagesContainer.bottomAnchor),
        ])

        splitView.addArrangedSubview(containersContainer)
        splitView.addArrangedSubview(imagesContainer)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(251), forSubviewAt: 0)

        unavailableLabel = NSTextField(labelWithString: "Docker not available.\nInstall Docker Desktop or start the daemon.")
        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        unavailableLabel.font = Theme.Fonts.body(size: 12)
        unavailableLabel.textColor = Theme.tertiaryText
        unavailableLabel.alignment = .center
        unavailableLabel.isBezeled = false
        unavailableLabel.isEditable = false
        unavailableLabel.isSelectable = false
        unavailableLabel.backgroundColor = .clear
        unavailableLabel.maximumNumberOfLines = 0
        unavailableLabel.isHidden = true
        addSubview(unavailableLabel)

        topInsetConstraint = splitView.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)
        NSLayoutConstraint.activate([
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),
            topInsetConstraint!,
            splitView.leadingAnchor.constraint(equalTo: separatorLine.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            unavailableLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            unavailableLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            unavailableLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        applyGlassOrSolid()
    }

    private func makeTable() -> HoverTableView {
        let table = HoverTableView()
        table.headerView = nil
        table.rowHeight = 48
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self
        table.backgroundColor = .clear
        table.target = self
        table.action = #selector(tableRowClicked(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.isEditable = false
        table.addTableColumn(column)
        return table
    }

    private func makeScroll(table: HoverTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = ThinScroller()
        return scroll
    }

    @objc private func tableRowClicked(_ sender: NSTableView) {
        guard sender === containersTable else { return }
        let row = sender.clickedRow
        guard row >= 0, row < containers.count else { return }
        delegate?.containerPanelDidRequestOpenContainer(id: containers[row].id)
    }

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

    @objc private func themeDidChange() {
        applyGlassOrSolid()
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        unavailableLabel.textColor = Theme.tertiaryText
        containersHeader.applyTheme()
        imagesHeader.applyTheme()
        containersTable.reloadData()
        imagesTable.reloadData()
    }

    override func layout() {
        super.layout()
        if !didSetInitialSplitPosition, splitView.bounds.height > 100 {
            splitView.setPosition(splitView.bounds.height * 0.55, ofDividerAt: 0)
            lastExpandedDividerPosition = splitView.bounds.height * 0.55
            didSetInitialSplitPosition = true
        }
        if containersCollapsed || imagesCollapsed { applyCollapseState() }
    }

    private func toggleContainersCollapsed() {
        containersCollapsed.toggle()
        containersHeader.isCollapsed = containersCollapsed
        applyCollapseState()
    }

    private func toggleImagesCollapsed() {
        imagesCollapsed.toggle()
        imagesHeader.isCollapsed = imagesCollapsed
        applyCollapseState()
    }

    private func applyCollapseState() {
        let total = splitView.bounds.height
        guard total > 0 else { return }
        let collapsedHeight: CGFloat = 26
        if containersCollapsed && !imagesCollapsed {
            splitView.setPosition(collapsedHeight, ofDividerAt: 0)
        } else if !containersCollapsed && imagesCollapsed {
            splitView.setPosition(total - collapsedHeight, ofDividerAt: 0)
        } else if containersCollapsed && imagesCollapsed {
            splitView.setPosition(collapsedHeight, ofDividerAt: 0)
        } else if let last = lastExpandedDividerPosition {
            splitView.setPosition(last, ofDividerAt: 0)
        } else {
            splitView.setPosition(total * 0.55, ofDividerAt: 0)
        }
    }

    fileprivate func startContainer(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ContainerHelper.start(id)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    fileprivate func stopContainer(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ContainerHelper.stop(id)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    fileprivate func removeContainer(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ContainerHelper.removeContainer(id, force: true)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    fileprivate func removeImage(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ContainerHelper.removeImage(id, force: false)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}

extension ContainerPanelView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 26 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.height - 26 }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !containersCollapsed && !imagesCollapsed {
            let pos = splitView.subviews.first?.frame.height ?? 0
            if pos > 26 { lastExpandedDividerPosition = pos }
        }
    }
}

extension ContainerPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === containersTable { return containers.count }
        if tableView === imagesTable { return images.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === containersTable {
            var cell = tableView.makeView(withIdentifier: Self.containerCellID, owner: self) as? ContainerRowCell
            if cell == nil { cell = ContainerRowCell(); cell?.identifier = Self.containerCellID }
            cell?.configure(container: containers[row], panel: self)
            return cell
        }
        if tableView === imagesTable {
            var cell = tableView.makeView(withIdentifier: Self.imageCellID, owner: self) as? ImageRowCell
            if cell == nil { cell = ImageRowCell(); cell?.identifier = Self.imageCellID }
            cell?.configure(image: images[row], panel: self)
            return cell
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.isEmphasized = false
        return view
    }
}

private enum CPImageIdentity {
    static func icon(for ref: String) -> (String, NSColor) {
        let lower = ref.lowercased()
        let withoutTag = lower
            .split(separator: "@").first.map(String.init)?
            .split(separator: ":").first.map(String.init) ?? lower
        let last = withoutTag.split(separator: "/").last.map(String.init) ?? withoutTag

        if last.contains("postgres") { return ("cylinder.fill", NSColor(srgbRed: 0.20, green: 0.45, blue: 0.85, alpha: 1.0)) }
        if last.contains("mysql") || last.contains("mariadb") { return ("cylinder.fill", NSColor.systemOrange) }
        if last.contains("mongo") { return ("leaf.fill", NSColor.systemGreen) }
        if last.contains("redis") || last.contains("memcached") || last.contains("valkey") { return ("memorychip.fill", NSColor.systemRed) }
        if last.contains("nginx") || last.contains("caddy") || last.contains("traefik") || last.contains("envoy") { return ("globe", NSColor.systemGreen) }
        if last.contains("httpd") || last.contains("apache") { return ("globe", NSColor.systemRed) }
        if last.contains("node") { return ("leaf.fill", NSColor(srgbRed: 0.40, green: 0.78, blue: 0.30, alpha: 1.0)) }
        if last.contains("python") { return ("ladybug.fill", NSColor.systemYellow) }
        if last.contains("ruby") { return ("diamond.fill", NSColor.systemRed) }
        if last.contains("golang") || last == "go" || last.hasPrefix("go-") { return ("g.circle.fill", NSColor.systemTeal) }
        if last.contains("rust") { return ("gearshape.fill", NSColor.systemOrange) }
        if last.contains("ubuntu") { return ("terminal.fill", NSColor.systemOrange) }
        if last.contains("debian") { return ("terminal.fill", NSColor.systemPink) }
        if last.contains("alpine") { return ("terminal.fill", NSColor.systemBlue) }
        if last.contains("rabbitmq") || last.contains("kafka") || last.contains("nats") { return ("envelope.fill", NSColor.systemOrange) }
        if last.contains("elastic") || last.contains("kibana") || last.contains("opensearch") { return ("magnifyingglass", NSColor.systemYellow) }
        if last.contains("grafana") { return ("chart.line.uptrend.xyaxis", NSColor.systemOrange) }
        if last.contains("prometheus") { return ("flame.fill", NSColor.systemOrange) }
        if last.contains("minio") || last.contains("s3") { return ("externaldrive.fill", NSColor.systemRed) }
        if last.contains("vault") { return ("lock.fill", NSColor.systemYellow) }
        if last.contains("registry") { return ("books.vertical.fill", NSColor.systemBlue) }
        return ("shippingbox.fill", Theme.secondaryText)
    }
}

private final class ContainerRowCell: NSView, HoverableRowCell {
    private let hoverBg = NSView()
    private let typeIcon = NSImageView()
    private let statusDot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let imageLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private weak var panel: ContainerPanelView?
    private var containerID: String = ""
    private var isRunning: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        hoverBg.translatesAutoresizingMaskIntoConstraints = false
        hoverBg.wantsLayer = true
        hoverBg.layer?.cornerRadius = Theme.CornerRadius.element
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverBg)

        typeIcon.translatesAutoresizingMaskIntoConstraints = false
        typeIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(typeIcon)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.borderWidth = 1.5
        statusDot.layer?.borderColor = Theme.sidebarBg.cgColor
        addSubview(statusDot)

        for label in [nameLabel, imageLabel, metaLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.backgroundColor = .clear
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        nameLabel.font = Theme.Fonts.body(size: 12)
        nameLabel.textColor = Theme.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        imageLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        imageLabel.textColor = Theme.tertiaryText
        imageLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = Theme.Fonts.body(size: 10)
        metaLabel.textColor = Theme.quaternaryText
        metaLabel.lineBreakMode = .byTruncatingTail

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.alphaValue = 0
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            hoverBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            hoverBg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            hoverBg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            typeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            typeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeIcon.widthAnchor.constraint(equalToConstant: 18),
            typeIcon.heightAnchor.constraint(equalToConstant: 18),

            statusDot.trailingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 2),
            statusDot.bottomAnchor.constraint(equalTo: typeIcon.bottomAnchor, constant: 2),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            nameLabel.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 9),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -6),

            imageLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            imageLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            imageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: imageLabel.bottomAnchor, constant: 1),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(container: ContainerHelper.Container, panel: ContainerPanelView) {
        self.panel = panel
        self.containerID = container.id
        self.isRunning = container.isRunning

        nameLabel.stringValue = container.names.isEmpty ? container.id : container.names
        imageLabel.stringValue = container.image
        metaLabel.stringValue = container.status

        let (symbol, tint) = CPImageIdentity.icon(for: container.image)
        typeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        typeIcon.contentTintColor = container.isRunning ? tint : Theme.tertiaryText
        typeIcon.alphaValue = container.isRunning ? 1.0 : 0.55

        statusDot.layer?.backgroundColor = (container.isRunning
            ? NSColor.systemGreen
            : Theme.tertiaryText.withAlphaComponent(0.55)).cgColor
        statusDot.layer?.borderColor = Theme.sidebarBg.cgColor

        rebuildActions()
    }

    private func rebuildActions() {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let toggleSymbol = isRunning ? "stop.fill" : "play.fill"
        let toggle = makeActionButton(symbol: toggleSymbol, tooltip: isRunning ? "Stop" : "Start") { [weak self] in
            guard let self = self else { return }
            if self.isRunning { self.panel?.stopContainer(self.containerID) }
            else { self.panel?.startContainer(self.containerID) }
        }
        let remove = makeActionButton(symbol: "trash", tooltip: "Remove") { [weak self] in
            guard let self = self else { return }
            self.panel?.removeContainer(self.containerID)
        }
        actionStack.addArrangedSubview(toggle)
        actionStack.addArrangedSubview(remove)
    }

    private func makeActionButton(symbol: String, tooltip: String, handler: @escaping () -> Void) -> DimIconButton {
        let button = DimIconButton()
        button.title = ""
        button.toolTip = tooltip
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        button.imagePosition = .imageOnly
        let target = CPActionTarget(handler: handler)
        objc_setAssociatedObject(button, &cpActionTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        button.target = target
        button.action = #selector(CPActionTarget.fire)
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        button.refreshDimState()
        return button
    }

    func setHovered(_ hovered: Bool) {
        hoverBg.layer?.backgroundColor = hovered ? Theme.hoverBg.cgColor : NSColor.clear.cgColor
        actionStack.alphaValue = hovered ? 1 : 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovered(false)
    }
}

private final class ImageRowCell: NSView, HoverableRowCell {
    private let hoverBg = NSView()
    private let typeIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private weak var panel: ContainerPanelView?
    private var imageID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        hoverBg.translatesAutoresizingMaskIntoConstraints = false
        hoverBg.wantsLayer = true
        hoverBg.layer?.cornerRadius = Theme.CornerRadius.element
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverBg)

        typeIcon.translatesAutoresizingMaskIntoConstraints = false
        typeIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(typeIcon)

        for label in [nameLabel, metaLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.backgroundColor = .clear
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        nameLabel.font = Theme.Fonts.body(size: 12)
        nameLabel.textColor = Theme.primaryText
        nameLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = Theme.Fonts.body(size: 10)
        metaLabel.textColor = Theme.tertiaryText
        metaLabel.lineBreakMode = .byTruncatingTail

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.alphaValue = 0
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            hoverBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            hoverBg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            hoverBg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            typeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            typeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeIcon.widthAnchor.constraint(equalToConstant: 18),
            typeIcon.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 9),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -6),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image: ContainerHelper.Image, panel: ContainerPanelView) {
        self.panel = panel
        self.imageID = image.id

        let (symbol, tint) = CPImageIdentity.icon(for: image.repository)
        typeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        typeIcon.contentTintColor = tint
        typeIcon.alphaValue = 0.85

        nameLabel.stringValue = image.displayName
        var meta: [String] = []
        if !image.size.isEmpty { meta.append(image.size) }
        if !image.createdAgo.isEmpty { meta.append(image.createdAgo) }
        meta.append(image.id)
        metaLabel.stringValue = meta.joined(separator: " · ")

        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let remove = DimIconButton()
        remove.title = ""
        remove.toolTip = "Remove image"
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        remove.imagePosition = .imageOnly
        let target = CPActionTarget(handler: { [weak self] in
            guard let self = self else { return }
            self.panel?.removeImage(self.imageID)
        })
        objc_setAssociatedObject(remove, &cpActionTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        remove.target = target
        remove.action = #selector(CPActionTarget.fire)
        remove.widthAnchor.constraint(equalToConstant: 18).isActive = true
        remove.heightAnchor.constraint(equalToConstant: 18).isActive = true
        remove.refreshDimState()
        actionStack.addArrangedSubview(remove)
    }

    func setHovered(_ hovered: Bool) {
        hoverBg.layer?.backgroundColor = hovered ? Theme.hoverBg.cgColor : NSColor.clear.cgColor
        actionStack.alphaValue = hovered ? 1 : 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovered(false)
    }
}

private var cpActionTargetKey: UInt8 = 0

private final class CPActionTarget: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
