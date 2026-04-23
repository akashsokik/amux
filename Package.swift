// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "amux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Tree-sitter core (ChimeHQ wrapper)
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", branch: "main"),
        // Vendored Neon with a Swift 6.2 concurrency fix in TreeSitterClient
        .package(path: "vendor/Neon"),

        // Tree-sitter grammars
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", branch: "master"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", branch: "master"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", branch: "split_parser"),
        // Skipped grammars:
        // - tree-sitter-c: SPM dependency identity conflict with ChimeHQ/SwiftTreeSitter
        // - tree-sitter-python: FileManager scanner.c detection bug in Package.swift
        // - tree-sitter-javascript: FileManager scanner.c detection bug in Package.swift
        // - tree-sitter-css: FileManager scanner.c detection bug in Package.swift
    ],
    targets: [
        .target(
            name: "CGhostty",
            path: "Sources/CGhostty",
            publicHeadersPath: "include"
        ),

        .executableTarget(
            name: "amux",
            dependencies: [
                "CGhostty",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "SwiftTreeSitterLayer", package: "SwiftTreeSitter"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            path: "Sources/amux",
            resources: [
                .copy("../../Resources/Fonts"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/vendor/ghostty-dist/macos-arm64_x86_64",
                    "-lghostty",
                    "-lc++",
                ]),
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
        .testTarget(
            name: "amuxTests",
            dependencies: ["amux"],
            path: "Tests/amuxTests"
        ),
    ]
)
