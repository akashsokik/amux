import AppKit

struct ThemeDefinition {
    let id: String
    let name: String

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
    static let kineticMonolith = ThemeDefinition(
        id: "kinetic-monolith",
        name: "Kinetic Monolith",
        surface: NSColor(srgbRed: 0.055, green: 0.055, blue: 0.055, alpha: 1.0),
        surfaceContainerLowest: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
        surfaceContainerLow: NSColor(srgbRed: 0.075, green: 0.075, blue: 0.075, alpha: 1.0),
        surfaceContainerHigh: NSColor(srgbRed: 0.122, green: 0.122, blue: 0.122, alpha: 1.0),
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
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    static let obsidian = ThemeDefinition(
        id: "obsidian",
        name: "Obsidian",
        surface: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1.0),        // #1a1a1a
        surfaceContainerLowest: NSColor(srgbRed: 0.051, green: 0.051, blue: 0.051, alpha: 1.0), // #0d0d0d
        surfaceContainerLow: NSColor(srgbRed: 0.125, green: 0.125, blue: 0.125, alpha: 1.0),    // #202020
        surfaceContainerHigh: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.173, alpha: 1.0),   // #2c2c2c
        surfaceContainerHighest: NSColor(srgbRed: 0.216, green: 0.216, blue: 0.216, alpha: 1.0), // #373737
        surfaceBright: NSColor(srgbRed: 0.235, green: 0.235, blue: 0.235, alpha: 1.0),          // #3c3c3c
        primary: NSColor(srgbRed: 1.0, green: 0.702, blue: 0.278, alpha: 1.0),                  // #ffb347
        primaryContainer: NSColor(srgbRed: 0.886, green: 0.580, blue: 0.153, alpha: 1.0),       // #e29427
        secondary: NSColor(srgbRed: 1.0, green: 0.843, blue: 0.502, alpha: 1.0),                // #ffd780
        onPrimary: NSColor(srgbRed: 0.298, green: 0.180, blue: 0.0, alpha: 1.0),                // #4c2e00
        onSurface: NSColor(srgbRed: 0.855, green: 0.835, blue: 0.808, alpha: 1.0),              // #dad5ce
        onSurfaceVariant: NSColor(srgbRed: 0.690, green: 0.671, blue: 0.647, alpha: 1.0),       // #b0aba5
        tertiaryText: NSColor(srgbRed: 0.400, green: 0.380, blue: 0.360, alpha: 1.0),           // #66615c
        quaternaryText: NSColor(srgbRed: 0.302, green: 0.286, blue: 0.271, alpha: 1.0),         // #4d4945
        outline: NSColor(srgbRed: 0.325, green: 0.310, blue: 0.294, alpha: 1.0),                // #534f4b
        outlineVariant: NSColor(srgbRed: 0.325, green: 0.310, blue: 0.294, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    static let phosphor = ThemeDefinition(
        id: "phosphor",
        name: "Phosphor",
        surface: NSColor(srgbRed: 0.039, green: 0.071, blue: 0.039, alpha: 1.0),               // #0a120a
        surfaceContainerLowest: NSColor(srgbRed: 0.020, green: 0.039, blue: 0.020, alpha: 1.0), // #050a05
        surfaceContainerLow: NSColor(srgbRed: 0.059, green: 0.098, blue: 0.059, alpha: 1.0),    // #0f190f
        surfaceContainerHigh: NSColor(srgbRed: 0.098, green: 0.149, blue: 0.098, alpha: 1.0),   // #192619
        surfaceContainerHighest: NSColor(srgbRed: 0.137, green: 0.196, blue: 0.137, alpha: 1.0), // #233223
        surfaceBright: NSColor(srgbRed: 0.157, green: 0.216, blue: 0.157, alpha: 1.0),          // #283728
        primary: NSColor(srgbRed: 0.224, green: 1.0, blue: 0.078, alpha: 1.0),                  // #39ff14
        primaryContainer: NSColor(srgbRed: 0.180, green: 0.820, blue: 0.063, alpha: 1.0),       // #2ed110
        secondary: NSColor(srgbRed: 0.400, green: 1.0, blue: 0.302, alpha: 1.0),                // #66ff4d
        onPrimary: NSColor(srgbRed: 0.0, green: 0.275, blue: 0.0, alpha: 1.0),                  // #004600
        onSurface: NSColor(srgbRed: 0.749, green: 0.851, blue: 0.749, alpha: 1.0),              // #bfd9bf
        onSurfaceVariant: NSColor(srgbRed: 0.576, green: 0.690, blue: 0.576, alpha: 1.0),       // #93b093
        tertiaryText: NSColor(srgbRed: 0.275, green: 0.373, blue: 0.275, alpha: 1.0),           // #465f46
        quaternaryText: NSColor(srgbRed: 0.196, green: 0.275, blue: 0.196, alpha: 1.0),         // #324632
        outline: NSColor(srgbRed: 0.224, green: 0.322, blue: 0.224, alpha: 1.0),                // #395239
        outlineVariant: NSColor(srgbRed: 0.224, green: 0.322, blue: 0.224, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    // Deep navy base, electric violet accent
    static let nightOwl = ThemeDefinition(
        id: "night-owl",
        name: "Night Owl",
        surface: NSColor(srgbRed: 0.012, green: 0.043, blue: 0.082, alpha: 1.0),               // #010b15
        surfaceContainerLowest: NSColor(srgbRed: 0.004, green: 0.024, blue: 0.055, alpha: 1.0), // #01060e
        surfaceContainerLow: NSColor(srgbRed: 0.027, green: 0.067, blue: 0.118, alpha: 1.0),    // #07111e
        surfaceContainerHigh: NSColor(srgbRed: 0.055, green: 0.106, blue: 0.173, alpha: 1.0),   // #0e1b2c
        surfaceContainerHighest: NSColor(srgbRed: 0.078, green: 0.141, blue: 0.224, alpha: 1.0), // #142439
        surfaceBright: NSColor(srgbRed: 0.098, green: 0.165, blue: 0.255, alpha: 1.0),          // #192a41
        primary: NSColor(srgbRed: 0.769, green: 0.471, blue: 1.0, alpha: 1.0),                  // #c478ff
        primaryContainer: NSColor(srgbRed: 0.620, green: 0.310, blue: 0.906, alpha: 1.0),       // #9e4fe7
        secondary: NSColor(srgbRed: 0.506, green: 0.831, blue: 1.0, alpha: 1.0),                // #81d4ff
        onPrimary: NSColor(srgbRed: 0.263, green: 0.102, blue: 0.447, alpha: 1.0),              // #431a72
        onSurface: NSColor(srgbRed: 0.808, green: 0.835, blue: 0.882, alpha: 1.0),              // #ced5e1
        onSurfaceVariant: NSColor(srgbRed: 0.608, green: 0.651, blue: 0.722, alpha: 1.0),       // #9ba6b8
        tertiaryText: NSColor(srgbRed: 0.322, green: 0.369, blue: 0.451, alpha: 1.0),           // #525e73
        quaternaryText: NSColor(srgbRed: 0.224, green: 0.267, blue: 0.341, alpha: 1.0),         // #394457
        outline: NSColor(srgbRed: 0.176, green: 0.231, blue: 0.318, alpha: 1.0),                // #2d3b51
        outlineVariant: NSColor(srgbRed: 0.176, green: 0.231, blue: 0.318, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    // Cool slate base, rose/pink accent
    static let rosePine = ThemeDefinition(
        id: "rose-pine",
        name: "Rose Pine",
        surface: NSColor(srgbRed: 0.137, green: 0.118, blue: 0.169, alpha: 1.0),               // #231e2b
        surfaceContainerLowest: NSColor(srgbRed: 0.098, green: 0.082, blue: 0.129, alpha: 1.0), // #191521
        surfaceContainerLow: NSColor(srgbRed: 0.165, green: 0.145, blue: 0.200, alpha: 1.0),    // #2a2533
        surfaceContainerHigh: NSColor(srgbRed: 0.212, green: 0.192, blue: 0.251, alpha: 1.0),   // #363140
        surfaceContainerHighest: NSColor(srgbRed: 0.255, green: 0.235, blue: 0.298, alpha: 1.0), // #413c4c
        surfaceBright: NSColor(srgbRed: 0.282, green: 0.259, blue: 0.329, alpha: 1.0),          // #484254
        primary: NSColor(srgbRed: 0.918, green: 0.549, blue: 0.659, alpha: 1.0),                // #ea8ca8
        primaryContainer: NSColor(srgbRed: 0.816, green: 0.400, blue: 0.533, alpha: 1.0),       // #d06688
        secondary: NSColor(srgbRed: 0.769, green: 0.620, blue: 0.910, alpha: 1.0),              // #c49ee8
        onPrimary: NSColor(srgbRed: 0.380, green: 0.125, blue: 0.208, alpha: 1.0),              // #612035
        onSurface: NSColor(srgbRed: 0.878, green: 0.847, blue: 0.922, alpha: 1.0),              // #e0d8eb
        onSurfaceVariant: NSColor(srgbRed: 0.710, green: 0.678, blue: 0.765, alpha: 1.0),       // #b5adc3
        tertiaryText: NSColor(srgbRed: 0.420, green: 0.396, blue: 0.475, alpha: 1.0),           // #6b6579
        quaternaryText: NSColor(srgbRed: 0.318, green: 0.298, blue: 0.369, alpha: 1.0),         // #514c5e
        outline: NSColor(srgbRed: 0.298, green: 0.275, blue: 0.357, alpha: 1.0),                // #4c465b
        outlineVariant: NSColor(srgbRed: 0.298, green: 0.275, blue: 0.357, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    // Warm dark brown, red/crimson accent
    static let bloodMoon = ThemeDefinition(
        id: "blood-moon",
        name: "Blood Moon",
        surface: NSColor(srgbRed: 0.094, green: 0.059, blue: 0.055, alpha: 1.0),               // #180f0e
        surfaceContainerLowest: NSColor(srgbRed: 0.059, green: 0.035, blue: 0.031, alpha: 1.0), // #0f0908
        surfaceContainerLow: NSColor(srgbRed: 0.122, green: 0.082, blue: 0.075, alpha: 1.0),    // #1f1513
        surfaceContainerHigh: NSColor(srgbRed: 0.173, green: 0.118, blue: 0.110, alpha: 1.0),   // #2c1e1c
        surfaceContainerHighest: NSColor(srgbRed: 0.216, green: 0.153, blue: 0.145, alpha: 1.0), // #372725
        surfaceBright: NSColor(srgbRed: 0.243, green: 0.176, blue: 0.165, alpha: 1.0),          // #3e2d2a
        primary: NSColor(srgbRed: 1.0, green: 0.337, blue: 0.282, alpha: 1.0),                  // #ff5648
        primaryContainer: NSColor(srgbRed: 0.847, green: 0.220, blue: 0.173, alpha: 1.0),       // #d8382c
        secondary: NSColor(srgbRed: 1.0, green: 0.576, blue: 0.412, alpha: 1.0),                // #ff9369
        onPrimary: NSColor(srgbRed: 0.353, green: 0.059, blue: 0.024, alpha: 1.0),              // #5a0f06
        onSurface: NSColor(srgbRed: 0.878, green: 0.824, blue: 0.812, alpha: 1.0),              // #e0d2cf
        onSurfaceVariant: NSColor(srgbRed: 0.722, green: 0.659, blue: 0.643, alpha: 1.0),       // #b8a8a4
        tertiaryText: NSColor(srgbRed: 0.420, green: 0.365, blue: 0.353, alpha: 1.0),           // #6b5d5a
        quaternaryText: NSColor(srgbRed: 0.318, green: 0.271, blue: 0.263, alpha: 1.0),         // #514543
        outline: NSColor(srgbRed: 0.318, green: 0.243, blue: 0.231, alpha: 1.0),                // #513e3b
        outlineVariant: NSColor(srgbRed: 0.318, green: 0.243, blue: 0.231, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    // True black OLED, hot pink accent
    static let voidPink = ThemeDefinition(
        id: "void-pink",
        name: "Void Pink",
        surface: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.035, alpha: 1.0),               // #090909
        surfaceContainerLowest: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),       // #000000
        surfaceContainerLow: NSColor(srgbRed: 0.063, green: 0.059, blue: 0.067, alpha: 1.0),    // #100f11
        surfaceContainerHigh: NSColor(srgbRed: 0.106, green: 0.098, blue: 0.114, alpha: 1.0),   // #1b191d
        surfaceContainerHighest: NSColor(srgbRed: 0.149, green: 0.141, blue: 0.161, alpha: 1.0), // #262429
        surfaceBright: NSColor(srgbRed: 0.176, green: 0.165, blue: 0.188, alpha: 1.0),          // #2d2a30
        primary: NSColor(srgbRed: 1.0, green: 0.282, blue: 0.580, alpha: 1.0),                  // #ff4894
        primaryContainer: NSColor(srgbRed: 0.878, green: 0.157, blue: 0.459, alpha: 1.0),       // #e02875
        secondary: NSColor(srgbRed: 1.0, green: 0.502, blue: 0.718, alpha: 1.0),                // #ff80b7
        onPrimary: NSColor(srgbRed: 0.365, green: 0.047, blue: 0.169, alpha: 1.0),              // #5d0c2b
        onSurface: NSColor(srgbRed: 0.859, green: 0.831, blue: 0.871, alpha: 1.0),              // #dbd4de
        onSurfaceVariant: NSColor(srgbRed: 0.690, green: 0.663, blue: 0.710, alpha: 1.0),       // #b0a9b5
        tertiaryText: NSColor(srgbRed: 0.388, green: 0.365, blue: 0.412, alpha: 1.0),           // #635d69
        quaternaryText: NSColor(srgbRed: 0.286, green: 0.267, blue: 0.306, alpha: 1.0),         // #49444e
        outline: NSColor(srgbRed: 0.255, green: 0.239, blue: 0.278, alpha: 1.0),                // #413d47
        outlineVariant: NSColor(srgbRed: 0.255, green: 0.239, blue: 0.278, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    // Cool blue-grey, ice blue accent
    static let glacier = ThemeDefinition(
        id: "glacier",
        name: "Glacier",
        surface: NSColor(srgbRed: 0.082, green: 0.098, blue: 0.114, alpha: 1.0),               // #15191d
        surfaceContainerLowest: NSColor(srgbRed: 0.047, green: 0.059, blue: 0.071, alpha: 1.0), // #0c0f12
        surfaceContainerLow: NSColor(srgbRed: 0.110, green: 0.129, blue: 0.149, alpha: 1.0),    // #1c2126
        surfaceContainerHigh: NSColor(srgbRed: 0.153, green: 0.176, blue: 0.200, alpha: 1.0),   // #272d33
        surfaceContainerHighest: NSColor(srgbRed: 0.196, green: 0.220, blue: 0.247, alpha: 1.0), // #32383f
        surfaceBright: NSColor(srgbRed: 0.220, green: 0.247, blue: 0.275, alpha: 1.0),          // #383f46
        primary: NSColor(srgbRed: 0.529, green: 0.847, blue: 1.0, alpha: 1.0),                  // #87d8ff
        primaryContainer: NSColor(srgbRed: 0.380, green: 0.729, blue: 0.906, alpha: 1.0),       // #61bae7
        secondary: NSColor(srgbRed: 0.702, green: 0.918, blue: 1.0, alpha: 1.0),                // #b3eaff
        onPrimary: NSColor(srgbRed: 0.059, green: 0.267, blue: 0.376, alpha: 1.0),              // #0f4460
        onSurface: NSColor(srgbRed: 0.824, green: 0.859, blue: 0.890, alpha: 1.0),              // #d2dbe3
        onSurfaceVariant: NSColor(srgbRed: 0.639, green: 0.686, blue: 0.729, alpha: 1.0),       // #a3afba
        tertiaryText: NSColor(srgbRed: 0.345, green: 0.388, blue: 0.431, alpha: 1.0),           // #58636e
        quaternaryText: NSColor(srgbRed: 0.251, green: 0.290, blue: 0.329, alpha: 1.0),         // #404a54
        outline: NSColor(srgbRed: 0.224, green: 0.263, blue: 0.306, alpha: 1.0),                // #39434e
        outlineVariant: NSColor(srgbRed: 0.224, green: 0.263, blue: 0.306, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    // Warm charcoal, solar orange/yellow accent
    static let solarFlare = ThemeDefinition(
        id: "solar-flare",
        name: "Solar Flare",
        surface: NSColor(srgbRed: 0.090, green: 0.078, blue: 0.067, alpha: 1.0),               // #171411
        surfaceContainerLowest: NSColor(srgbRed: 0.055, green: 0.047, blue: 0.039, alpha: 1.0), // #0e0c0a
        surfaceContainerLow: NSColor(srgbRed: 0.118, green: 0.106, blue: 0.090, alpha: 1.0),    // #1e1b17
        surfaceContainerHigh: NSColor(srgbRed: 0.169, green: 0.153, blue: 0.133, alpha: 1.0),   // #2b2722
        surfaceContainerHighest: NSColor(srgbRed: 0.212, green: 0.196, blue: 0.173, alpha: 1.0), // #36322c
        surfaceBright: NSColor(srgbRed: 0.239, green: 0.220, blue: 0.196, alpha: 1.0),          // #3d3832
        primary: NSColor(srgbRed: 1.0, green: 0.784, blue: 0.176, alpha: 1.0),                  // #ffc82d
        primaryContainer: NSColor(srgbRed: 0.878, green: 0.659, blue: 0.082, alpha: 1.0),       // #e0a815
        secondary: NSColor(srgbRed: 1.0, green: 0.878, blue: 0.502, alpha: 1.0),                // #ffe080
        onPrimary: NSColor(srgbRed: 0.349, green: 0.255, blue: 0.0, alpha: 1.0),                // #594100
        onSurface: NSColor(srgbRed: 0.871, green: 0.847, blue: 0.816, alpha: 1.0),              // #ded8d0
        onSurfaceVariant: NSColor(srgbRed: 0.706, green: 0.678, blue: 0.643, alpha: 1.0),       // #b4ada4
        tertiaryText: NSColor(srgbRed: 0.408, green: 0.384, blue: 0.357, alpha: 1.0),           // #68625b
        quaternaryText: NSColor(srgbRed: 0.310, green: 0.290, blue: 0.267, alpha: 1.0),         // #4f4a44
        outline: NSColor(srgbRed: 0.290, green: 0.267, blue: 0.243, alpha: 1.0),                // #4a443e
        outlineVariant: NSColor(srgbRed: 0.290, green: 0.267, blue: 0.243, alpha: 0.15),
        hoverBg: NSColor(white: 1.0, alpha: 0.04),
        activeBg: NSColor(white: 1.0, alpha: 0.10),
        cornerRadiusBadge: 0,
        cornerRadiusElement: 0,
        cornerRadiusCard: 0
    )

    static let allBuiltIn: [ThemeDefinition] = [
        .kineticMonolith,
        .obsidian,
        .phosphor,
        .nightOwl,
        .rosePine,
        .bloodMoon,
        .voidPink,
        .glacier,
        .solarFlare,
    ]
}
