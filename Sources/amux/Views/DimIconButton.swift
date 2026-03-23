import AppKit

/// An NSButton subclass that appears dim by default and brightens on hover or when active.
class DimIconButton: NSButton {
    private var hoverArea: NSTrackingArea?

    private(set) var isHoveredState = false {
        didSet { refreshDimState() }
    }

    /// Set to `true` for the currently-selected / active icon (e.g. active sidebar tab).
    var isActiveState = false {
        didSet { refreshDimState() }
    }

    override var isHighlighted: Bool {
        didSet { refreshDimState() }
    }

    func refreshDimState() {
        if isActiveState || isHighlighted {
            contentTintColor = Theme.primaryText
            alphaValue = 1.0
        } else if isHoveredState {
            contentTintColor = Theme.secondaryText
            alphaValue = 1.0
        } else {
            contentTintColor = Theme.quaternaryText
            alphaValue = 0.5
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
    override func mouseExited(with event: NSEvent) { isHoveredState = false }
}
