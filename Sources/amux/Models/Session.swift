import Foundation
import AppKit

enum PaneStatus {
    case idle
    case running
    case success
    case error
}

class Session: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var splitTree: SplitTree
    @Published var focusedPaneID: UUID?
    @Published var paneStatus: PaneStatus
    let createdAt: Date
    let colorHex: String

    var statusColor: NSColor {
        switch paneStatus {
        case .idle:    return Theme.quaternaryText
        case .running: return Theme.primary
        case .success: return NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)
        case .error:   return NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0)
        }
    }

    init(name: String, colorHex: String? = nil) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex ?? Session.randomColorHex()
        let tree = SplitTree()
        self.splitTree = tree
        self.paneStatus = .idle
        self.createdAt = Date()
        self.focusedPaneID = tree.root?.id
    }

    /// Initialize from persisted state.
    init(id: UUID, name: String, splitTree: SplitTree, focusedPaneID: UUID?, createdAt: Date, colorHex: String) {
        self.id = id
        self.name = name
        self.splitTree = splitTree
        self.focusedPaneID = focusedPaneID
        self.paneStatus = .idle
        self.createdAt = createdAt
        self.colorHex = colorHex
    }

    // MARK: - Color

    static let palette: [String] = [
        "e06c75", "e5c07b", "98c379", "56b6c2",
        "61afef", "c678dd", "d19a66", "be5046",
        "7ec8e3", "c3a6ff", "f4a261", "a8d8b9",
        "ff6b8a", "ffd93d", "6bcb77", "4d96ff",
    ]

    static func randomColorHex() -> String {
        palette.randomElement()!
    }

    var color: NSColor {
        NSColor(hexString: colorHex) ?? NSColor.gray
    }

    // MARK: - Codable Support

    struct CodableRepresentation: Codable {
        let id: UUID
        let name: String
        let splitTree: SplitTree.CodableRepresentation
        let focusedPaneID: UUID?
        let createdAt: Date
        let colorHex: String?

        init(from session: Session) {
            self.id = session.id
            self.name = session.name
            self.splitTree = SplitTree.CodableRepresentation(from: session.splitTree)
            self.focusedPaneID = session.focusedPaneID
            self.createdAt = session.createdAt
            self.colorHex = session.colorHex
        }

        func toSession() -> Session {
            return Session(
                id: id,
                name: name,
                splitTree: splitTree.toSplitTree(),
                focusedPaneID: focusedPaneID,
                createdAt: createdAt,
                colorHex: colorHex ?? Session.randomColorHex()
            )
        }
    }

    // MARK: - Split the focused pane

    /// Split the currently focused pane in the given direction.
    /// Returns the new pane's ID, or nil if no pane is focused.
    @discardableResult
    func splitFocusedPane(direction: SplitDirection) -> UUID? {
        guard let focusedID = focusedPaneID else { return nil }
        guard let (_, newID) = splitTree.insert(
            splitting: focusedID, direction: direction
        ) else {
            return nil
        }
        // Move focus to the newly created pane.
        focusedPaneID = newID
        return newID
    }

    // MARK: - Close the focused pane

    /// Close the currently focused pane.
    /// Returns false if the session is now empty (no panes remaining).
    @discardableResult
    func closeFocusedPane() -> Bool {
        guard let focusedID = focusedPaneID else { return false }

        // Before removing, determine what to focus next.
        let allIDs = splitTree.allPaneIDs()
        let nextFocusID: UUID?

        if allIDs.count <= 1 {
            // This is the last pane; session will be empty.
            nextFocusID = nil
        } else {
            // Try to focus the next pane, falling back to previous.
            nextFocusID = splitTree.focusTarget(from: focusedID, direction: .next)
                .flatMap({ $0 == focusedID ? nil : $0 })
                ?? allIDs.first(where: { $0 != focusedID })
        }

        let result = splitTree.remove(paneID: focusedID)

        if result == nil {
            // Tree is now empty.
            focusedPaneID = nil
            return false
        }

        focusedPaneID = nextFocusID
        return true
    }

    // MARK: - Navigate focus

    func moveFocus(_ direction: FocusDirection) {
        guard let focusedID = focusedPaneID else {
            // If nothing is focused, focus the first pane.
            focusedPaneID = splitTree.allPaneIDs().first
            return
        }
        if let target = splitTree.focusTarget(
            from: focusedID, direction: direction
        ) {
            focusedPaneID = target
        }
    }

    // MARK: - Toggle zoom

    func toggleZoom() {
        guard focusedPaneID != nil else { return }
        if splitTree.zoomedPaneID != nil {
            splitTree.zoomedPaneID = nil
        } else {
            splitTree.zoomedPaneID = focusedPaneID
        }
    }

    // MARK: - Resize focused pane

    func resizeFocusedPane(direction: SplitDirection, delta: CGFloat) {
        guard let focusedID = focusedPaneID else { return }
        splitTree.resize(
            paneID: focusedID, direction: direction, delta: delta
        )
    }
}
