# Editor Sidebar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a right-side editor sidebar with tabs, syntax highlighting (TreeSitter), and "open in editor" pill, triggered by clicking files in FileTree.

**Architecture:** New `EditorSidebarView` as a peer to `SplitContainerView` in `MainWindowController`, mirroring the left sidebar pattern. A `FileTreeView` delegate notifies `MainWindowController` of file clicks, which routes to the editor sidebar. TreeSitter via `SwiftTreeSitter` for syntax highlighting.

**Tech Stack:** Swift, AppKit (NSTextView), SwiftTreeSitter, NSWorkspace (external editor detection)

---

### Task 1: Add SwiftTreeSitter dependency to Package.swift

**Files:**
- Modify: `Package.swift`

**Step 1: Add the SwiftTreeSitter package dependency and language grammar packages**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "amux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
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
            ],
            path: "Sources/amux",
            resources: [
                .copy("../../Resources/Fonts"),
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
    ]
)
```

**Step 2: Resolve the package**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift package resolve`
Expected: SwiftTreeSitter downloaded successfully.

**Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add SwiftTreeSitter dependency for editor sidebar"
```

---

### Task 2: Create EditorTab data model

**Files:**
- Create: `Sources/amux/Models/EditorTab.swift`

**Step 1: Create the model file**

```swift
import Foundation

class EditorTab: Identifiable {
    let id: UUID
    let filePath: String
    var content: String
    var isDirty: Bool = false
    var encoding: String.Encoding

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    var fileExtension: String {
        URL(fileURLWithPath: filePath).pathExtension
    }

    init(filePath: String) throws {
        self.id = UUID()
        self.filePath = filePath

        // Try UTF-8 first, fall back to ASCII
        if let str = try? String(contentsOfFile: filePath, encoding: .utf8) {
            self.content = str
            self.encoding = .utf8
        } else {
            self.content = try String(contentsOfFile: filePath, encoding: .ascii)
            self.encoding = .ascii
        }
    }

    func save() throws {
        try content.write(toFile: filePath, atomically: true, encoding: encoding)
        isDirty = false
    }
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Models/EditorTab.swift
git commit -m "feat: add EditorTab data model"
```

---

### Task 3: Create ExternalEditorHelper

**Files:**
- Create: `Sources/amux/Helpers/ExternalEditorHelper.swift`

**Step 1: Create the helper**

```swift
import AppKit

enum ExternalEditorHelper {
    /// Known GUI editors in priority order
    private static let knownEditors: [(name: String, bundleID: String)] = [
        ("VS Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("TextMate", "com.macromates.TextMate"),
    ]

    /// Returns the best available GUI editor, or nil if none found
    static func preferredEditor() -> (name: String, bundleID: String)? {
        for editor in knownEditors {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) != nil {
                return editor
            }
        }
        return nil
    }

    /// Opens the file in the preferred editor, or falls back to system default
    static func openInEditor(filePath: String) {
        let url = URL(fileURLWithPath: filePath)

        if let editor = preferredEditor(),
           let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Display name for the button label
    static func editorButtonLabel() -> String {
        if let editor = preferredEditor() {
            return "Open in \(editor.name)"
        }
        return "Open in Editor"
    }
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Helpers/ExternalEditorHelper.swift
git commit -m "feat: add ExternalEditorHelper for GUI editor detection"
```

---

### Task 4: Create SyntaxHighlighter wrapper

**Files:**
- Create: `Sources/amux/Helpers/SyntaxHighlighter.swift`

**Step 1: Create the highlighter**

This wraps SwiftTreeSitter to map file extensions to languages and apply highlighting to an NSTextStorage. Note: tree-sitter language grammars are loaded dynamically. For the initial implementation, we'll use a regex-based fallback approach and integrate tree-sitter grammars incrementally since bundling them requires compiling C sources.

```swift
import AppKit
import SwiftTreeSitter

class SyntaxHighlighter {
    private var parser: Parser?
    private var tree: Tree?
    private weak var textStorage: NSTextStorage?
    private let defaultFont: NSFont

    /// Maps file extensions to tree-sitter language names
    private static let extensionToLanguage: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript",
        "ts": "typescript", "tsx": "tsx", "jsx": "javascript",
        "rs": "rust", "go": "go", "c": "c", "h": "c",
        "cpp": "cpp", "hpp": "cpp", "m": "objc",
        "json": "json", "yaml": "yaml", "yml": "yaml",
        "md": "markdown", "html": "html", "css": "css",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "rb": "ruby", "java": "java", "kt": "kotlin",
        "toml": "toml", "xml": "xml",
    ]

    /// Keyword-based highlighting colors (fallback when tree-sitter grammar not available)
    private static let keywordColor = NSColor(calibratedRed: 0.78, green: 0.47, blue: 0.76, alpha: 1.0)
    private static let stringColor = NSColor(calibratedRed: 0.58, green: 0.79, blue: 0.50, alpha: 1.0)
    private static let commentColor = NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.55, alpha: 1.0)
    private static let numberColor = NSColor(calibratedRed: 0.82, green: 0.67, blue: 0.47, alpha: 1.0)
    private static let typeColor = NSColor(calibratedRed: 0.47, green: 0.73, blue: 0.82, alpha: 1.0)

    /// Common keywords across languages
    private static let keywords: Set<String> = [
        "func", "function", "def", "fn", "class", "struct", "enum", "protocol",
        "interface", "import", "from", "return", "if", "else", "for", "while",
        "do", "switch", "case", "break", "continue", "var", "let", "const",
        "val", "pub", "private", "public", "static", "override", "guard",
        "throw", "throws", "try", "catch", "finally", "async", "await",
        "self", "super", "nil", "null", "None", "true", "false", "True", "False",
        "in", "is", "as", "where", "with", "yield", "lambda", "pass",
        "type", "typealias", "typedef", "extension", "impl",
    ]

    init(textStorage: NSTextStorage, font: NSFont) {
        self.textStorage = textStorage
        self.defaultFont = font
    }

    func highlight(fileExtension: String) {
        // For now, use regex-based highlighting as a reliable fallback.
        // Tree-sitter grammar integration can be added per-language later
        // once the C grammar libraries are compiled and bundled.
        applyRegexHighlighting()
    }

    func highlightEdits(in range: NSRange) {
        // Re-highlight the affected line range
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        let lineRange = string.lineRange(for: range)
        applyRegexHighlighting(in: lineRange)
    }

    private func applyRegexHighlighting(in range: NSRange? = nil) {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        let fullRange = range ?? NSRange(location: 0, length: string.length)

        storage.beginEditing()

        // Reset to default
        storage.addAttributes([
            .foregroundColor: Theme.primaryText,
            .font: defaultFont,
        ], range: fullRange)

        let text = string.substring(with: fullRange)
        let baseOffset = fullRange.location

        // Comments: // and # single-line
        highlightPattern(#"(//|#).*$"#, in: text, color: SyntaxHighlighter.commentColor,
                         storage: storage, baseOffset: baseOffset)

        // Multi-line comments /* ... */
        highlightPattern(#"/\*[\s\S]*?\*/"#, in: text, color: SyntaxHighlighter.commentColor,
                         storage: storage, baseOffset: baseOffset)

        // Strings: double-quoted and single-quoted
        highlightPattern(#""(?:[^"\\]|\\.)*""#, in: text, color: SyntaxHighlighter.stringColor,
                         storage: storage, baseOffset: baseOffset)
        highlightPattern(#"'(?:[^'\\]|\\.)*'"#, in: text, color: SyntaxHighlighter.stringColor,
                         storage: storage, baseOffset: baseOffset)

        // Numbers
        highlightPattern(#"\b\d+\.?\d*\b"#, in: text, color: SyntaxHighlighter.numberColor,
                         storage: storage, baseOffset: baseOffset)

        // Keywords (word boundaries)
        let keywordPattern = "\\b(" + SyntaxHighlighter.keywords.joined(separator: "|") + ")\\b"
        highlightPattern(keywordPattern, in: text, color: SyntaxHighlighter.keywordColor,
                         storage: storage, baseOffset: baseOffset)

        // Type names (capitalized identifiers)
        highlightPattern(#"\b[A-Z][a-zA-Z0-9_]*\b"#, in: text, color: SyntaxHighlighter.typeColor,
                         storage: storage, baseOffset: baseOffset)

        storage.endEditing()
    }

    private func highlightPattern(_ pattern: String, in text: String,
                                  color: NSColor, storage: NSTextStorage,
                                  baseOffset: Int) {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: [.anchorsMatchLines]) else { return }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let range = NSRange(location: match.range.location + baseOffset, length: match.range.length)
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Helpers/SyntaxHighlighter.swift
git commit -m "feat: add SyntaxHighlighter with regex-based highlighting"
```

---

### Task 5: Create EditorSidebarView with tab bar and placeholder

**Files:**
- Create: `Sources/amux/Views/EditorSidebarView.swift`

**Step 1: Create the main editor sidebar view**

This is the largest file. It contains:
- A tab bar at top (reusing patterns from PaneTabBar)
- A header with file path and "Open in Editor" pill
- The NSTextView-based editor with line number gutter
- Placeholder view when no files are open

```swift
import AppKit

// MARK: - EditorSidebarView Delegate

protocol EditorSidebarViewDelegate: AnyObject {
    func editorSidebarDidToggle(visible: Bool)
}

// MARK: - EditorSidebarView

class EditorSidebarView: NSView {
    weak var delegate: EditorSidebarViewDelegate?

    private var tabs: [EditorTab] = []
    private var activeTabID: UUID?
    private var tabBar: EditorTabBar!
    private var headerView: EditorHeaderView!
    private var editorContainer: NSView!
    private var placeholderLabel: NSTextField!
    private var separatorLine: NSView!

    // Editor components per tab (cached)
    private var editorViews: [UUID: EditorContentView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.sidebarBg.cgColor
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        placeholderLabel.textColor = Theme.quaternaryText
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        // Left separator line
        separatorLine = NSView()
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)

        // Tab bar
        tabBar = EditorTabBar()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        addSubview(tabBar)

        // Header with file path and open-in-editor button
        headerView = EditorHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.isHidden = true
        addSubview(headerView)

        // Editor container
        editorContainer = NSView()
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editorContainer)

        // Placeholder
        placeholderLabel = NSTextField(labelWithString: "Click a file in the tree to open it")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = Theme.Fonts.body(size: 13)
        placeholderLabel.textColor = Theme.quaternaryText
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0
        addSubview(placeholderLabel)

        let contentLeading = separatorLine.trailingAnchor

        NSLayoutConstraint.activate([
            // Left separator
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),

            // Tab bar
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            tabBar.leadingAnchor.constraint(equalTo: contentLeading),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: EditorTabBar.barHeight),

            // Header
            headerView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentLeading),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 32),

            // Editor container
            editorContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: contentLeading),
            editorContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Placeholder (centered in editor container area)
            placeholderLabel.centerXAnchor.constraint(equalTo: editorContainer.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: editorContainer.centerYAnchor),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: editorContainer.widthAnchor, constant: -40),
        ])
    }

    // MARK: - Public API

    func openFile(at path: String) {
        // Check if already open
        if let existingTab = tabs.first(where: { $0.filePath == path }) {
            activateTab(existingTab.id)
            return
        }

        // Open new tab
        guard let tab = try? EditorTab(filePath: path) else { return }
        tabs.append(tab)
        activateTab(tab.id)
    }

    var hasOpenTabs: Bool {
        return !tabs.isEmpty
    }

    // MARK: - Tab Management

    private func activateTab(_ tabID: UUID) {
        activeTabID = tabID
        updateTabBar()
        showEditorForActiveTab()
    }

    private func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]

        if tab.isDirty {
            promptSaveBeforeClosing(tab: tab) { [weak self] shouldClose in
                if shouldClose {
                    self?.removeTab(at: index)
                }
            }
        } else {
            removeTab(at: index)
        }
    }

    private func removeTab(at index: Int) {
        let tab = tabs[index]
        tabs.remove(at: index)

        // Remove cached editor view
        if let editorView = editorViews.removeValue(forKey: tab.id) {
            editorView.removeFromSuperview()
        }

        // Activate adjacent tab
        if tabs.isEmpty {
            activeTabID = nil
            showPlaceholder()
        } else if tab.id == activeTabID {
            let newIndex = min(index, tabs.count - 1)
            activateTab(tabs[newIndex].id)
        } else {
            updateTabBar()
        }
    }

    private func updateTabBar() {
        let tabData = tabs.map { (id: $0.id, title: $0.fileName, isDirty: $0.isDirty) }
        tabBar.updateTabs(tabData, activeID: activeTabID)
    }

    private func showEditorForActiveTab() {
        guard let tabID = activeTabID,
              let tab = tabs.first(where: { $0.id == tabID }) else {
            showPlaceholder()
            return
        }

        placeholderLabel.isHidden = true
        headerView.isHidden = false

        // Update header
        headerView.configure(filePath: tab.filePath)

        // Hide all editor views
        for (_, view) in editorViews {
            view.isHidden = true
        }

        // Show or create editor view for this tab
        if let existing = editorViews[tabID] {
            existing.isHidden = false
        } else {
            let editorView = EditorContentView(tab: tab)
            editorView.translatesAutoresizingMaskIntoConstraints = false
            editorView.onDirtyStateChanged = { [weak self] isDirty in
                tab.isDirty = isDirty
                self?.updateTabBar()
            }
            editorContainer.addSubview(editorView)
            NSLayoutConstraint.activate([
                editorView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
                editorView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
                editorView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
                editorView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            ])
            editorViews[tabID] = editorView
        }
    }

    private func showPlaceholder() {
        placeholderLabel.isHidden = false
        headerView.isHidden = true
        for (_, view) in editorViews {
            view.isHidden = true
        }
        updateTabBar()
    }

    private func promptSaveBeforeClosing(tab: EditorTab, completion: @escaping (Bool) -> Void) {
        guard let window = self.window else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(tab.fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                try? tab.save()
                completion(true)
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// Save the currently active tab
    func saveActiveTab() {
        guard let tabID = activeTabID,
              let tab = tabs.first(where: { $0.id == tabID }) else { return }
        try? tab.save()
        updateTabBar()
        editorViews[tabID]?.markClean()
    }
}

// MARK: - EditorTabBarDelegate

extension EditorSidebarView: EditorTabBarDelegate {
    func editorTabBar(_ tabBar: EditorTabBar, didSelectTab tabID: UUID) {
        activateTab(tabID)
    }

    func editorTabBar(_ tabBar: EditorTabBar, didCloseTab tabID: UUID) {
        closeTab(tabID)
    }
}

// MARK: - EditorTabBar

protocol EditorTabBarDelegate: AnyObject {
    func editorTabBar(_ tabBar: EditorTabBar, didSelectTab tabID: UUID)
    func editorTabBar(_ tabBar: EditorTabBar, didCloseTab tabID: UUID)
}

class EditorTabBar: NSView {
    weak var delegate: EditorTabBarDelegate?

    private var scrollView: NSScrollView!
    private var tabContainer: NSView!
    private var tabItemViews: [EditorTabItemView] = []

    static let barHeight: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
        for item in tabItemViews {
            item.refreshTheme()
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.surfaceContainerLow.cgColor

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        tabContainer = NSView(frame: .zero)
        scrollView.documentView = tabContainer

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func updateTabs(_ tabs: [(id: UUID, title: String, isDirty: Bool)], activeID: UUID?) {
        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        for tab in tabs {
            let item = EditorTabItemView(tabID: tab.id, title: tab.title, isDirty: tab.isDirty)
            item.isActive = (tab.id == activeID)
            item.showCloseButton = true
            item.delegate = self
            tabContainer.addSubview(item)
            tabItemViews.append(item)
        }

        layoutTabItems()
    }

    private func layoutTabItems() {
        var x: CGFloat = 4
        let y: CGFloat = 2
        let height = bounds.height - 4

        for item in tabItemViews {
            let width = item.intrinsicContentSize.width
            item.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 2
        }

        tabContainer.frame = NSRect(
            x: 0, y: 0,
            width: max(x + 2, scrollView.bounds.width),
            height: max(bounds.height - 1, 0)
        )
    }

    override func layout() {
        super.layout()
        layoutTabItems()
    }
}

extension EditorTabBar: EditorTabItemViewDelegate {
    func editorTabItemDidSelect(_ item: EditorTabItemView) {
        delegate?.editorTabBar(self, didSelectTab: item.tabID)
    }

    func editorTabItemDidClose(_ item: EditorTabItemView) {
        delegate?.editorTabBar(self, didCloseTab: item.tabID)
    }
}

// MARK: - EditorTabItemView

protocol EditorTabItemViewDelegate: AnyObject {
    func editorTabItemDidSelect(_ item: EditorTabItemView)
    func editorTabItemDidClose(_ item: EditorTabItemView)
}

class EditorTabItemView: NSView {
    let tabID: UUID
    weak var delegate: EditorTabItemViewDelegate?

    private let titleLabel = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let closeButton = NSButton()
    private let highlightView = NSView()
    private var trackingArea: NSTrackingArea?

    var title: String {
        didSet { titleLabel.stringValue = title }
    }

    var isDirty: Bool = false {
        didSet { dirtyDot.isHidden = !isDirty }
    }

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    var showCloseButton: Bool = true {
        didSet { updateAppearance() }
    }

    private var isHovered: Bool = false {
        didSet { updateAppearance() }
    }

    init(tabID: UUID, title: String, isDirty: Bool = false) {
        self.tabID = tabID
        self.title = title
        self.isDirty = isDirty
        super.init(frame: .zero)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        wantsLayer = true

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.CornerRadius.element
        addSubview(highlightView)

        // Dirty indicator dot
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.layer?.backgroundColor = Theme.tertiaryText.cgColor
        dirtyDot.isHidden = !isDirty
        addSubview(dirtyDot)

        titleLabel.stringValue = title
        titleLabel.font = Theme.Fonts.label(size: 12)
        titleLabel.textColor = Theme.tertiaryText
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        closeButton.title = ""
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        )
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.tertiaryText
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        if let cell = closeButton.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }
        addSubview(closeButton)

        updateAppearance()
    }

    private static let minTabWidth: CGFloat = 100
    private static let maxTitleWidth: CGFloat = 120

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let clampedTitle = min(titleWidth, EditorTabItemView.maxTitleWidth)
        // padding(8) + dirty(6+4) + title + gap(4) + close(14) + padding(6)
        let natural: CGFloat = 8 + (isDirty ? 10 : 0) + clampedTitle + 4 + 14 + 6
        return NSSize(width: max(natural, EditorTabItemView.minTabWidth), height: 24)
    }

    override func layout() {
        super.layout()
        highlightView.frame = bounds

        var x: CGFloat = 8

        // Dirty dot
        if isDirty {
            dirtyDot.frame = NSRect(x: x, y: (bounds.height - 6) / 2, width: 6, height: 6)
            x += 10
        }

        // Close button on right
        let closeSize: CGFloat = 14
        let closeX = bounds.width - 6 - closeSize
        closeButton.frame = NSRect(
            x: closeX,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )

        // Title
        let titleWidth = closeX - x - 4
        let titleH = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: x,
            y: (bounds.height - titleH) / 2,
            width: max(0, titleWidth),
            height: titleH
        )
    }

    private func updateAppearance() {
        if isActive {
            highlightView.layer?.backgroundColor = Theme.surfaceContainerHigh.cgColor
            titleLabel.textColor = Theme.primaryText
        } else if isHovered {
            highlightView.layer?.backgroundColor = Theme.hoverBg.cgColor
            titleLabel.textColor = Theme.secondaryText
        } else {
            highlightView.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = Theme.tertiaryText
        }

        closeButton.alphaValue = (isActive || isHovered) ? 1 : 0
    }

    func refreshTheme() {
        closeButton.contentTintColor = Theme.tertiaryText
        dirtyDot.layer?.backgroundColor = Theme.tertiaryText.cgColor
        updateAppearance()
    }

    @objc private func closeClicked() {
        delegate?.editorTabItemDidClose(self)
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.editorTabItemDidSelect(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

// MARK: - EditorHeaderView

class EditorHeaderView: NSView {
    private var pathLabel: NSTextField!
    private var openInEditorButton: NSButton!

    private var currentFilePath: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = Theme.Fonts.body(size: 11)
        pathLabel.textColor = Theme.quaternaryText
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        addSubview(pathLabel)

        // "Open in Editor" pill button
        openInEditorButton = NSButton()
        openInEditorButton.translatesAutoresizingMaskIntoConstraints = false
        openInEditorButton.title = ExternalEditorHelper.editorButtonLabel()
        openInEditorButton.font = Theme.Fonts.label(size: 10)
        openInEditorButton.bezelStyle = .roundRect
        openInEditorButton.isBordered = true
        openInEditorButton.contentTintColor = Theme.secondaryText
        openInEditorButton.target = self
        openInEditorButton.action = #selector(openInEditorClicked)
        addSubview(openInEditorButton)

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: openInEditorButton.leadingAnchor, constant: -8),

            openInEditorButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            openInEditorButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            openInEditorButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(filePath: String) {
        currentFilePath = filePath
        // Show abbreviated path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = filePath
        if display.hasPrefix(home) {
            display = "~" + display.dropFirst(home.count)
        }
        pathLabel.stringValue = display
        pathLabel.toolTip = filePath
    }

    @objc private func openInEditorClicked() {
        guard let path = currentFilePath else { return }
        ExternalEditorHelper.openInEditor(filePath: path)
    }
}

// MARK: - EditorContentView (NSTextView + Line Numbers)

class EditorContentView: NSView, NSTextStorageDelegate {
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var lineNumberView: LineNumberView!
    private var highlighter: SyntaxHighlighter?
    private let tab: EditorTab
    private var isUpdatingFromModel = false

    var onDirtyStateChanged: ((Bool) -> Void)?

    init(tab: EditorTab) {
        self.tab = tab
        super.init(frame: .zero)
        setupUI()
        loadContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScroller = ThinScroller()

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = font
        textView.textColor = Theme.primaryText
        textView.backgroundColor = Theme.background
        textView.insertionPointColor = Theme.primaryText
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.activeBg,
            .foregroundColor: Theme.primaryText,
        ]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // Allow horizontal scrolling
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        addSubview(scrollView)

        // Line number gutter
        lineNumberView = LineNumberView(textView: textView)
        lineNumberView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lineNumberView)

        NSLayoutConstraint.activate([
            lineNumberView.topAnchor.constraint(equalTo: topAnchor),
            lineNumberView.leadingAnchor.constraint(equalTo: leadingAnchor),
            lineNumberView.bottomAnchor.constraint(equalTo: bottomAnchor),
            lineNumberView.widthAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: lineNumberView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Set up text storage delegate for change tracking & highlighting
        textView.textStorage?.delegate = self

        // Set up highlighter
        highlighter = SyntaxHighlighter(
            textStorage: textView.textStorage!,
            font: font
        )
    }

    private func loadContent() {
        isUpdatingFromModel = true
        textView.string = tab.content
        highlighter?.highlight(fileExtension: tab.fileExtension)
        isUpdatingFromModel = false
        lineNumberView.needsDisplay = true
    }

    func markClean() {
        // Called after save
        lineNumberView.needsDisplay = true
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !isUpdatingFromModel else { return }
        guard editedMask.contains(.editedCharacters) else { return }

        tab.content = textView.string
        if !tab.isDirty {
            tab.isDirty = true
            onDirtyStateChanged?(true)
        }

        // Re-highlight edited region
        DispatchQueue.main.async { [weak self] in
            self?.highlighter?.highlightEdits(in: editedRange)
            self?.lineNumberView.needsDisplay = true
        }
    }
}

// MARK: - LineNumberView

class LineNumberView: NSView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true

        // Observe text changes and scroll
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange),
            name: NSText.didChangeNotification, object: textView
        )

        // Observe scroll changes via the clip view
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(textDidScroll),
                name: NSView.boundsDidChangeNotification, object: clipView
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func textDidScroll(_ notification: Notification) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // Background
        Theme.sidebarBg.setFill()
        dirtyRect.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.quaternaryText,
        ]

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let string = textView.string as NSString
        var lineNumber = 1

        // Count lines before visible range
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: charRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        // Draw visible line numbers
        string.enumerateSubstrings(
            in: charRange,
            options: [.byLines, .substringNotRequired]
        ) { [weak self] _, substringRange, _, _ in
            guard let self = self else { return }

            let glyphIdx = layoutManager.glyphIndexForCharacter(at: substringRange.location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            lineRect.origin.y -= visibleRect.origin.y
            // Offset for textContainerInset
            lineRect.origin.y += textView.textContainerInset.height

            let numStr = "\(lineNumber)" as NSString
            let size = numStr.size(withAttributes: attrs)
            let x = self.bounds.width - size.width - 8
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2

            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            lineNumber += 1
        }
    }
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Views/EditorSidebarView.swift
git commit -m "feat: add EditorSidebarView with tab bar, header, editor, and line numbers"
```

---

### Task 6: Add FileTreeView delegate for file selection

**Files:**
- Modify: `Sources/amux/Views/FileTreeView.swift`

**Step 1: Add delegate protocol and property**

At the top of `FileTreeView.swift`, after the `FileTreeNode` class (line 38), add a delegate protocol:

```swift
protocol FileTreeViewDelegate: AnyObject {
    func fileTreeView(_ view: FileTreeView, didSelectFileAt path: String)
}
```

Add a delegate property to `FileTreeView` class (after line 47):

```swift
weak var delegate: FileTreeViewDelegate?
```

**Step 2: Add selection handling in the outline view delegate**

Add a new delegate method in the `NSOutlineViewDelegate` extension (after the existing delegate methods, around line 209):

```swift
func outlineViewSelectionDidChange(_ notification: Notification) {
    let selectedRow = outlineView.selectedRow
    guard selectedRow >= 0,
          let node = outlineView.item(atRow: selectedRow) as? FileTreeNode,
          !node.isDirectory else { return }
    delegate?.fileTreeView(self, didSelectFileAt: node.url.path)
}
```

**Step 3: Commit**

```bash
git add Sources/amux/Views/FileTreeView.swift
git commit -m "feat: add FileTreeView delegate for file selection"
```

---

### Task 7: Wire up EditorSidebarView in MainWindowController

**Files:**
- Modify: `Sources/amux/Views/MainWindowController.swift`
- Modify: `Sources/amux/Views/SidebarView.swift`

**Step 1: Add editor sidebar properties to MainWindowController (after line 16)**

```swift
private(set) var editorSidebarView: EditorSidebarView!
private var editorResizeHandle: SidebarResizeHandle!
private var editorSidebarWidthConstraint: NSLayoutConstraint!
private var editorSidebarTrailingConstraint: NSLayoutConstraint!

private(set) var isEditorSidebarVisible = false
private var editorSidebarWidth: CGFloat = 350
private let minEditorSidebarWidth: CGFloat = 250
private let maxEditorSidebarWidth: CGFloat = 500
```

**Step 2: Add toolbar item identifier (after line 7)**

```swift
static let editorToggle = NSToolbarItem.Identifier("editorToggle")
```

**Step 3: Update setupViews() to add editor sidebar**

After the existing sidebar and split container setup, add the editor sidebar, its resize handle, and update constraints so `splitContainerView.trailingAnchor` pins to `editorSidebarView.leadingAnchor` (or `contentView.trailingAnchor` when hidden).

The constraints need to change:
- `splitContainerView.trailingAnchor` should pin to `editorSidebarView.leadingAnchor` instead of `contentView.trailingAnchor`
- `globalStatusBar.trailingAnchor` should pin to `editorSidebarView.leadingAnchor`
- Editor sidebar pins to the right edge

**Step 4: Add toggle method**

```swift
func toggleEditorSidebar() {
    isEditorSidebarVisible.toggle()
    let targetTrailing: CGFloat = isEditorSidebarVisible ? 0 : editorSidebarWidth

    NSAnimationContext.runAnimationGroup({ context in
        context.duration = Theme.Animation.standard
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true
        editorSidebarTrailingConstraint.animator().constant = targetTrailing
        window?.contentView?.layoutSubtreeIfNeeded()
    })
}
```

**Step 5: Add toolbar button for editor toggle**

In the toolbar delegate, add a new case for `.editorToggle` that creates a `sidebar.right` SF Symbol button, and add it to `toolbarDefaultItemIdentifiers` before `.actions`.

**Step 6: Add Cmd+Shift+E keyboard shortcut**

In `AppDelegate.swift` or wherever keyboard shortcuts are handled, add a handler for Cmd+Shift+E that calls `toggleEditorSidebar()`.

**Step 7: Wire FileTreeView delegate through SidebarView**

In `SidebarView.swift`:
- Add a new delegate method to `SidebarViewDelegate`:
  ```swift
  func sidebarDidSelectFile(path: String)
  ```
- Set `fileTreeView.delegate = self` in `setupFileTree()`
- Implement `FileTreeViewDelegate` on `SidebarView` to forward to its own delegate:
  ```swift
  extension SidebarView: FileTreeViewDelegate {
      func fileTreeView(_ view: FileTreeView, didSelectFileAt path: String) {
          delegate?.sidebarDidSelectFile(path: path)
      }
  }
  ```

In `MainWindowController.swift`, implement the new delegate method:
```swift
func sidebarDidSelectFile(path: String) {
    if !isEditorSidebarVisible {
        toggleEditorSidebar()
    }
    editorSidebarView.openFile(at: path)
}
```

**Step 8: Handle Cmd+S for saving**

Add a key event handler or menu item that calls `editorSidebarView.saveActiveTab()` when the editor sidebar is visible and has focus.

**Step 9: Commit**

```bash
git add Sources/amux/Views/MainWindowController.swift Sources/amux/Views/SidebarView.swift Sources/amux/Views/FileTreeView.swift
git commit -m "feat: wire EditorSidebarView into MainWindowController with toggle and FileTree integration"
```

---

### Task 8: Build and test

**Step 1: Build the project**

Run: `cd /Users/akashswamy/Workspace/fun-projects/agenterm && swift build`
Expected: Build succeeds with no errors.

**Step 2: Fix any compilation errors**

Address any missing imports, type mismatches, or constraint conflicts.

**Step 3: Manual testing checklist**

- [ ] Editor sidebar toggle button appears in toolbar (right side)
- [ ] Clicking toggle shows the sidebar with placeholder text
- [ ] Clicking a file in FileTree opens it in the editor sidebar
- [ ] File content displays with syntax highlighting
- [ ] Line numbers show correctly and scroll with content
- [ ] Multiple files open in tabs, clicking tabs switches between them
- [ ] Dirty dot appears when editing, disappears after Cmd+S save
- [ ] Close button on tabs works, prompts save if dirty
- [ ] "Open in Editor" pill opens file in VS Code / system editor
- [ ] Resize handle between split container and editor sidebar works
- [ ] Cmd+Shift+E toggles the editor sidebar

**Step 4: Commit**

```bash
git add -A
git commit -m "fix: resolve build issues for editor sidebar"
```
