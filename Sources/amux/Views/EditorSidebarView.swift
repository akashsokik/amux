import AppKit
import Neon
import SwiftTreeSitter

// MARK: - EditorSidebarView Delegate

protocol EditorSidebarViewDelegate: AnyObject {
    func editorSidebarDidToggle(visible: Bool)
    func editorSidebarDidRequestToggleExpand()
}

// MARK: - EditorSidebarView

class EditorSidebarView: NSView {
    weak var delegate: EditorSidebarViewDelegate?

    private var tabs: [EditorTab] = []
    private var activeTabID: UUID?

    private var glassView: GlassBackgroundView?
    private var separatorLine: NSView!
    private var tabStripView: EditorTabStripView!
    private var headerView: EditorHeaderView!
    private var contentContainer: NSView!
    private var editorContentView: EditorTextContentView!
    private var placeholderLabel: NSTextField!
    private var unsupportedLabel: NSTextField!

    private var tabStripTopConstraint: NSLayoutConstraint!

    /// Distance from the view's top to the tab strip. Default 40pt reserves space
    /// for the window toolbar. Set to 0 when embedded below a shared header (e.g.
    /// a tabbed container that already accounts for the toolbar).
    var topContentInset: CGFloat = 40 {
        didSet { tabStripTopConstraint?.constant = topContentInset }
    }

    /// Hide the view's own separator + glass. Use when wrapped in a container
    /// that draws shared chrome.
    var chromeHidden: Bool = false {
        didSet {
            separatorLine?.isHidden = chromeHidden
            if chromeHidden { glassView?.isHidden = true }
        }
    }

    private let fileLoadQueue = DispatchQueue(
        label: "amux.editor-file-load",
        qos: .userInitiated
    )

    private var editorSurfaceColor: NSColor {
        Theme.sidebarBg
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: Theme.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    func setGlassHidden(_ hidden: Bool) {
        glassView?.isHidden = hidden
        if hidden {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
        } else {
            applyGlassOrSolid()
        }
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy {
            layer?.backgroundColor = NSColor.clear.cgColor
            if glassView == nil {
                let gv = GlassBackgroundView()
                gv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(gv, positioned: .below, relativeTo: subviews.first)
                NSLayoutConstraint.activate([
                    gv.topAnchor.constraint(equalTo: topAnchor),
                    gv.bottomAnchor.constraint(equalTo: bottomAnchor),
                    gv.leadingAnchor.constraint(equalTo: leadingAnchor),
                    gv.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                glassView = gv
            }
            glassView?.isHidden = false
            glassView?.setTint(Theme.sidebarBg)
        } else {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
            glassView?.isHidden = true
        }
    }

    @objc private func themeDidChange() {
        applyGlassOrSolid()
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        contentContainer.layer?.backgroundColor = editorSurfaceColor.cgColor
        placeholderLabel.textColor = Theme.tertiaryText
        unsupportedLabel.textColor = Theme.tertiaryText
        tabStripView.refreshTheme()
        headerView.refreshTheme()
        editorContentView.refreshTheme()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        separatorLine = NSView()

        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = Theme.outlineVariant.cgColor
        addSubview(separatorLine)

        tabStripView = EditorTabStripView()
        tabStripView.translatesAutoresizingMaskIntoConstraints = false
        tabStripView.delegate = self
        addSubview(tabStripView)

        headerView = EditorHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onSave = { [weak self] in
            self?.saveActiveTab()
        }
        headerView.onClose = { [weak self] in
            self?.closeActiveTab()
        }
        headerView.onToggleExpand = { [weak self] in
            self?.delegate?.editorSidebarDidRequestToggleExpand()
        }
        addSubview(headerView)

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = editorSurfaceColor.cgColor
        addSubview(contentContainer)

        editorContentView = EditorTextContentView()
        editorContentView.translatesAutoresizingMaskIntoConstraints = false
        editorContentView.isHidden = true
        editorContentView.onTextChange = { [weak self] newContent in
            guard let self, let tab = self.activeTab else { return }
            tab.updateContent(newContent)
            self.refreshChrome()
        }
        contentContainer.addSubview(editorContentView)

        placeholderLabel = NSTextField(labelWithString: "Click a file in the tree to open it")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = Theme.Fonts.body(size: 12)
        placeholderLabel.textColor = Theme.tertiaryText
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0
        contentContainer.addSubview(placeholderLabel)

        unsupportedLabel = NSTextField(
            labelWithString: "This file cannot be edited inline yet.\nUse Open in Editor to continue."
        )
        unsupportedLabel.translatesAutoresizingMaskIntoConstraints = false
        unsupportedLabel.font = Theme.Fonts.body(size: 12)
        unsupportedLabel.textColor = Theme.tertiaryText
        unsupportedLabel.alignment = .center
        unsupportedLabel.lineBreakMode = .byWordWrapping
        unsupportedLabel.maximumNumberOfLines = 0
        unsupportedLabel.isHidden = true
        contentContainer.addSubview(unsupportedLabel)

        let contentLeading = separatorLine.trailingAnchor

        tabStripTopConstraint = tabStripView.topAnchor.constraint(equalTo: topAnchor, constant: topContentInset)

        NSLayoutConstraint.activate([
            separatorLine.topAnchor.constraint(equalTo: topAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 1),

            tabStripTopConstraint,
            tabStripView.leadingAnchor.constraint(equalTo: contentLeading),
            tabStripView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabStripView.heightAnchor.constraint(equalToConstant: EditorTabStripView.barHeight),

            headerView.topAnchor.constraint(equalTo: tabStripView.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentLeading),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentLeading),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            editorContentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            editorContentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            editorContentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            editorContentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            placeholderLabel.widthAnchor.constraint(
                lessThanOrEqualTo: contentContainer.widthAnchor,
                constant: -40
            ),

            unsupportedLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            unsupportedLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            unsupportedLabel.widthAnchor.constraint(
                lessThanOrEqualTo: contentContainer.widthAnchor,
                constant: -40
            ),
        ])

        renderState()
        applyGlassOrSolid()
    }

    // MARK: - Public API

    func setExpanded(_ expanded: Bool) {
        headerView.setExpanded(expanded)
    }

    func openFile(at path: String) {
        if let existingTab = tabs.first(where: { $0.filePath == path }) {
            activateTab(existingTab.id)
            return
        }

        fileLoadQueue.async { [weak self] in
            do {
                let loaded = try EditorTab.load(from: path)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    if let existingTab = self.tabs.first(where: { $0.filePath == path }) {
                        self.activateTab(existingTab.id)
                        return
                    }

                    let tab: EditorTab
                    switch loaded {
                    case .text(let content, let encoding):
                        tab = EditorTab(
                            filePath: path,
                            content: content,
                            encoding: encoding
                        )
                    case .unsupported:
                        tab = EditorTab(unsupportedFileAt: path)
                    }

                    self.tabs.append(tab)
                    self.activateTab(tab.id)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.presentError(
                        title: "Unable to Open File",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    var hasOpenTabs: Bool {
        !tabs.isEmpty
    }

    func handlesTabShortcuts(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let firstResponder = window.firstResponder as? NSView {
            return firstResponder.isDescendant(of: self)
        }
        return window.firstResponder === self
    }

    func saveActiveTab() {
        guard let tab = activeTab, tab.isEditable else { return }
        tab.updateContent(editorContentView.stringValue)

        do {
            try tab.save()
            refreshChrome()
        } catch {
            presentError(
                title: "Unable to Save File",
                message: error.localizedDescription
            )
        }
    }

    func selectNextTab() {
        guard let activeTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs.count > 1 else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        activateTab(tabs[nextIndex].id)
    }

    func selectPreviousTab() {
        guard let activeTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs.count > 1 else { return }
        let previousIndex = (currentIndex - 1 + tabs.count) % tabs.count
        activateTab(tabs[previousIndex].id)
    }

    func closeCurrentTab() {
        closeActiveTab()
    }

    // MARK: - State management

    private func activateTab(_ tabID: UUID) {
        activeTabID = tabID
        renderState()
        focusActiveTab()
    }

    private func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    private func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]

        if tab.isDirty {
            promptSaveBeforeClosing(tab: tab) { [weak self] shouldClose in
                guard shouldClose else { return }
                self?.removeTab(at: index)
            }
            return
        }

        removeTab(at: index)
    }

    private func removeTab(at index: Int) {
        let removedTab = tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
        } else if removedTab.id == activeTabID {
            let nextIndex = min(index, tabs.count - 1)
            activeTabID = tabs[nextIndex].id
        }

        renderState()
    }

    private func renderState() {
        refreshChrome()

        guard let tab = activeTab else {
            placeholderLabel.isHidden = false
            unsupportedLabel.isHidden = true
            editorContentView.isHidden = true
            return
        }

        placeholderLabel.isHidden = true

        if tab.isEditable {
            unsupportedLabel.isHidden = true
            editorContentView.isHidden = false
            editorContentView.setText(
                tab.content,
                fileExtension: tab.fileExtension,
                isEditable: true
            )
        } else {
            editorContentView.isHidden = true
            unsupportedLabel.isHidden = false
        }
    }

    private func refreshChrome() {
        tabStripView.updateTabs(tabs, activeID: activeTabID)

        guard let tab = activeTab else {
            headerView.clear()
            return
        }

        headerView.configure(
            filePath: tab.filePath,
            isDirty: tab.isDirty,
            canSave: tab.isEditable && tab.isDirty,
            canClose: true
        )
    }

    private func promptSaveBeforeClosing(
        tab: EditorTab,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window else {
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
                do {
                    try tab.save()
                    completion(true)
                } catch {
                    self.presentError(
                        title: "Unable to Save File",
                        message: error.localizedDescription
                    )
                    completion(false)
                }
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    private func presentError(title: String, message: String) {
        guard let window else {
            print("[EditorSidebarView] \(title): \(message)")
            return
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func focusActiveTab() {
        guard window != nil else { return }
        if activeTab?.isEditable == true {
            editorContentView.focusEditor()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

extension EditorSidebarView: EditorTabStripViewDelegate {
    func editorTabStripView(_ view: EditorTabStripView, didSelectTab tabID: UUID) {
        activateTab(tabID)
    }

    func editorTabStripView(_ view: EditorTabStripView, didCloseTab tabID: UUID) {
        closeTab(tabID)
    }
}

// MARK: - EditorTabStripView

protocol EditorTabStripViewDelegate: AnyObject {
    func editorTabStripView(_ view: EditorTabStripView, didSelectTab tabID: UUID)
    func editorTabStripView(_ view: EditorTabStripView, didCloseTab tabID: UUID)
}

class EditorTabStripView: NSView {
    static let barHeight: CGFloat = 30

    weak var delegate: EditorTabStripViewDelegate?

    private var glassView: GlassBackgroundView?
    private var scrollView: NSScrollView!
    private var tabContainer: NSView!
    private var tabItemViews: [EditorTabItemView] = []

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

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScroller = ThinScroller()
        addSubview(scrollView)

        tabContainer = NSView(frame: .zero)
        scrollView.documentView = tabContainer

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshTheme()
    }

    func updateTabs(_ tabs: [EditorTab], activeID: UUID?) {
        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        for tab in tabs {
            let item = EditorTabItemView(tabID: tab.id, title: tab.fileName, isDirty: tab.isDirty)
            item.delegate = self
            item.isActive = (tab.id == activeID)
            item.toolTip = tab.filePath
            tabContainer.addSubview(item)
            tabItemViews.append(item)
        }

        layoutTabItems()
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy {
            layer?.backgroundColor = NSColor.clear.cgColor
            if glassView == nil {
                let gv = GlassBackgroundView()
                gv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(gv, positioned: .below, relativeTo: subviews.first)
                NSLayoutConstraint.activate([
                    gv.topAnchor.constraint(equalTo: topAnchor),
                    gv.bottomAnchor.constraint(equalTo: bottomAnchor),
                    gv.leadingAnchor.constraint(equalTo: leadingAnchor),
                    gv.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                glassView = gv
            }
            glassView?.isHidden = false
            glassView?.setTint(Theme.surfaceContainerLow)
        } else {
            layer?.backgroundColor = Theme.surfaceContainerLow.cgColor
            glassView?.isHidden = true
        }
    }

    func refreshTheme() {
        applyGlassOrSolid()
        for item in tabItemViews {
            item.refreshTheme()
        }
    }

    private func layoutTabItems() {
        var x: CGFloat = 6
        let y: CGFloat = 2
        let height = max(bounds.height - 4, 0)

        for item in tabItemViews {
            let width = item.intrinsicContentSize.width
            item.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 2
        }

        tabContainer.frame = NSRect(
            x: 0,
            y: 0,
            width: max(x + 4, scrollView.bounds.width),
            height: max(bounds.height, 0)
        )
    }

    override func layout() {
        super.layout()
        layoutTabItems()
    }
}

extension EditorTabStripView: EditorTabItemViewDelegate {
    func editorTabItemDidSelect(_ item: EditorTabItemView) {
        delegate?.editorTabStripView(self, didSelectTab: item.tabID)
    }

    func editorTabItemDidClose(_ item: EditorTabItemView) {
        delegate?.editorTabStripView(self, didCloseTab: item.tabID)
    }
}

// MARK: - EditorHeaderView

class EditorHeaderView: NSView {
    private var glassView: GlassBackgroundView?
    private var pathLabel: NSTextField!
    private var expandButton: DimIconButton!
    private var saveButton: DimIconButton!
    private var editorDropdown: EditorDropdownButton!
    private var closeButton: DimIconButton!
    private var bottomBorder: NSView!

    private var currentFilePath: String?
    private(set) var isExpanded = false

    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleExpand: (() -> Void)?

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
        layer?.backgroundColor = Theme.sidebarBg.cgColor

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = Theme.Fonts.label(size: 10)
        pathLabel.backgroundColor = .clear
        pathLabel.isBezeled = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = false
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        addSubview(pathLabel)

        expandButton = DimIconButton()
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.image = NSImage(
            systemSymbolName: "arrow.left.and.line.vertical.and.arrow.right",
            accessibilityDescription: "Expand Editor"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        expandButton.imagePosition = .imageOnly
        expandButton.bezelStyle = .accessoryBarAction
        expandButton.isBordered = false
        expandButton.target = self
        expandButton.action = #selector(expandClicked)
        expandButton.toolTip = "Expand Editor"
        expandButton.refreshDimState()
        addSubview(expandButton)

        saveButton = DimIconButton()
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: "Save File"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        saveButton.imagePosition = .imageOnly
        saveButton.bezelStyle = .accessoryBarAction
        saveButton.isBordered = false
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.toolTip = "Save (Shift-Cmd-S)"
        saveButton.refreshDimState()
        addSubview(saveButton)

        editorDropdown = EditorDropdownButton()
        editorDropdown.translatesAutoresizingMaskIntoConstraints = false
        editorDropdown.onOpenFile = { [weak self] bundleID in
            guard let path = self?.currentFilePath else { return }
            ExternalEditorHelper.openIn(filePath: path, bundleID: bundleID)
        }
        addSubview(editorDropdown)

        closeButton = DimIconButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close File"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        )
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.refreshDimState()
        addSubview(closeButton)

        bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        addSubview(bottomBorder)

        // Icon cluster: group all action buttons tightly
        let iconCluster = NSStackView(views: [expandButton, saveButton, editorDropdown, closeButton])
        iconCluster.translatesAutoresizingMaskIntoConstraints = false
        iconCluster.orientation = .horizontal
        iconCluster.spacing = 2
        iconCluster.alignment = .centerY
        addSubview(iconCluster)

        let iconSize: CGFloat = 20

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: iconCluster.leadingAnchor,
                constant: -8
            ),

            iconCluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            iconCluster.centerYAnchor.constraint(equalTo: centerYAnchor),

            expandButton.widthAnchor.constraint(equalToConstant: iconSize),
            expandButton.heightAnchor.constraint(equalToConstant: iconSize),
            saveButton.widthAnchor.constraint(equalToConstant: iconSize),
            saveButton.heightAnchor.constraint(equalToConstant: iconSize),
            editorDropdown.heightAnchor.constraint(equalToConstant: iconSize),
            closeButton.widthAnchor.constraint(equalToConstant: iconSize),
            closeButton.heightAnchor.constraint(equalToConstant: iconSize),

            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        refreshTheme()
        clear()
    }

    func configure(filePath: String, isDirty: Bool, canSave: Bool, canClose: Bool) {
        currentFilePath = filePath

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = filePath
        if display.hasPrefix(home) {
            display = "~" + display.dropFirst(home.count)
        }

        pathLabel.stringValue = isDirty ? "\(display) *" : display
        pathLabel.toolTip = filePath
        saveButton.isHidden = false
        saveButton.isEnabled = canSave
        editorDropdown.isHidden = false
        editorDropdown.isEnabled = true
        closeButton.isHidden = false
        closeButton.isEnabled = canClose
    }

    func clear() {
        currentFilePath = nil
        pathLabel.stringValue = ""
        pathLabel.toolTip = nil
        saveButton.isHidden = true
        editorDropdown.isHidden = true
        closeButton.isHidden = true
    }

    private func applyGlassOrSolid() {
        if Theme.useVibrancy {
            layer?.backgroundColor = NSColor.clear.cgColor
            if glassView == nil {
                let gv = GlassBackgroundView()
                gv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(gv, positioned: .below, relativeTo: subviews.first)
                NSLayoutConstraint.activate([
                    gv.topAnchor.constraint(equalTo: topAnchor),
                    gv.bottomAnchor.constraint(equalTo: bottomAnchor),
                    gv.leadingAnchor.constraint(equalTo: leadingAnchor),
                    gv.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                glassView = gv
            }
            glassView?.isHidden = false
            glassView?.setTint(Theme.sidebarBg)
        } else {
            layer?.backgroundColor = Theme.sidebarBg.cgColor
            glassView?.isHidden = true
        }
    }

    func refreshTheme() {
        applyGlassOrSolid()
        bottomBorder.layer?.backgroundColor = Theme.outlineVariant.cgColor
        pathLabel.textColor = Theme.tertiaryText
        expandButton.refreshDimState()
        saveButton.refreshDimState()
        editorDropdown.refreshTheme()
        closeButton.refreshDimState()
    }

    @objc private func expandClicked() {
        onToggleExpand?()
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        let symbolName = expanded
            ? "arrow.right.and.line.vertical.and.arrow.left"
            : "arrow.left.and.line.vertical.and.arrow.right"
        expandButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: expanded ? "Collapse Editor" : "Expand Editor"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        expandButton.toolTip = expanded ? "Collapse Editor" : "Expand Editor"
    }

    @objc private func saveClicked() {
        onSave?()
    }

    @objc private func closeClicked() {
        onClose?()
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

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let closeButton = DimIconButton()
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

    private var isHovered = false {
        didSet { updateAppearance() }
    }

    private var iconColor: NSColor = Theme.tertiaryText

    init(tabID: UUID, title: String, isDirty: Bool, fileExtension: String = "") {
        self.tabID = tabID
        self.title = title
        self.isDirty = isDirty
        let info = FileIconInfo.forFile(named: title)
        self.iconColor = info.color
        super.init(frame: .zero)
        setupSubviews(iconInfo: info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews(iconInfo: FileIconInfo) {
        wantsLayer = true

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = Theme.CornerRadius.element
        addSubview(highlightView)

        iconView.image = NSImage(
            systemSymbolName: iconInfo.symbolName,
            accessibilityDescription: "File"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        iconView.contentTintColor = iconInfo.color
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.layer?.backgroundColor = Theme.primary.cgColor
        dirtyDot.isHidden = !isDirty
        addSubview(dirtyDot)

        titleLabel.stringValue = title
        titleLabel.font = Theme.Fonts.label(size: 12)
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
            NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        )
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.refreshDimState()
        addSubview(closeButton)

        updateAppearance()
    }

    private static let minTabWidth: CGFloat = 120
    private static let maxTitleWidth: CGFloat = 168

    override var intrinsicContentSize: NSSize {
        let titleWidth = min(titleLabel.intrinsicContentSize.width, Self.maxTitleWidth)
        let dirtyWidth: CGFloat = isDirty ? 10 : 0
        let naturalWidth = 8 + 14 + 5 + titleWidth + dirtyWidth + 4 + 14 + 6
        return NSSize(width: max(Self.minTabWidth, naturalWidth), height: 24)
    }

    override func layout() {
        super.layout()
        highlightView.frame = bounds

        let iconSize: CGFloat = 14
        let iconX: CGFloat = 8
        iconView.frame = NSRect(
            x: iconX,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        let closeSize: CGFloat = 14
        let closeX = bounds.width - 6 - closeSize
        closeButton.frame = NSRect(
            x: closeX,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )

        var titleRightInset: CGFloat = 24
        if isDirty {
            let dotSize: CGFloat = 6
            dirtyDot.frame = NSRect(
                x: closeX - 6 - dotSize,
                y: (bounds.height - dotSize) / 2,
                width: dotSize,
                height: dotSize
            )
            titleRightInset = 34
        } else {
            dirtyDot.frame = .zero
        }

        let titleX = iconX + iconSize + 5
        let titleWidth = max(0, bounds.width - titleX - titleRightInset)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: titleX,
            y: (bounds.height - titleHeight) / 2,
            width: titleWidth,
            height: titleHeight
        )
    }

    private func updateAppearance() {
        if isActive {
            highlightView.layer?.backgroundColor = Theme.surfaceContainerHigh.cgColor
            titleLabel.textColor = Theme.primaryText
            iconView.contentTintColor = iconColor
            iconView.alphaValue = 1.0
        } else if isHovered {
            highlightView.layer?.backgroundColor = Theme.hoverBg.cgColor
            titleLabel.textColor = Theme.secondaryText
            iconView.contentTintColor = iconColor
            iconView.alphaValue = 1.0
        } else {
            highlightView.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = Theme.tertiaryText
            iconView.contentTintColor = iconColor
            iconView.alphaValue = 1.0
        }

        closeButton.isHidden = !(isActive || isHovered)
        closeButton.refreshDimState()
    }

    func refreshTheme() {
        dirtyDot.layer?.backgroundColor = Theme.primary.cgColor
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
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

// MARK: - EditorActionButton

class EditorActionButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet { refreshTheme() }
    }

    override var isHighlighted: Bool {
        didSet { refreshTheme() }
    }

    override var isEnabled: Bool {
        didSet { refreshTheme() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: 22)
    }

    func refreshTheme() {
        layer?.cornerRadius = Theme.CornerRadius.element
        layer?.borderWidth = 1
        layer?.borderColor = Theme.outlineVariant.cgColor

        if !isEnabled {
            layer?.backgroundColor = Theme.surfaceContainerHigh.withAlphaComponent(0.35).cgColor
        } else if isHighlighted {
            layer?.backgroundColor = Theme.activeBg.cgColor
        } else if isHovered {
            layer?.backgroundColor = Theme.hoverBg.cgColor
        } else {
            layer?.backgroundColor = Theme.surfaceContainerHigh.cgColor
        }

        let foreground: NSColor
        if !isEnabled {
            foreground = Theme.quaternaryText
        } else if isHighlighted {
            foreground = Theme.primaryText
        } else {
            foreground = Theme.secondaryText
        }

        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.Fonts.label(size: 10),
                .foregroundColor: foreground,
            ]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}


// MARK: - EditorDropdownButton

class EditorDropdownButton: NSView {
    var onOpenFile: ((String) -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let chevron = NSImageView()
    private let mainBg = NSView()
    private let chevronBg = NSView()
    private var trackingAreaRef: NSTrackingArea?

    private enum HoverZone { case none, main, chevron }
    private var hoverZone: HoverZone = .none { didSet { refreshTheme() } }

    var isEnabled: Bool = true {
        didSet { refreshTheme() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true

        mainBg.wantsLayer = true
        mainBg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainBg)

        chevronBg.wantsLayer = true
        chevronBg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronBg)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        )
        chevron.imageScaling = .scaleProportionallyUpOrDown
        addSubview(chevron)

        NSLayoutConstraint.activate([
            mainBg.topAnchor.constraint(equalTo: topAnchor),
            mainBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainBg.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            mainBg.bottomAnchor.constraint(equalTo: bottomAnchor),

            chevronBg.topAnchor.constraint(equalTo: topAnchor),
            chevronBg.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            chevronBg.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevronBg.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 12),

            chevron.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
            chevron.heightAnchor.constraint(equalToConstant: 8),
        ])

        updateLabel()
        refreshTheme()
    }

    override var intrinsicContentSize: NSSize {
        let labelWidth = label.intrinsicContentSize.width
        // icon(14) + gap(4) + label + gap(4) + divider(1) + gap(4) + chevron(8) + padding(11)
        return NSSize(width: 6 + 14 + 4 + labelWidth + 4 + 1 + 4 + 8 + 5, height: 22)
    }

    private func updateLabel() {
        let editor = ExternalEditorHelper.defaultEditor()
        label.stringValue = editor?.name ?? "Open"
        if let editor {
            iconView.image = ExternalEditorHelper.appIcon(for: editor.bundleID, size: 14)
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }
        invalidateIntrinsicContentSize()
    }

    func refreshTheme() {
        let radius = Theme.CornerRadius.element
        let border = Theme.outlineVariant.cgColor
        let restBg = Theme.surfaceContainerHigh.cgColor
        let disabledBg = Theme.surfaceContainerHigh.withAlphaComponent(0.35).cgColor
        let hoverBg = Theme.hoverBg.cgColor

        // Main button area - round left corners only
        mainBg.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        mainBg.layer?.cornerRadius = radius
        mainBg.layer?.borderWidth = 1
        mainBg.layer?.borderColor = border

        // Chevron area - round right corners only
        chevronBg.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        chevronBg.layer?.cornerRadius = radius
        chevronBg.layer?.borderWidth = 1
        chevronBg.layer?.borderColor = border

        if !isEnabled {
            mainBg.layer?.backgroundColor = disabledBg
            chevronBg.layer?.backgroundColor = disabledBg
        } else {
            mainBg.layer?.backgroundColor = hoverZone == .main ? hoverBg : restBg
            chevronBg.layer?.backgroundColor = hoverZone == .chevron ? hoverBg : restBg
        }

        let foreground: NSColor = isEnabled ? Theme.secondaryText : Theme.quaternaryText
        label.font = Theme.Fonts.label(size: 10)
        label.textColor = foreground
        divider.layer?.backgroundColor = Theme.outlineVariant.withAlphaComponent(0.5).cgColor
        chevron.contentTintColor = foreground
        chevron.alphaValue = isEnabled ? 0.6 : 0.3
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if localPoint.x >= divider.frame.minX {
            showMenu()
        } else {
            openDefaultEditor()
        }
    }

    private func openDefaultEditor() {
        guard let editor = ExternalEditorHelper.defaultEditor() else {
            showMenu()
            return
        }
        onOpenFile?(editor.bundleID)
    }

    private func showMenu() {
        let menu = NSMenu()
        let installed = ExternalEditorHelper.installedEditors()
        let defaultBundleID = ExternalEditorHelper.defaultEditor()?.bundleID

        if installed.isEmpty {
            let item = NSMenuItem(title: "No editors found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for editor in installed {
                let item = NSMenuItem(
                    title: editor.name,
                    action: #selector(editorMenuItemClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = editor.bundleID
                item.image = ExternalEditorHelper.appIcon(for: editor.bundleID, size: 16)
                if editor.bundleID == defaultBundleID {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: bounds.height + 2),
            in: self
        )
    }

    @objc private func editorMenuItemClicked(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        ExternalEditorHelper.setDefaultEditor(bundleID)
        updateLabel()
        onOpenFile?(bundleID)
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func zoneForEvent(_ event: NSEvent) -> HoverZone {
        let x = convert(event.locationInWindow, from: nil).x
        return x >= divider.frame.minX ? .chevron : .main
    }

    override func mouseEntered(with event: NSEvent) { hoverZone = zoneForEvent(event) }
    override func mouseMoved(with event: NSEvent) { hoverZone = zoneForEvent(event) }
    override func mouseExited(with event: NSEvent) { hoverZone = .none }
}

// MARK: - EditorTextContentView

class EditorTextContentView: NSView, NSTextViewDelegate {
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var highlighter: TextViewHighlighter?
    private var highlighterLanguage = ""
    private var isBindingText = false
    private var currentFileExtension = ""

    var onTextChange: ((String) -> Void)?

    private var editorSurfaceColor: NSColor {
        Theme.sidebarBg
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var stringValue: String {
        textView.string
    }

    private func setupUI() {
        wantsLayer = true

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScroller = ThinScroller()
        scrollView.horizontalScroller = ThinScroller()
        addSubview(scrollView)

        textView = NSTextView()
        textView.delegate = self
        textView.isRichText = false
        textView.drawsBackground = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 100,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshTheme()
    }

    func setText(_ text: String, fileExtension: String, isEditable: Bool) {
        let newLang = TreeSitterManager.shared.languageName(for: fileExtension) ?? ""
        let needsNewHighlighter = highlighterLanguage != newLang

        // If language is changing, tear down old highlighter BEFORE setting text
        // so the old storage delegate doesn't process the new content.
        if needsNewHighlighter {
            highlighter = nil
            highlighterLanguage = ""
        }

        isBindingText = true
        currentFileExtension = fileExtension
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textColor = isEditable ? Theme.primaryText : Theme.secondaryText
        isBindingText = false

        if needsNewHighlighter {
            configureHighlighter()
        }
        // When the language hasn't changed, Neon's storage delegate already
        // handled the text change -- no need to invalidate again.
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    func refreshTheme() {
        layer?.backgroundColor = editorSurfaceColor.cgColor
        scrollView.backgroundColor = editorSurfaceColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = editorSurfaceColor
        textView.insertionPointColor = Theme.primaryText
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.activeBg,
            .foregroundColor: Theme.primaryText,
        ]
        if textView.isEditable {
            textView.textColor = Theme.primaryText
        } else {
            textView.textColor = Theme.secondaryText
        }
        // Theme colors changed -- need to recreate highlighter since the
        // attribute provider closure captures colors at creation time.
        configureHighlighter()
    }

    func textDidChange(_ notification: Notification) {
        guard !isBindingText else { return }
        onTextChange?(textView.string)
    }

    private func configureHighlighter() {
        // Drop the old highlighter (resets text storage delegate, etc.)
        highlighter = nil
        highlighterLanguage = ""

        guard let config = TreeSitterManager.shared.configuration(for: currentFileExtension) else {
            // No grammar for this file type -- leave text unstyled
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Set typing attributes so new text gets a sensible default style
        textView.typingAttributes = [
            .foregroundColor: Theme.primaryText,
            .font: font,
        ]

        let highlighterConfig = TextViewHighlighter.Configuration(
            languageConfiguration: config,
            attributeProvider: { token in
                Self.attributes(for: token.name)
            },
            languageProvider: { name in
                // We don't support embedded languages yet
                nil
            },
            locationTransformer: { _ in nil }
        )

        do {
            highlighter = try TextViewHighlighter(
                textView: textView,
                configuration: highlighterConfig
            )
            highlighter?.observeEnclosingScrollView()
            highlighterLanguage = TreeSitterManager.shared.languageName(for: currentFileExtension) ?? ""
        } catch {
            // If tree-sitter setup fails, fall back to plain text
            highlighter = nil
        }
    }

    private static func attributes(for tokenName: String) -> [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let color: NSColor

        if tokenName.hasPrefix("keyword") {
            // Soft pink/magenta
            color = NSColor.systemPink.blended(withFraction: 0.3, of: Theme.primaryText) ?? .systemPink
        } else if tokenName.hasPrefix("string") {
            // Warm green
            color = NSColor.systemGreen.blended(withFraction: 0.25, of: Theme.primaryText) ?? .systemGreen
        } else if tokenName.hasPrefix("comment") {
            color = Theme.tertiaryText
        } else if tokenName.hasPrefix("number") || tokenName.hasPrefix("float") {
            // Orange/amber
            color = NSColor.systemOrange.blended(withFraction: 0.2, of: Theme.primaryText) ?? .systemOrange
        } else if tokenName.hasPrefix("type") || tokenName.hasPrefix("constructor") {
            // Teal/cyan
            color = NSColor.systemTeal.blended(withFraction: 0.2, of: Theme.primaryText) ?? .systemTeal
        } else if tokenName.hasPrefix("function") || tokenName.hasPrefix("method") {
            // Blue
            color = NSColor.systemBlue.blended(withFraction: 0.2, of: Theme.primaryText) ?? .systemBlue
        } else if tokenName.hasPrefix("property") || tokenName.hasPrefix("variable.member") {
            // Light purple
            color = NSColor.systemIndigo.blended(withFraction: 0.35, of: Theme.primaryText) ?? .systemIndigo
        } else if tokenName.hasPrefix("operator") {
            color = Theme.secondaryText
        } else if tokenName.hasPrefix("punctuation") {
            color = Theme.tertiaryText
        } else if tokenName.hasPrefix("constant") {
            // Warm orange
            color = NSColor.systemOrange.blended(withFraction: 0.3, of: Theme.primaryText) ?? .systemOrange
        } else if tokenName.hasPrefix("variable") {
            color = Theme.primaryText
        } else if tokenName.hasPrefix("tag") {
            // Red for HTML tags
            color = NSColor.systemRed.blended(withFraction: 0.3, of: Theme.primaryText) ?? .systemRed
        } else if tokenName.hasPrefix("attribute") {
            // Yellow for attributes
            color = NSColor.systemYellow.blended(withFraction: 0.25, of: Theme.primaryText) ?? .systemYellow
        } else if tokenName.hasPrefix("text.title") || tokenName.hasPrefix("markup.heading") {
            // Bold headings
            color = NSColor.systemBlue.blended(withFraction: 0.15, of: Theme.primaryText) ?? .systemBlue
        } else if tokenName.hasPrefix("text.uri") || tokenName.hasPrefix("markup.link") {
            color = NSColor.systemTeal.blended(withFraction: 0.2, of: Theme.primaryText) ?? .systemTeal
        } else if tokenName.hasPrefix("text.literal") || tokenName.hasPrefix("markup.raw") {
            color = NSColor.systemGreen.blended(withFraction: 0.25, of: Theme.primaryText) ?? .systemGreen
        } else if tokenName.hasPrefix("text.reference") {
            color = NSColor.systemIndigo.blended(withFraction: 0.3, of: Theme.primaryText) ?? .systemIndigo
        } else if tokenName.hasPrefix("text.emphasis") {
            color = NSColor.systemYellow.blended(withFraction: 0.3, of: Theme.primaryText) ?? .systemYellow
        } else if tokenName.hasPrefix("text.strong") {
            color = NSColor.systemOrange.blended(withFraction: 0.2, of: Theme.primaryText) ?? .systemOrange
        } else {
            color = Theme.primaryText
        }

        return [
            .foregroundColor: color,
            .font: font,
        ]
    }
}
