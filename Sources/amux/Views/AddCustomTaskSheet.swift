import AppKit

// MARK: - Add Custom Task Sheet
//
// Modal sheet used by RunnerPanelView to collect a name / command / cwd from
// the user and produce a PinnedTask. The sheet only validates form-level input
// (non-empty name + command + derivable id); persistence and collisions with
// existing detected tasks are the caller's concern.

final class AddCustomTaskSheet: NSWindow {
    /// Confirm handler: receives the built task and a `dismiss` closure that
    /// ends the sheet. Call `dismiss()` only after the task has been
    /// successfully persisted; skip it to keep the sheet open (e.g. after
    /// surfacing an error the user should react to).
    typealias ConfirmHandler = (_ task: PinnedTask, _ dismiss: @escaping () -> Void) -> Void

    /// Set by the presenter before calling `beginSheet(_:)`. Settable so the
    /// handler can reference the sheet instance (needed to present an error
    /// alert on the sheet itself).
    var onConfirmHandler: ConfirmHandler?
    var onCancelHandler: (() -> Void)?

    private let existingPinnedIDs: Set<String>

    private let nameField = NSTextField()
    private let commandField = NSTextField()
    private let cwdField = NSTextField()
    private let addActionButton = NSButton(title: "Add", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // Kept alive so `controlTextDidChange` callbacks reach us — NSTextField's
    // `delegate` is weak.
    private lazy var textDelegate: TextDelegate = TextDelegate(owner: self)

    init(existingPinnedIDs: Set<String>) {
        self.existingPinnedIDs = existingPinnedIDs

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        self.title = "Add Custom Task"
        self.isReleasedWhenClosed = false

        buildContent()
        updateAddEnabled()
    }

    // MARK: - Layout

    private func buildContent() {
        guard let content = contentView else { return }
        content.wantsLayer = true

        let nameLabel = makeLabel("Name")
        let commandLabel = makeLabel("Command")
        let cwdLabel = makeLabel("CWD (optional)")

        [nameField, commandField, cwdField].forEach { field in
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = NSFont.systemFont(ofSize: 12)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.isEditable = true
            field.isSelectable = true
            field.focusRingType = .default
            field.delegate = textDelegate
        }
        cwdField.placeholderString = "Relative to worktree root"

        addActionButton.translatesAutoresizingMaskIntoConstraints = false
        addActionButton.bezelStyle = .rounded
        addActionButton.keyEquivalent = "\r" // default / Return
        addActionButton.target = self
        addActionButton.action = #selector(addClicked)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        [nameLabel, commandLabel, cwdLabel,
         nameField, commandField, cwdField,
         addActionButton, cancelButton].forEach { content.addSubview($0) }

        // Vertical rhythm: label on its own row, field below.
        let topPad: CGFloat = 16
        let hPad: CGFloat = 18

        NSLayoutConstraint.activate([
            // Labels — leading column.
            nameLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: topPad),
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),

            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),

            commandLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            commandLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),

            commandField.topAnchor.constraint(equalTo: commandLabel.bottomAnchor, constant: 4),
            commandField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),
            commandField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),

            cwdLabel.topAnchor.constraint(equalTo: commandField.bottomAnchor, constant: 10),
            cwdLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),

            cwdField.topAnchor.constraint(equalTo: cwdLabel.bottomAnchor, constant: 4),
            cwdField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),
            cwdField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),

            // Buttons — bottom row.
            addActionButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            addActionButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),
            addActionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),

            cancelButton.centerYAnchor.constraint(equalTo: addActionButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: addActionButton.leadingAnchor, constant: -10),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return lbl
    }

    // MARK: - Validation

    fileprivate func updateAddEnabled() {
        addActionButton.isEnabled = canSubmit()
    }

    private func canSubmit() -> Bool {
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedCommand.isEmpty { return false }
        return !Self.deriveID(from: trimmedName).isEmpty
    }

    // MARK: - Actions

    @objc private func addClicked() {
        // Defensive — shouldn't fire when disabled, but guard anyway.
        guard canSubmit() else { return }

        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCWD = cwdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseID = Self.deriveID(from: trimmedName)
        let finalID = Self.dedupe(baseID: baseID, existing: existingPinnedIDs)

        let task = PinnedTask(
            id: finalID,
            name: trimmedName,
            command: trimmedCommand,
            cwd: trimmedCWD.isEmpty ? nil : trimmedCWD
        )

        // Hand off to the caller. They decide whether to dismiss (success) or
        // leave the sheet open (error surfaced in an alert).
        guard let onConfirmHandler else {
            // No handler wired — treat as a dismiss to avoid trapping the user.
            dismiss(returnCode: .OK)
            return
        }
        onConfirmHandler(task) { [weak self] in
            self?.dismiss(returnCode: .OK)
        }
    }

    @objc private func cancelClicked() {
        onCancelHandler?()
        dismiss(returnCode: .cancel)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelHandler?()
        dismiss(returnCode: .cancel)
    }

    private func dismiss(returnCode: NSApplication.ModalResponse) {
        if let parent = sheetParent {
            parent.endSheet(self, returnCode: returnCode)
        } else {
            orderOut(nil)
        }
    }

    // MARK: - Id derivation

    /// Kebab-case: lowercase, replace runs of non-[a-z0-9-] with '-',
    /// then strip leading/trailing dashes.
    static func deriveID(from name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            let c = Character(scalar)
            let isAllowed = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-"
            if isAllowed {
                out.append(c)
                lastWasDash = (c == "-")
            } else {
                if !lastWasDash {
                    out.append("-")
                    lastWasDash = true
                }
            }
        }
        // Trim leading/trailing '-'.
        while out.first == "-" { out.removeFirst() }
        while out.last == "-" { out.removeLast() }
        return out
    }

    /// Append `-2`, `-3`, ... if the base collides with an existing id.
    static func dedupe(baseID: String, existing: Set<String>) -> String {
        if !existing.contains(baseID) { return baseID }
        var n = 2
        while existing.contains("\(baseID)-\(n)") {
            n += 1
        }
        return "\(baseID)-\(n)"
    }
}

// MARK: - Text field delegate shim

private final class TextDelegate: NSObject, NSTextFieldDelegate {
    weak var owner: AddCustomTaskSheet?

    init(owner: AddCustomTaskSheet) {
        self.owner = owner
    }

    func controlTextDidChange(_ obj: Notification) {
        owner?.updateAddEnabled()
    }
}

