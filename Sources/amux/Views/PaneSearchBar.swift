import AppKit
import CGhostty

protocol PaneSearchBarDelegate: AnyObject {
    func searchBarDidDismiss(_ searchBar: PaneSearchBar)
}

class PaneSearchBar: NSView {
    weak var delegate: PaneSearchBarDelegate?

    private var searchField: NSTextField!
    private var matchLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var closeButton: NSButton!

    private var surface: ghostty_surface_t?

    static let barHeight: CGFloat = 32

    init(surface: ghostty_surface_t?) {
        self.surface = surface
        super.init(frame: .zero)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        let bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = Theme.borderPrimary.cgColor
        addSubview(bottomBorder)

        searchField = NSTextField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find..."
        searchField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        searchField.textColor = Theme.primaryText
        searchField.backgroundColor = Theme.elevated
        searchField.drawsBackground = true
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        addSubview(searchField)

        matchLabel = NSTextField(labelWithString: "")
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        matchLabel.textColor = Theme.quaternaryText
        matchLabel.isBezeled = false
        matchLabel.isEditable = false
        addSubview(matchLabel)

        prevButton = makeButton(symbolName: "chevron.up", action: #selector(prevMatch))
        addSubview(prevButton)

        nextButton = makeButton(symbolName: "chevron.down", action: #selector(nextMatch))
        addSubview(nextButton)

        closeButton = makeButton(symbolName: "xmark", action: #selector(dismissSearch))
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: matchLabel.leadingAnchor, constant: -8),

            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -8),

            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            prevButton.widthAnchor.constraint(equalToConstant: 22),
            prevButton.heightAnchor.constraint(equalToConstant: 22),

            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            nextButton.widthAnchor.constraint(equalToConstant: 22),
            nextButton.heightAnchor.constraint(equalToConstant: 22),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func makeButton(symbolName: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.title = ""
        btn.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: symbolName
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        )
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = false
        btn.contentTintColor = Theme.tertiaryText
        btn.target = self
        btn.action = action
        if let cell = btn.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }
        return btn
    }

    // MARK: - Public

    func activate() {
        window?.makeFirstResponder(searchField)
    }

    func updateMatchCount(selected: Int, total: Int) {
        if total > 0 {
            matchLabel.stringValue = "\(selected)/\(total)"
        } else if !searchField.stringValue.isEmpty {
            matchLabel.stringValue = "No matches"
        } else {
            matchLabel.stringValue = ""
        }
    }

    // MARK: - Actions

    @objc private func searchFieldAction() {
        performSearch(forward: true)
    }

    @objc private func nextMatch() {
        performSearch(forward: true)
    }

    @objc private func prevMatch() {
        performSearch(forward: false)
    }

    @objc private func dismissSearch() {
        // Clear search highlighting
        if let surface = surface {
            let action = "search:close"
            _ = action.withCString { ptr in
                ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
            }
        }
        delegate?.searchBarDidDismiss(self)
    }

    private func performSearch(forward: Bool) {
        guard let surface = surface else { return }
        let query = searchField.stringValue
        guard !query.isEmpty else { return }

        // Use Ghostty's search binding action
        let direction = forward ? "search:forward" : "search:backward"
        _ = direction.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(direction.utf8.count))
        }
    }
}

// MARK: - NSTextFieldDelegate

extension PaneSearchBar: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Live search as user types -- send search term to ghostty
        guard let surface = surface else { return }
        let query = searchField.stringValue
        if query.isEmpty {
            let action = "search:close"
            _ = action.withCString { ptr in
                ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
            }
            matchLabel.stringValue = ""
        } else {
            // Start search with the current query
            let action = "search:start"
            _ = action.withCString { ptr in
                ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            dismissSearch()
            return true
        }
        return false
    }
}
