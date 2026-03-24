import AppKit

/// A frosted-glass background using NSVisualEffectView.
/// Add as the lowest subview of any pane that should blur its backdrop.
class GlassBackgroundView: NSVisualEffectView {
    /// Tint layer drawn on top of the blur to match the theme surface color.
    private let tintLayer = CALayer()

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blending: NSVisualEffectView.BlendingMode = .withinWindow
    ) {
        super.init(frame: .zero)
        self.material = material
        self.blendingMode = blending
        self.state = .active
        self.wantsLayer = true

        tintLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(tintLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tintLayer.frame = bounds
    }

    /// Update the tint overlay color (a semi-transparent version of the theme surface).
    func setTint(_ color: NSColor, opacity: CGFloat = 0.55) {
        tintLayer.backgroundColor = color.withAlphaComponent(opacity).cgColor
    }
}
