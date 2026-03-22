import AppKit

protocol DividerViewDelegate: AnyObject {
    func dividerView(_ divider: DividerView, didDragBy delta: CGFloat)
    func dividerViewDidFinishDrag(_ divider: DividerView)
}

class DividerView: NSView {
    let splitNodeID: UUID
    var direction: SplitDirection
    weak var delegate: DividerViewDelegate?

    private var isDragging = false
    private var isHovered = false
    private var dragStartPoint: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    /// The visual thickness of the divider line.
    private let lineThickness: CGFloat = 1
    /// The total hit-target thickness (3px padding on each side of the 1px line).
    static let hitTargetThickness: CGFloat = 7

    init(splitNodeID: UUID, direction: SplitDirection) {
        self.splitNodeID = splitNodeID
        self.direction = direction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if isDragging || isHovered {
            color = Theme.primary.withAlphaComponent(0.20)
        } else {
            color = Theme.outlineVariant
        }
        color.setFill()

        let lineRect: NSRect
        switch direction {
        case .vertical:
            // Vertical split: divider is a vertical line in the center of the hit target
            let centerX = bounds.midX - (lineThickness / 2)
            lineRect = NSRect(x: centerX, y: bounds.minY, width: lineThickness, height: bounds.height)
        case .horizontal:
            // Horizontal split: divider is a horizontal line in the center of the hit target
            let centerY = bounds.midY - (lineThickness / 2)
            lineRect = NSRect(x: bounds.minX, y: centerY, width: bounds.width, height: lineThickness)
        }
        lineRect.fill()
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        discardCursorRects()
        switch direction {
        case .vertical:
            addCursorRect(bounds, cursor: .resizeLeftRight)
        case .horizontal:
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }

    // MARK: - Tracking area for hover

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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    // MARK: - Drag handling

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let current = event.locationInWindow
        let delta: CGFloat
        switch direction {
        case .vertical:
            delta = current.x - dragStartPoint.x
        case .horizontal:
            delta = -(current.y - dragStartPoint.y)
        }
        dragStartPoint = current
        delegate?.dividerView(self, didDragBy: delta)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        needsDisplay = true
        delegate?.dividerViewDidFinishDrag(self)
    }
}
