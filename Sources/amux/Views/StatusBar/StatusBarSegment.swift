import AppKit

enum SegmentPosition {
    case left, center, right
}

protocol StatusBarSegment: AnyObject {
    var id: String { get }
    var label: String { get }
    var icon: String { get }
    var position: SegmentPosition { get }
    var refreshInterval: TimeInterval { get }
    func render() -> NSView
    func update()
}

/// A stack view that dims its icon by default and brightens it on hover.
class HoverableSegmentStack: NSStackView {
    weak var segmentIcon: NSImageView?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        segmentIcon?.alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        segmentIcon?.alphaValue = 0.5
    }
}
