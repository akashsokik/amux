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
