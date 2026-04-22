import AppKit

// MARK: - Display Mode

enum DiffDisplayMode {
    case unified
    case sideBySide
}

// MARK: - Scope

/// Which slice of git the diff represents. Drives how the diff is fetched
/// and which action buttons apply (stage/unstage only make sense for the
/// working-tree/index slices).
enum DiffScope: Equatable {
    case workingTree             // `git diff -- <path>`
    case index                   // `git diff --cached -- <path>`
    case commit(hash: String)    // `git show <hash> -- <path>`
}

// MARK: - Diff Tab Content
//
// Fills a single pane tab with the diff of one file. Lives alongside
// GhosttyTerminalView inside a TerminalPane — the parent pane owns tab
// switching/close, while this view owns the diff-specific chrome (mode
// toggle, stage/unstage buttons) and the actual rendering.
final class DiffTabView: NSView {
    // Identity
    let filePath: String
    private(set) var scope: DiffScope
    let repoRoot: String

    /// Convenience — some call sites still reason about "staged" as a Bool.
    var staged: Bool { scope == .index }

    private var displayMode: DiffDisplayMode = .unified
    private var diffText: String = ""

    // Chrome
    private var actionBar: NSView!
    private var actionBarSeparator: NSView!
    private var unifiedToggleButton: DimIconButton!
    private var sideBySideToggleButton: DimIconButton!
    private var stageButton: GitPanelActionButton!
    private var unstageButton: GitPanelActionButton!
    private var pathLabel: NSTextField!

    // Unified
    private var unifiedScrollView: NSScrollView!
    private var unifiedTextView: NSTextView!

    // Side-by-side
    private var sideBySideContainer: NSView!
    private var leftScrollView: NSScrollView!
    private var rightScrollView: NSScrollView!
    private var leftTextView: NSTextView!
    private var rightTextView: NSTextView!
    private var sideBySideSeparator: NSView!
    private var isSyncingScroll = false

    // MARK: - Init

    convenience init(filePath: String, staged: Bool, repoRoot: String) {
        self.init(filePath: filePath, scope: staged ? .index : .workingTree, repoRoot: repoRoot)
    }

    init(filePath: String, scope: DiffScope, repoRoot: String) {
        self.filePath = filePath
        self.scope = scope
        self.repoRoot = repoRoot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        setupChrome()
        setupUnified()
        setupSideBySide()
        applyModeVisibility()
        updateActionButtonStates()
        updateModeButtons()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    /// Returns true if this tab represents the same (path, scope) slice.
    func matches(filePath: String, scope: DiffScope) -> Bool {
        self.filePath == filePath && self.scope == scope
    }

    /// Re-fetch the diff from git and re-render.
    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let diff: String
            switch self.scope {
            case .workingTree:
                diff = GitHelper.diff(from: self.repoRoot, path: self.filePath, staged: false) ?? ""
            case .index:
                diff = GitHelper.diff(from: self.repoRoot, path: self.filePath, staged: true) ?? ""
            case .commit(let hash):
                diff = GitHelper.diffAtCommit(from: self.repoRoot, hash: hash, path: self.filePath) ?? ""
            }
            DispatchQueue.main.async {
                self.diffText = diff
                self.renderDiff()
            }
        }
    }

    // MARK: - Setup

    private func setupChrome() {
        actionBar = NSView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
        addSubview(actionBar)

        unifiedToggleButton = makeChromeButton(
            symbol: "text.justify",
            tooltip: "Unified view",
            action: #selector(unifiedModeClicked)
        )
        actionBar.addSubview(unifiedToggleButton)

        sideBySideToggleButton = makeChromeButton(
            symbol: "rectangle.split.2x1",
            tooltip: "Side-by-side view",
            action: #selector(sideBySideModeClicked)
        )
        actionBar.addSubview(sideBySideToggleButton)

        pathLabel = NSTextField(labelWithString: filePath)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = Theme.Fonts.body(size: 11)
        pathLabel.textColor = Theme.tertiaryText
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        actionBar.addSubview(pathLabel)

        stageButton = GitPanelActionButton(title: "Stage", symbolName: "plus")
        stageButton.translatesAutoresizingMaskIntoConstraints = false
        stageButton.target = self
        stageButton.action = #selector(stageClicked)
        actionBar.addSubview(stageButton)

        unstageButton = GitPanelActionButton(title: "Unstage", symbolName: "minus")
        unstageButton.translatesAutoresizingMaskIntoConstraints = false
        unstageButton.target = self
        unstageButton.action = #selector(unstageClicked)
        actionBar.addSubview(unstageButton)

        actionBarSeparator = NSView()
        actionBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        actionBarSeparator.wantsLayer = true
        actionBarSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(actionBarSeparator)

        NSLayoutConstraint.activate([
            actionBar.topAnchor.constraint(equalTo: topAnchor),
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 32),

            unifiedToggleButton.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 8),
            unifiedToggleButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            unifiedToggleButton.widthAnchor.constraint(equalToConstant: 22),
            unifiedToggleButton.heightAnchor.constraint(equalToConstant: 22),

            sideBySideToggleButton.leadingAnchor.constraint(equalTo: unifiedToggleButton.trailingAnchor, constant: 2),
            sideBySideToggleButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            sideBySideToggleButton.widthAnchor.constraint(equalToConstant: 22),
            sideBySideToggleButton.heightAnchor.constraint(equalToConstant: 22),

            unstageButton.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -8),
            unstageButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            unstageButton.heightAnchor.constraint(equalToConstant: 22),

            stageButton.trailingAnchor.constraint(equalTo: unstageButton.leadingAnchor, constant: -6),
            stageButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            stageButton.heightAnchor.constraint(equalToConstant: 22),

            pathLabel.leadingAnchor.constraint(equalTo: sideBySideToggleButton.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: stageButton.leadingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),

            actionBarSeparator.topAnchor.constraint(equalTo: actionBar.bottomAnchor),
            actionBarSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBarSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBarSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func makeChromeButton(symbol: String, tooltip: String, action: Selector) -> DimIconButton {
        let button = DimIconButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.toolTip = tooltip
        button.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: tooltip
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.refreshDimState()
        return button
    }

    private func setupUnified() {
        unifiedScrollView = NSScrollView()
        unifiedScrollView.translatesAutoresizingMaskIntoConstraints = false
        unifiedScrollView.hasVerticalScroller = true
        unifiedScrollView.hasHorizontalScroller = true
        unifiedScrollView.drawsBackground = false
        unifiedScrollView.borderType = .noBorder
        unifiedScrollView.autohidesScrollers = true
        unifiedScrollView.scrollerStyle = .overlay
        addSubview(unifiedScrollView)

        unifiedTextView = Self.makeDiffTextView()
        unifiedScrollView.documentView = unifiedTextView

        NSLayoutConstraint.activate([
            unifiedScrollView.topAnchor.constraint(equalTo: actionBarSeparator.bottomAnchor),
            unifiedScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            unifiedScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            unifiedScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupSideBySide() {
        // Container that holds two independent scroll views (left + right)
        // with a vertical separator between them. NSTextView lays out
        // properly only when it is the direct documentView of an NSScrollView,
        // so each side gets its own scroll view and we sync the vertical
        // scrolling via boundsDidChange notifications.
        sideBySideContainer = NSView()
        sideBySideContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sideBySideContainer)

        leftScrollView = Self.makeSideScrollView()
        leftTextView = Self.makeDiffTextView()
        leftScrollView.documentView = leftTextView
        sideBySideContainer.addSubview(leftScrollView)

        sideBySideSeparator = NSView()
        sideBySideSeparator.translatesAutoresizingMaskIntoConstraints = false
        sideBySideSeparator.wantsLayer = true
        sideBySideSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        sideBySideContainer.addSubview(sideBySideSeparator)

        rightScrollView = Self.makeSideScrollView()
        rightTextView = Self.makeDiffTextView()
        rightScrollView.documentView = rightTextView
        sideBySideContainer.addSubview(rightScrollView)

        NSLayoutConstraint.activate([
            sideBySideContainer.topAnchor.constraint(equalTo: actionBarSeparator.bottomAnchor),
            sideBySideContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sideBySideContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sideBySideContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            leftScrollView.topAnchor.constraint(equalTo: sideBySideContainer.topAnchor),
            leftScrollView.bottomAnchor.constraint(equalTo: sideBySideContainer.bottomAnchor),
            leftScrollView.leadingAnchor.constraint(equalTo: sideBySideContainer.leadingAnchor),
            leftScrollView.widthAnchor.constraint(
                equalTo: sideBySideContainer.widthAnchor, multiplier: 0.5, constant: -0.5
            ),

            sideBySideSeparator.topAnchor.constraint(equalTo: sideBySideContainer.topAnchor),
            sideBySideSeparator.bottomAnchor.constraint(equalTo: sideBySideContainer.bottomAnchor),
            sideBySideSeparator.leadingAnchor.constraint(equalTo: leftScrollView.trailingAnchor),
            sideBySideSeparator.widthAnchor.constraint(equalToConstant: 1),

            rightScrollView.topAnchor.constraint(equalTo: sideBySideContainer.topAnchor),
            rightScrollView.bottomAnchor.constraint(equalTo: sideBySideContainer.bottomAnchor),
            rightScrollView.leadingAnchor.constraint(equalTo: sideBySideSeparator.trailingAnchor),
            rightScrollView.trailingAnchor.constraint(equalTo: sideBySideContainer.trailingAnchor),
        ])

        // Sync vertical scrolling between the two clip views.
        leftScrollView.contentView.postsBoundsChangedNotifications = true
        rightScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(leftClipDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: leftScrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(rightClipDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: rightScrollView.contentView
        )
    }

    private static func makeSideScrollView() -> NSScrollView {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        return sv
    }

    @objc private func leftClipDidScroll(_ n: Notification) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        var origin = rightScrollView.contentView.bounds.origin
        origin.y = leftScrollView.contentView.bounds.origin.y
        rightScrollView.contentView.scroll(to: origin)
        rightScrollView.reflectScrolledClipView(rightScrollView.contentView)
        isSyncingScroll = false
    }

    @objc private func rightClipDidScroll(_ n: Notification) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        var origin = leftScrollView.contentView.bounds.origin
        origin.y = rightScrollView.contentView.bounds.origin.y
        leftScrollView.contentView.scroll(to: origin)
        leftScrollView.reflectScrolledClipView(leftScrollView.contentView)
        isSyncingScroll = false
    }

    private static func makeDiffTextView() -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        // Both resizable so the view grows to fit content and horizontal
        // scrolling works inside the parent NSScrollView.
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = []
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        return tv
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.background.cgColor
        actionBar.layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
        actionBarSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        sideBySideSeparator.layer?.backgroundColor = Theme.outlineVariant.cgColor
        unifiedToggleButton.refreshDimState()
        sideBySideToggleButton.refreshDimState()
        pathLabel.textColor = Theme.tertiaryText
        renderDiff()
    }

    // MARK: - Actions

    @objc private func unifiedModeClicked() { setMode(.unified) }
    @objc private func sideBySideModeClicked() { setMode(.sideBySide) }

    private func setMode(_ newMode: DiffDisplayMode) {
        guard displayMode != newMode else { return }
        displayMode = newMode
        updateModeButtons()
        applyModeVisibility()
        renderDiff()
    }

    private func updateModeButtons() {
        unifiedToggleButton.isActiveState = (displayMode == .unified)
        sideBySideToggleButton.isActiveState = (displayMode == .sideBySide)
    }

    private func applyModeVisibility() {
        unifiedScrollView.isHidden = (displayMode != .unified)
        sideBySideContainer.isHidden = (displayMode != .sideBySide)
    }

    private func updateActionButtonStates() {
        switch scope {
        case .workingTree:
            stageButton.isHidden = false
            unstageButton.isHidden = false
            stageButton.isEnabled = true
            unstageButton.isEnabled = false
        case .index:
            stageButton.isHidden = false
            unstageButton.isHidden = false
            stageButton.isEnabled = false
            unstageButton.isEnabled = true
        case .commit:
            // Commit diffs are historical and read-only; hide the stage buttons.
            stageButton.isHidden = true
            unstageButton.isHidden = true
        }
    }

    @objc private func stageClicked() {
        let path = filePath
        let root = repoRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = GitHelper.stage(from: root, paths: [path])
            DispatchQueue.main.async {
                self?.scope = .index
                self?.updateActionButtonStates()
                self?.reload()
            }
        }
    }

    @objc private func unstageClicked() {
        let path = filePath
        let root = repoRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = GitHelper.unstage(from: root, paths: [path])
            DispatchQueue.main.async {
                self?.scope = .workingTree
                self?.updateActionButtonStates()
                self?.reload()
            }
        }
    }

    // MARK: - Rendering (shared parser + renderer)

    private func renderDiff() {
        let rows = Self.parseDiff(diffText)
        switch displayMode {
        case .unified:
            let attr = Self.renderUnified(rows)
            unifiedTextView.textStorage?.setAttributedString(attr)
        case .sideBySide:
            let (leftAS, rightAS) = Self.renderSideBySide(rows)
            leftTextView.textStorage?.setAttributedString(leftAS)
            rightTextView.textStorage?.setAttributedString(rightAS)
        }
    }

    // MARK: - Parsing

    private enum RowKind {
        case fileHeader, hunkHeader, context, delete, add
    }

    private struct Row {
        let kind: RowKind
        let oldLine: Int?
        let newLine: Int?
        let text: String
    }

    private static func parseDiff(_ diff: String) -> [Row] {
        var rows: [Row] = []
        var oldLine = 0
        var newLine = 0
        let lines = diff.components(separatedBy: "\n")
        let effective = (lines.last == "") ? Array(lines.dropLast()) : lines

        for line in effective {
            if line.hasPrefix("@@") {
                if let parsed = parseHunkHeader(line) {
                    oldLine = parsed.oldStart
                    newLine = parsed.newStart
                }
                rows.append(Row(kind: .hunkHeader, oldLine: nil, newLine: nil, text: line))
                continue
            }
            if line.hasPrefix("+++") || line.hasPrefix("---") ||
                line.hasPrefix("diff ") || line.hasPrefix("index ") ||
                line.hasPrefix("new file") || line.hasPrefix("deleted file") ||
                line.hasPrefix("similarity ") || line.hasPrefix("rename ") ||
                line.hasPrefix("Binary ") {
                rows.append(Row(kind: .fileHeader, oldLine: nil, newLine: nil, text: line))
                continue
            }
            let first = line.first
            let content = line.isEmpty ? "" : String(line.dropFirst())
            if first == "+" {
                rows.append(Row(kind: .add, oldLine: nil, newLine: newLine, text: content))
                newLine += 1
            } else if first == "-" {
                rows.append(Row(kind: .delete, oldLine: oldLine, newLine: nil, text: content))
                oldLine += 1
            } else if first == " " {
                rows.append(Row(kind: .context, oldLine: oldLine, newLine: newLine, text: content))
                oldLine += 1
                newLine += 1
            } else if first == "\\" {
                rows.append(Row(kind: .fileHeader, oldLine: nil, newLine: nil, text: line))
            }
        }
        return rows
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        guard let rangeStart = line.range(of: "@@ "),
              let rangeEnd = line.range(of: " @@", range: rangeStart.upperBound..<line.endIndex) else {
            return nil
        }
        let inner = line[rangeStart.upperBound..<rangeEnd.lowerBound]
        let parts = inner.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let oldPart = parts[0]
        let newPart = parts[1]
        guard oldPart.hasPrefix("-"), newPart.hasPrefix("+") else { return nil }
        let oldNums = oldPart.dropFirst().split(separator: ",")
        let newNums = newPart.dropFirst().split(separator: ",")
        let oldStart = Int(oldNums.first ?? "0") ?? 0
        let newStart = Int(newNums.first ?? "0") ?? 0
        return (oldStart, newStart)
    }

    // MARK: - Rendering helpers

    private static func renderUnified(_ rows: [Row]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString()
        if rows.isEmpty {
            return NSAttributedString(
                string: "No changes to display.",
                attributes: [.font: font, .foregroundColor: Theme.tertiaryText]
            )
        }
        var displayLine = 1
        for row in rows {
            let gutter = String(format: "%5d  ", displayLine)
            result.append(NSAttributedString(string: gutter, attributes: [
                .font: font, .foregroundColor: Theme.quaternaryText,
            ]))
            let (fg, bg) = colors(for: row.kind)
            let prefix: String
            switch row.kind {
            case .add: prefix = "+"
            case .delete: prefix = "-"
            case .context: prefix = " "
            default: prefix = ""
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            if let bg = bg { attrs[.backgroundColor] = bg }
            result.append(NSAttributedString(string: prefix + row.text, attributes: attrs))
            result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            displayLine += 1
        }
        return result
    }

    private static func renderSideBySide(_ rows: [Row]) -> (NSAttributedString, NSAttributedString) {
        let left = NSMutableAttributedString()
        let right = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if rows.isEmpty { return (left, right) }

        var i = 0
        while i < rows.count {
            let row = rows[i]
            switch row.kind {
            case .fileHeader:
                appendFullWidth(into: left, text: row.text, font: font, color: Theme.tertiaryText)
                appendFullWidth(into: right, text: row.text, font: font, color: Theme.tertiaryText)
                i += 1
            case .hunkHeader:
                appendFullWidth(into: left, text: row.text, font: font, color: hunkColor())
                appendFullWidth(into: right, text: row.text, font: font, color: hunkColor())
                i += 1
            case .context:
                appendRow(into: left, lineNum: row.oldLine, text: row.text, kind: .context, font: font)
                appendRow(into: right, lineNum: row.newLine, text: row.text, kind: .context, font: font)
                i += 1
            case .delete, .add:
                var deletes: [Row] = []
                while i < rows.count, rows[i].kind == .delete { deletes.append(rows[i]); i += 1 }
                var adds: [Row] = []
                while i < rows.count, rows[i].kind == .add { adds.append(rows[i]); i += 1 }
                let n = max(deletes.count, adds.count)
                for k in 0..<n {
                    if k < deletes.count {
                        appendRow(into: left, lineNum: deletes[k].oldLine, text: deletes[k].text,
                                  kind: .delete, font: font)
                    } else {
                        appendBlankRow(into: left, font: font)
                    }
                    if k < adds.count {
                        appendRow(into: right, lineNum: adds[k].newLine, text: adds[k].text,
                                  kind: .add, font: font)
                    } else {
                        appendBlankRow(into: right, font: font)
                    }
                }
            }
        }
        return (left, right)
    }

    private static func appendFullWidth(
        into target: NSMutableAttributedString,
        text: String, font: NSFont, color: NSColor
    ) {
        target.append(NSAttributedString(string: "       ", attributes: [
            .font: font, .foregroundColor: Theme.quaternaryText,
        ]))
        target.append(NSAttributedString(string: text + "\n", attributes: [
            .font: font, .foregroundColor: color,
        ]))
    }

    private static func appendRow(
        into target: NSMutableAttributedString,
        lineNum: Int?, text: String, kind: RowKind, font: NSFont
    ) {
        let gutter = lineNum.map { String(format: "%5d  ", $0) } ?? "       "
        target.append(NSAttributedString(string: gutter, attributes: [
            .font: font, .foregroundColor: Theme.quaternaryText,
        ]))
        let (fg, bg) = colors(for: kind)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        if let bg = bg { attrs[.backgroundColor] = bg }
        target.append(NSAttributedString(string: text, attributes: attrs))
        target.append(NSAttributedString(string: "\n", attributes: [.font: font]))
    }

    private static func appendBlankRow(into target: NSMutableAttributedString, font: NSFont) {
        let blankBg = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.18)
        target.append(NSAttributedString(string: "       \n", attributes: [
            .font: font, .backgroundColor: blankBg,
        ]))
    }

    private static func colors(for kind: RowKind) -> (NSColor, NSColor?) {
        switch kind {
        case .add:
            return (
                NSColor(srgbRed: 0.55, green: 0.95, blue: 0.60, alpha: 1.00),
                NSColor(srgbRed: 0.20, green: 0.60, blue: 0.30, alpha: 0.20)
            )
        case .delete:
            return (
                NSColor(srgbRed: 0.98, green: 0.60, blue: 0.60, alpha: 1.00),
                NSColor(srgbRed: 0.80, green: 0.25, blue: 0.25, alpha: 0.20)
            )
        case .context:
            return (Theme.secondaryText, nil)
        case .hunkHeader:
            return (hunkColor(), nil)
        case .fileHeader:
            return (Theme.tertiaryText, nil)
        }
    }

    private static func hunkColor() -> NSColor {
        NSColor(srgbRed: 0.60, green: 0.75, blue: 1.00, alpha: 1.00)
    }
}

// MARK: - Flipped view for document-view top-left origin

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
