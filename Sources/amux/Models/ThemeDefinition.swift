import AppKit

struct ThemeDefinition {
    let id: String
    let name: String
    let isLight: Bool

    // Surfaces
    let surface: NSColor
    let surfaceContainerLowest: NSColor
    let surfaceContainerLow: NSColor
    let surfaceContainerHigh: NSColor
    let surfaceContainerHighest: NSColor
    let surfaceBright: NSColor

    // Accent
    let primary: NSColor
    let primaryContainer: NSColor
    let secondary: NSColor
    let onPrimary: NSColor

    // Text
    let onSurface: NSColor
    let onSurfaceVariant: NSColor
    let tertiaryText: NSColor
    let quaternaryText: NSColor

    // Borders
    let outline: NSColor
    let outlineVariant: NSColor

    // Interactive
    let hoverBg: NSColor
    let activeBg: NSColor

    // Corner radii
    let cornerRadiusBadge: CGFloat
    let cornerRadiusElement: CGFloat
    let cornerRadiusCard: CGFloat
}

// MARK: - Built-in Themes

extension ThemeDefinition {

    // ───────────────────────────────────────────────
    // MARK: Default (neutral monochrome)
    // ───────────────────────────────────────────────

    static let kineticMonolith = ThemeDefinition(
        id: "kinetic-monolith",
        name: "Default",
        isLight: false,
        surface: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.075, green: 0.075, blue: 0.075, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.133, green: 0.133, blue: 0.133, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.165, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.173, alpha: 1.0),
        primary: NSColor(srgbRed: 0.561, green: 0.961, blue: 1.0, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.0, green: 0.933, blue: 0.988, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.0, green: 0.863, blue: 0.988, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.0, green: 0.365, blue: 0.388, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.831, green: 0.831, blue: 0.831, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.671, green: 0.671, blue: 0.671, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.333, green: 0.333, blue: 0.333, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.251, green: 0.251, blue: 0.251, alpha: 1.0),
        outline: NSColor(srgbRed: 0.282, green: 0.282, blue: 0.282, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.282, green: 0.282, blue: 0.282, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let kineticMonolithLight = ThemeDefinition(
        id: "kinetic-monolith-light",
        name: "Default Light",
        isLight: true,
        surface: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.941, green: 0.941, blue: 0.941, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.902, green: 0.902, blue: 0.902, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.863, green: 0.863, blue: 0.863, alpha: 1.0),
        primary: NSColor(srgbRed: 0.0, green: 0.500, blue: 0.545, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.0, green: 0.600, blue: 0.650, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.0, green: 0.440, blue: 0.510, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.400, green: 0.400, blue: 0.400, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.600, green: 0.600, blue: 0.600, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.733, green: 0.733, blue: 0.733, alpha: 1.0),
        outline: NSColor(srgbRed: 0.878, green: 0.878, blue: 0.878, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.878, green: 0.878, blue: 0.878, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // ───────────────────────────────────────────────
    // MARK: Dusk (warm pastel, cozy mood)
    // ───────────────────────────────────────────────

    static let dusk = ThemeDefinition(
        id: "dusk",
        name: "Dusk",
        isLight: false,
        surface: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.149, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.192, green: 0.196, blue: 0.267, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.224, green: 0.227, blue: 0.302, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.255, green: 0.259, blue: 0.337, alpha: 1.0),
        primary: NSColor(srgbRed: 0.537, green: 0.706, blue: 0.980, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.475, green: 0.643, blue: 0.918, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.961, green: 0.663, blue: 0.722, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.118, green: 0.180, blue: 0.353, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.804, green: 0.839, blue: 0.957, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.651, green: 0.678, blue: 0.784, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.424, green: 0.439, blue: 0.525, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.345, green: 0.357, blue: 0.439, alpha: 1.0),
        outline: NSColor(srgbRed: 0.271, green: 0.278, blue: 0.353, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.271, green: 0.278, blue: 0.353, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let duskLight = ThemeDefinition(
        id: "dusk-light",
        name: "Dusk Light",
        isLight: true,
        surface: NSColor(srgbRed: 0.937, green: 0.945, blue: 0.961, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.957, green: 0.961, blue: 0.973, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.937, green: 0.945, blue: 0.961, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.898, green: 0.910, blue: 0.933, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.863, green: 0.875, blue: 0.902, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.831, green: 0.843, blue: 0.875, alpha: 1.0),
        primary: NSColor(srgbRed: 0.118, green: 0.400, blue: 0.749, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.157, green: 0.451, blue: 0.808, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.820, green: 0.286, blue: 0.400, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.298, green: 0.310, blue: 0.412, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.451, green: 0.463, blue: 0.557, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.580, green: 0.592, blue: 0.671, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.694, green: 0.706, blue: 0.765, alpha: 1.0),
        outline: NSColor(srgbRed: 0.784, green: 0.796, blue: 0.843, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.784, green: 0.796, blue: 0.843, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // ───────────────────────────────────────────────
    // MARK: Fjord (arctic cool, muted blues)
    // ───────────────────────────────────────────────

    static let fjord = ThemeDefinition(
        id: "fjord",
        name: "Fjord",
        isLight: false,
        surface: NSColor(srgbRed: 0.180, green: 0.204, blue: 0.251, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.149, green: 0.173, blue: 0.216, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.180, green: 0.204, blue: 0.251, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.231, green: 0.259, blue: 0.322, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.267, green: 0.298, blue: 0.369, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.298, green: 0.337, blue: 0.412, alpha: 1.0),
        primary: NSColor(srgbRed: 0.533, green: 0.753, blue: 0.816, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.506, green: 0.718, blue: 0.788, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.663, green: 0.776, blue: 0.855, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.118, green: 0.220, blue: 0.267, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.647, green: 0.694, blue: 0.761, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.380, green: 0.431, blue: 0.533, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.298, green: 0.345, blue: 0.435, alpha: 1.0),
        outline: NSColor(srgbRed: 0.267, green: 0.298, blue: 0.369, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.267, green: 0.298, blue: 0.369, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let fjordLight = ThemeDefinition(
        id: "fjord-light",
        name: "Fjord Light",
        isLight: true,
        surface: NSColor(srgbRed: 0.925, green: 0.937, blue: 0.957, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.973, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.925, green: 0.937, blue: 0.957, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.878, green: 0.898, blue: 0.929, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.808, green: 0.835, blue: 0.886, alpha: 1.0),
        primary: NSColor(srgbRed: 0.318, green: 0.557, blue: 0.635, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.365, green: 0.604, blue: 0.682, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.373, green: 0.506, blue: 0.620, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.180, green: 0.220, blue: 0.286, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.322, green: 0.369, blue: 0.451, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.478, green: 0.525, blue: 0.600, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.620, green: 0.659, blue: 0.722, alpha: 1.0),
        outline: NSColor(srgbRed: 0.749, green: 0.780, blue: 0.831, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.749, green: 0.780, blue: 0.831, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // ───────────────────────────────────────────────
    // MARK: Neon (deep indigo, nocturnal)
    // ───────────────────────────────────────────────

    static let neon = ThemeDefinition(
        id: "neon",
        name: "Neon",
        isLight: false,
        surface: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.149, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.118, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.149, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.141, green: 0.157, blue: 0.231, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.176, green: 0.192, blue: 0.271, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.208, green: 0.224, blue: 0.310, alpha: 1.0),
        primary: NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.424, green: 0.584, blue: 0.925, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.478, green: 0.808, blue: 0.710, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.133, green: 0.192, blue: 0.400, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.753, green: 0.792, blue: 0.961, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.604, green: 0.647, blue: 0.808, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.384, green: 0.412, blue: 0.545, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.290, green: 0.314, blue: 0.427, alpha: 1.0),
        outline: NSColor(srgbRed: 0.220, green: 0.243, blue: 0.349, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.220, green: 0.243, blue: 0.349, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let neonLight = ThemeDefinition(
        id: "neon-light",
        name: "Neon Light",
        isLight: true,
        surface: NSColor(srgbRed: 0.961, green: 0.965, blue: 0.984, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.976, green: 0.980, blue: 0.992, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.961, green: 0.965, blue: 0.984, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.922, green: 0.929, blue: 0.957, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.878, green: 0.886, blue: 0.922, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.835, green: 0.843, blue: 0.886, alpha: 1.0),
        primary: NSColor(srgbRed: 0.290, green: 0.431, blue: 0.808, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.337, green: 0.478, blue: 0.855, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.259, green: 0.600, blue: 0.502, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.212, green: 0.224, blue: 0.329, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.373, green: 0.392, blue: 0.518, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.529, green: 0.549, blue: 0.655, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.667, green: 0.682, blue: 0.765, alpha: 1.0),
        outline: NSColor(srgbRed: 0.776, green: 0.792, blue: 0.855, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.776, green: 0.792, blue: 0.855, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // ───────────────────────────────────────────────
    // MARK: Ember (warm earth tones)
    // ───────────────────────────────────────────────

    static let ember = ThemeDefinition(
        id: "ember",
        name: "Ember",
        isLight: false,
        surface: NSColor(srgbRed: 0.157, green: 0.149, blue: 0.141, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.125, green: 0.118, blue: 0.110, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.157, green: 0.149, blue: 0.141, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.220, green: 0.208, blue: 0.196, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.271, green: 0.255, blue: 0.243, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.310, green: 0.294, blue: 0.278, alpha: 1.0),
        primary: NSColor(srgbRed: 0.843, green: 0.600, blue: 0.129, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.780, green: 0.541, blue: 0.082, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.820, green: 0.525, blue: 0.180, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.220, green: 0.165, blue: 0.024, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.922, green: 0.859, blue: 0.698, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.659, green: 0.600, blue: 0.518, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.451, green: 0.416, blue: 0.365, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.349, green: 0.322, blue: 0.282, alpha: 1.0),
        outline: NSColor(srgbRed: 0.310, green: 0.290, blue: 0.259, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.310, green: 0.290, blue: 0.259, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let emberLight = ThemeDefinition(
        id: "ember-light",
        name: "Ember Light",
        isLight: true,
        surface: NSColor(srgbRed: 0.984, green: 0.957, blue: 0.906, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.992, green: 0.973, blue: 0.937, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.984, green: 0.957, blue: 0.906, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.949, green: 0.918, blue: 0.859, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.914, green: 0.882, blue: 0.820, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.878, green: 0.847, blue: 0.784, alpha: 1.0),
        primary: NSColor(srgbRed: 0.690, green: 0.478, blue: 0.059, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.753, green: 0.541, blue: 0.098, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.659, green: 0.380, blue: 0.047, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.235, green: 0.220, blue: 0.169, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.400, green: 0.373, blue: 0.318, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.565, green: 0.541, blue: 0.486, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.694, green: 0.671, blue: 0.624, alpha: 1.0),
        outline: NSColor(srgbRed: 0.816, green: 0.792, blue: 0.741, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.816, green: 0.792, blue: 0.741, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // ───────────────────────────────────────────────
    // MARK: Amethyst (purple-tinted, vibrant)
    // ───────────────────────────────────────────────

    static let amethyst = ThemeDefinition(
        id: "amethyst",
        name: "Amethyst",
        isLight: false,
        surface: NSColor(srgbRed: 0.157, green: 0.165, blue: 0.212, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.125, green: 0.133, blue: 0.176, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.157, green: 0.165, blue: 0.212, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.204, green: 0.216, blue: 0.275, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.247, green: 0.259, blue: 0.325, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.282, green: 0.298, blue: 0.369, alpha: 1.0),
        primary: NSColor(srgbRed: 1.0, green: 0.475, blue: 0.776, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.941, green: 0.396, blue: 0.714, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.545, green: 0.914, blue: 0.992, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.380, green: 0.098, blue: 0.243, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.973, green: 0.973, blue: 0.949, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.745, green: 0.745, blue: 0.722, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.447, green: 0.455, blue: 0.478, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.337, green: 0.345, blue: 0.373, alpha: 1.0),
        outline: NSColor(srgbRed: 0.278, green: 0.290, blue: 0.341, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.278, green: 0.290, blue: 0.341, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let amethystLight = ThemeDefinition(
        id: "amethyst-light",
        name: "Amethyst Light",
        isLight: true,
        surface: NSColor(srgbRed: 0.976, green: 0.969, blue: 0.984, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.988, green: 0.984, blue: 0.992, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.976, green: 0.969, blue: 0.984, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.937, green: 0.929, blue: 0.949, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.898, green: 0.890, blue: 0.914, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.863, green: 0.855, blue: 0.882, alpha: 1.0),
        primary: NSColor(srgbRed: 0.835, green: 0.298, blue: 0.596, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.882, green: 0.345, blue: 0.643, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.278, green: 0.592, blue: 0.682, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.176, green: 0.169, blue: 0.208, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.345, green: 0.337, blue: 0.392, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.525, green: 0.518, blue: 0.569, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.675, green: 0.667, blue: 0.710, alpha: 1.0),
        outline: NSColor(srgbRed: 0.800, green: 0.792, blue: 0.824, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.800, green: 0.792, blue: 0.824, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // ───────────────────────────────────────────────
    // MARK: Verdant (forest green, nature)
    // ───────────────────────────────────────────────

    static let verdant = ThemeDefinition(
        id: "verdant",
        name: "Verdant",
        isLight: false,
        surface: NSColor(srgbRed: 0.114, green: 0.133, blue: 0.118, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.086, green: 0.102, blue: 0.090, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.114, green: 0.133, blue: 0.118, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.161, green: 0.184, blue: 0.169, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.204, green: 0.231, blue: 0.212, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.235, green: 0.267, blue: 0.247, alpha: 1.0),
        primary: NSColor(srgbRed: 0.608, green: 0.804, blue: 0.553, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.533, green: 0.737, blue: 0.486, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.824, green: 0.706, blue: 0.467, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 0.114, green: 0.243, blue: 0.082, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.847, green: 0.882, blue: 0.855, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.643, green: 0.694, blue: 0.659, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.400, green: 0.451, blue: 0.420, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.310, green: 0.353, blue: 0.329, alpha: 1.0),
        outline: NSColor(srgbRed: 0.255, green: 0.290, blue: 0.267, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.255, green: 0.290, blue: 0.267, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.08),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    static let verdantLight = ThemeDefinition(
        id: "verdant-light",
        name: "Verdant Light",
        isLight: true,
        surface: NSColor(srgbRed: 0.949, green: 0.965, blue: 0.949, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.965, green: 0.976, blue: 0.965, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.949, green: 0.965, blue: 0.949, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.910, green: 0.933, blue: 0.914, alpha: 1.0),
        surfaceContainerHighest: NSColor(srgbRed: 0.871, green: 0.898, blue: 0.878, alpha: 1.0),
        surfaceBright: NSColor(srgbRed: 0.835, green: 0.867, blue: 0.843, alpha: 1.0),
        primary: NSColor(srgbRed: 0.286, green: 0.545, blue: 0.220, alpha: 1.0),
        primaryContainer: NSColor(srgbRed: 0.337, green: 0.604, blue: 0.267, alpha: 1.0),
        secondary: NSColor(srgbRed: 0.573, green: 0.459, blue: 0.216, alpha: 1.0),
        onPrimary: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        onSurface: NSColor(srgbRed: 0.133, green: 0.176, blue: 0.141, alpha: 1.0),
        onSurfaceVariant: NSColor(srgbRed: 0.310, green: 0.369, blue: 0.322, alpha: 1.0),
        tertiaryText: NSColor(srgbRed: 0.478, green: 0.537, blue: 0.494, alpha: 1.0),
        quaternaryText: NSColor(srgbRed: 0.631, green: 0.678, blue: 0.647, alpha: 1.0),
        outline: NSColor(srgbRed: 0.765, green: 0.800, blue: 0.776, alpha: 1.0),
        outlineVariant: NSColor(srgbRed: 0.765, green: 0.800, blue: 0.776, alpha: 0.60),
        hoverBg: NSColor(white: 0.0, alpha: 0.04),
        activeBg: NSColor(white: 0.0, alpha: 0.07),
        cornerRadiusBadge: 4,
        cornerRadiusElement: 4,
        cornerRadiusCard: 8
    )

    // MARK: - All Built-in Themes

    static let allBuiltIn: [ThemeDefinition] = [
        .kineticMonolith,
        .kineticMonolithLight,
        .dusk,
        .duskLight,
        .fjord,
        .fjordLight,
        .neon,
        .neonLight,
        .ember,
        .emberLight,
        .amethyst,
        .amethystLight,
        .verdant,
        .verdantLight,
    ]

    /// Returns the dark/light companion of this theme (e.g. "Fjord" <-> "Fjord Light").
    var companion: ThemeDefinition? {
        let companionID: String
        if id.hasSuffix("-light") {
            companionID = String(id.dropLast("-light".count))
        } else {
            companionID = id + "-light"
        }
        return ThemeDefinition.allBuiltIn.first { $0.id == companionID }
    }

    /// The family name shared by both dark and light variants (e.g. "Fjord").
    var familyName: String {
        name.replacingOccurrences(of: " Light", with: "")
    }
}
