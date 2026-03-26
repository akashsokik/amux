import AppKit

/// An NSButton subclass with consistent hover/active states matching the native editor style.
/// Default: muted color. Hover: brighter color + subtle background. Active: full brightness.
class DimIconButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private let hoverBgLayer = CALayer()

    private(set) var isHoveredState = false {
        didSet { refreshDimState() }
    }

    /// Set to `true` for the currently-selected / active icon (e.g. active sidebar tab).
    var isActiveState = false {
        didSet { refreshDimState() }
    }

    override var isHighlighted: Bool {
        didSet {
            if !isHighlighted && oldValue {
                // On mouseUp, re-check whether the cursor is still inside
                // before falling back to the default state. Layout changes
                // during the action (e.g. sidebar toggle animation) can
                // spuriously fire mouseExited, causing a visible flicker.
                if let window = window {
                    let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    isHoveredState = bounds.contains(loc)
                }
            }
            refreshDimState()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .accessoryBarAction
        focusRingType = .none
        wantsLayer = true
        hoverBgLayer.cornerRadius = Theme.CornerRadius.element
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
        layer?.insertSublayer(hoverBgLayer, at: 0)
    }

    override func layout() {
        super.layout()
        // Always use a square hover background, centered in bounds
        let side = min(bounds.width, bounds.height)
        let squareRect = NSRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        CALayer.performWithoutAnimation {
            hoverBgLayer.frame = squareRect
        }
    }

    func refreshDimState() {
        hoverBgLayer.cornerRadius = Theme.CornerRadius.element

        if isActiveState {
            contentTintColor = Theme.primaryText
            alphaValue = 1.0
            CALayer.performWithoutAnimation {
                hoverBgLayer.backgroundColor = Theme.activeBg.cgColor
            }
        } else if isHighlighted {
            // Momentary press: brighten tint only, no background flash
            contentTintColor = Theme.primaryText
            alphaValue = 1.0
        } else if isHoveredState {
            contentTintColor = Theme.secondaryText
            alphaValue = 1.0
            CALayer.performWithoutAnimation {
                hoverBgLayer.backgroundColor = Theme.hoverBg.cgColor
            }
        } else {
            contentTintColor = Theme.tertiaryText
            alphaValue = 1.0
            CALayer.performWithoutAnimation {
                hoverBgLayer.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHoveredState = true }

    override func mouseExited(with event: NSEvent) {
        // Layout animations (e.g. sidebar toggle) can fire spurious
        // mouseExited events. Verify the cursor is actually outside.
        guard let window = window else { isHoveredState = false; return }
        let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(loc) {
            isHoveredState = false
        }
    }
}

// MARK: - CALayer animation suppression helper

extension CALayer {
    static func performWithoutAnimation(_ block: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block()
        CATransaction.commit()
    }
}
