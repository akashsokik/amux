import AppKit
import CoreText

enum Theme {
    // MARK: - Theme Change Notification

    static let didChangeNotification = Notification.Name("ThemeDidChange")

    // MARK: - Current theme forwarding

    private static var current: ThemeDefinition { ThemeManager.shared.current }
    static var isLight: Bool { current.isLight }

    // MARK: - Surface hierarchy

    static var surface: NSColor { current.surface }
    static var surfaceContainerLowest: NSColor { current.surfaceContainerLowest }
    static var surfaceContainerLow: NSColor { current.surfaceContainerLow }
    static var surfaceContainerHigh: NSColor { current.surfaceContainerHigh }
    static var surfaceContainerHighest: NSColor { current.surfaceContainerHighest }
    static var surfaceBright: NSColor { current.surfaceBright }

    // MARK: - Primary / Accent

    static var primary: NSColor { current.primary }
    static var primaryContainer: NSColor { current.primaryContainer }
    static var secondary: NSColor { current.secondary }
    static var onPrimary: NSColor { current.onPrimary }

    // MARK: - Text hierarchy

    static var onSurface: NSColor { current.onSurface }
    static var onSurfaceVariant: NSColor { current.onSurfaceVariant }

    // MARK: - Outline / Ghost borders

    static var outline: NSColor { current.outline }
    static var outlineVariant: NSColor { current.outlineVariant }

    // MARK: - Interactive states

    static var hoverBg: NSColor { current.hoverBg }
    static var activeBg: NSColor { current.activeBg }

    // MARK: - Backward-compatible aliases

    static var background: NSColor { surface }
    static var panelBg: NSColor { surface }
    static var elevated: NSColor { surfaceContainerHigh }
    static var sidebarBg: NSColor { surfaceContainerLow }
    static var primaryText: NSColor { onSurface }
    static var secondaryText: NSColor { onSurfaceVariant }
    static var tertiaryText: NSColor { current.tertiaryText }
    static var quaternaryText: NSColor { current.quaternaryText }
    static var borderPrimary: NSColor { outlineVariant }
    static var borderSecondary: NSColor { current.outline.withAlphaComponent(0.25) }
    static var borderTranslucent: NSColor { NSColor(white: current.isLight ? 0.0 : 1.0, alpha: 0.06) }
    static var accent: NSColor { primary }
    static var accentUI: NSColor { primary }

    // MARK: - Corner Radius

    enum CornerRadius {
        static var badge: CGFloat { ThemeManager.shared.current.cornerRadiusBadge }
        static var element: CGFloat { ThemeManager.shared.current.cornerRadiusElement }
        static var card: CGFloat { ThemeManager.shared.current.cornerRadiusCard }
    }

    // MARK: - Animation

    enum Animation {
        static let quick: TimeInterval = 0.1
        static let standard: TimeInterval = 0.25
    }

    // MARK: - Fonts (Space Grotesk with system fallback)

    enum Fonts {
        private static let familyName = "Space Grotesk"

        static func display(size: CGFloat) -> NSFont {
            NSFont(name: "\(familyName) Bold", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .bold)
        }

        static func headline(size: CGFloat) -> NSFont {
            NSFont(name: "\(familyName) Medium", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .medium)
        }

        static func body(size: CGFloat) -> NSFont {
            NSFont(name: familyName, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        }

        static func label(size: CGFloat) -> NSFont {
            NSFont(name: "\(familyName) Medium", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .medium)
        }
    }

    // MARK: - Font Registration

    static func registerFonts() {
        let fontNames = [
            "SpaceGrotesk-Regular",
            "SpaceGrotesk-Medium",
            "SpaceGrotesk-Bold",
        ]

        let bundle = Bundle.main
        for name in fontNames {
            if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                var errorRef: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef) {
                    if let error = errorRef?.takeRetainedValue() {
                        print("[Theme] Failed to register font \(name): \(error)")
                    }
                }
            } else {
                // Try executable-relative path (SPM executables)
                let execURL = Bundle.main.executableURL?.deletingLastPathComponent()
                let candidates = [
                    execURL?.appendingPathComponent("Fonts/\(name).ttf"),
                    execURL?.appendingPathComponent("../Resources/Fonts/\(name).ttf"),
                    execURL?.deletingLastPathComponent().appendingPathComponent("Resources/Fonts/\(name).ttf"),
                ]
                for candidate in candidates {
                    guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
                    var errorRef: Unmanaged<CFError>?
                    if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef) {
                        break
                    }
                }
            }
        }
    }
}

// MARK: - Thin overlay scroller

class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        return 6
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }
        let inset = knobRect.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 2, yRadius: 2)
        NSColor(white: ThemeManager.shared.current.isLight ? 0.0 : 1.0, alpha: 0.15).setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track
    }
}

// MARK: - NSColor hex init

extension NSColor {
    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
