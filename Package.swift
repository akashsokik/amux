// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "amux",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // C target that wraps the ghostty.h header via a modulemap.
        // The actual symbols live in libghostty.a which is linked by
        // the executable target below.
        .target(
            name: "CGhostty",
            path: "Sources/CGhostty",
            publicHeadersPath: "include"
        ),

        .executableTarget(
            name: "amux",
            dependencies: ["CGhostty"],
            path: "Sources/amux",
            resources: [
                .copy("../../Resources/Fonts"),
            ],
            linkerSettings: [
                // Link the static library built by the Ghostty project.
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/vendor/ghostty-dist/macos-arm64_x86_64",
                    "-lghostty",
                    "-lc++",
                ]),
                // Frameworks required by libghostty
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
