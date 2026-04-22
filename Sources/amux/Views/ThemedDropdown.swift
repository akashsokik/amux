import AppKit

// MARK: - Themed dropdown popover
//
// Lightweight replacement for NSMenu so our chip-button dropdowns stay
// visually consistent with the app theme (monospace font, custom colors,
// rounded rows). Uses NSPopover for click-outside-to-dismiss behavior.

final class ThemedDropdown {
    // MARK: Item

    struct Item {
        let title: String
        let subtitle: String?
        let iconSymbol: String?
        let isChecked: Bool
        let isEnabled: Bool
        let handler: (() -> Void)?
        let kind: Kind

        enum Kind { case row, separator, header }

        static func row(
            _ title: String,
            subtitle: String? = nil,
            icon: String? = nil,
            checked: Bool = false,
            enabled: Bool = true,
            handler: @escaping () -> Void
        ) -> Item {
            Item(title: title, subtitle: subtitle, iconSymbol: icon,
                 isChecked: checked, isEnabled: enabled, handler: handler, kind: .row)
        }

        static func separator() -> Item {
            Item(title: "", subtitle: nil, iconSymbol: nil,
                 isChecked: false, isEnabled: false, handler: nil, kind: .separator)
        }

        static func header(_ title: String) -> Item {
            Item(title: title, subtitle: nil, iconSymbol: nil,
                 isChecked: false, isEnabled: false, handler: nil, kind: .header)
        }
    }

    // MARK: - State

    private var items: [Item] = []
    private var popover: NSPopover?

    // MARK: - Builder API

    @discardableResult
    func add(_ item: Item) -> Self { items.append(item); return self }

    @discardableResult
    func addRow(
        _ title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> Self {
        items.append(.row(title, subtitle: subtitle, icon: icon, checked: checked, enabled: enabled, handler: handler))
        return self
    }

    @discardableResult
    func addSeparator() -> Self { items.append(.separator()); return self }

    @discardableResult
    func addHeader(_ title: String) -> Self { items.append(.header(title)); return self }

    // MARK: - Presentation

    func show(relativeTo view: NSView, preferredEdge: NSRectEdge = .maxY) {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: ThemeManager.shared.current.isLight ? .aqua : .darkAqua)

        let vc = ThemedDropdownViewController(items: items, onPick: { [weak pop] handler in
            pop?.performClose(nil)
            // Defer so the popover animation completes before we act.
            DispatchQueue.main.async { handler() }
        })
        pop.contentViewController = vc

        pop.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
        popover = pop
    }
}

// MARK: - Content view controller

private final class ThemedDropdownViewController: NSViewController {
    private let items: [ThemedDropdown.Item]
    private let onPick: (@escaping () -> Void) -> Void
    private let stack = NSStackView()

    init(items: [ThemedDropdown.Item], onPick: @escaping (@escaping () -> Void) -> Void) {
        self.items = items
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let minWidth: CGFloat = 240
    private static let maxWidth: CGFloat = 360
    private static let maxHeight: CGFloat = 320

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.elevated.cgColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.alignment = .leading

        for item in items {
            let view = makeItemView(item)
            stack.addArrangedSubview(view)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = ThinScroller()

        // Document view hosts the row stack and owns the single hover-tracking area.
        let document = DropdownDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),

            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        for view in stack.arrangedSubviews {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true
        }

        self.view = container

        container.layoutSubtreeIfNeeded()
        let naturalHeight = stack.fittingSize.height
        let naturalWidth = stack.fittingSize.width
        let width = min(max(naturalWidth + 12, Self.minWidth), Self.maxWidth)
        let height = min(naturalHeight, Self.maxHeight)
        preferredContentSize = NSSize(width: width, height: height)
    }

    private func makeItemView(_ item: ThemedDropdown.Item) -> NSView {
        switch item.kind {
        case .separator:
            return DropdownSeparator()
        case .header:
            return DropdownHeader(title: item.title)
        case .row:
            let row = DropdownRow(item: item)
            row.onClick = { [weak self] in
                guard let handler = item.handler else { return }
                self?.onPick(handler)
            }
            return row
        }
    }
}

// MARK: - Row

fileprivate final class DropdownRow: NSView {
    private let hoverBg = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()

    private(set) var isHovered = false
    private let item: ThemedDropdown.Item

    var onClick: (() -> Void)?

    init(item: ThemedDropdown.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        hoverBg.translatesAutoresizingMaskIntoConstraints = false
        hoverBg.wantsLayer = true
        hoverBg.layer?.cornerRadius = Theme.CornerRadius.element
        hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverBg)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = Theme.secondaryText
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let symbol = item.iconSymbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        }
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.Fonts.body(size: 12)
        titleLabel.textColor = item.isEnabled ? Theme.primaryText : Theme.quaternaryText
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.stringValue = item.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Theme.Fonts.body(size: 10)
        subtitleLabel.textColor = Theme.tertiaryText
        subtitleLabel.backgroundColor = .clear
        subtitleLabel.isBezeled = false
        subtitleLabel.isEditable = false
        subtitleLabel.isSelectable = false
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.isHidden = item.subtitle == nil
        addSubview(subtitleLabel)

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        checkView.contentTintColor = Theme.primary
        checkView.imageScaling = .scaleProportionallyUpOrDown
        checkView.isHidden = !item.isChecked
        addSubview(checkView)

        let iconOffset: CGFloat = item.iconSymbol == nil ? 8 : 26

        NSLayoutConstraint.activate([
            hoverBg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            hoverBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverBg.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: iconOffset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkView.leadingAnchor, constant: -8),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 12),
            checkView.heightAnchor.constraint(equalToConstant: 12),

            heightAnchor.constraint(equalToConstant: 26),
        ])

        iconView.isHidden = item.iconSymbol == nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard item.isEnabled else { return }
        onClick?()
    }

    func setHovered(_ hovered: Bool) {
        guard item.isEnabled else {
            hoverBg.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        isHovered = hovered
        hoverBg.layer?.backgroundColor = hovered ? Theme.hoverBg.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = item.isEnabled ? Theme.primaryText : Theme.quaternaryText
    }
}

// MARK: - Separator

private final class DropdownSeparator: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Dropdown document view
//
// Flipped so rows lay out top-down. Owns a single tracking area that captures
// mouseMoved for the whole list — individual rows don't track hover themselves.
// This mirrors the pattern used by HoverTableView in the history list and
// guarantees exactly one hovered row at any time.

private final class DropdownDocumentView: NSView {
    override var isFlipped: Bool { true }

    private var trackingAreaRef: NSTrackingArea?
    private weak var hoveredRow: DropdownRow?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHoveredRow(at: convert(event.locationInWindow, from: nil))
    }

    private func updateHoveredRow(at point: NSPoint) {
        let row = subviews.compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? DropdownRow }
            .first(where: { $0.frame.contains(convert(point, to: $0.superview)) })
        setHoveredRow(row)
    }

    private func setHoveredRow(_ row: DropdownRow?) {
        guard row !== hoveredRow else { return }
        hoveredRow?.setHovered(false)
        hoveredRow = row
        row?.setHovered(true)
    }
}

// MARK: - Header

private final class DropdownHeader: NSView {
    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.label(size: 10)
        label.textColor = Theme.tertiaryText
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
