import AppKit
import Foundation

enum PaneLayoutPreset: String, CaseIterable {
    case threeVerticalPanes
    case threeHorizontalPanes
    case fourEqualPanes

    var paneCount: Int {
        switch self {
        case .threeVerticalPanes, .threeHorizontalPanes:
            return 3
        case .fourEqualPanes:
            return 4
        }
    }

    var menuTitle: String {
        switch self {
        case .threeVerticalPanes:
            return "Layout: 3 Vertical Panes"
        case .threeHorizontalPanes:
            return "Layout: 3 Horizontal Panes"
        case .fourEqualPanes:
            return "Layout: 4 Equal Panes"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .threeVerticalPanes:
            return "Cmd+Opt+V"
        case .threeHorizontalPanes:
            return "Cmd+Opt+H"
        case .fourEqualPanes:
            return "Cmd+Opt+G"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .threeVerticalPanes:
            return "v"
        case .threeHorizontalPanes:
            return "h"
        case .fourEqualPanes:
            return "g"
        }
    }

    var modifierMask: NSEvent.ModifierFlags {
        [.command, .option]
    }

    var icon: String {
        switch self {
        case .threeVerticalPanes:
            return "rectangle.split.1x2"
        case .threeHorizontalPanes:
            return "rectangle.split.2x1"
        case .fourEqualPanes:
            return "square.grid.2x2"
        }
    }

    func makeRoot(paneIDs: [UUID]) -> SplitNode {
        precondition(paneIDs.count == paneCount)

        switch self {
        case .threeVerticalPanes:
            return makeEqualStripeTree(direction: .vertical, paneIDs: paneIDs[...])
        case .threeHorizontalPanes:
            return makeEqualStripeTree(direction: .horizontal, paneIDs: paneIDs[...])
        case .fourEqualPanes:
            let leftColumn = makeEqualStripeTree(direction: .horizontal, paneIDs: paneIDs.prefix(2))
            let rightColumn = makeEqualStripeTree(
                direction: .horizontal, paneIDs: paneIDs.suffix(2))
            return .split(
                SplitNode.SplitContainer(
                    direction: .vertical,
                    ratio: 0.5,
                    first: leftColumn,
                    second: rightColumn
                )
            )
        }
    }

    private func makeEqualStripeTree(
        direction: SplitDirection,
        paneIDs: ArraySlice<UUID>
    ) -> SplitNode {
        guard let firstPaneID = paneIDs.first else {
            preconditionFailure("Pane layout presets require at least one pane ID")
        }

        if paneIDs.count == 1 {
            return .leaf(id: firstPaneID)
        }

        return .split(
            SplitNode.SplitContainer(
                direction: direction,
                ratio: 1.0 / Double(paneIDs.count),
                first: .leaf(id: firstPaneID),
                second: makeEqualStripeTree(direction: direction, paneIDs: paneIDs.dropFirst())
            )
        )
    }
}

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
        case .idle: return Theme.quaternaryText
        case .running: return Theme.primary
        case .success: return NSColor(srgbRed: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)
        case .error: return NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1.0)
        }
    }

    var projectID: UUID?

    init(name: String, colorHex: String? = nil) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex ?? Session.randomColorHex()
        let tree = SplitTree()
        self.splitTree = tree
        self.paneStatus = .idle
        self.createdAt = Date()
        self.focusedPaneID = tree.root?.id
        self.projectID = nil
    }

    /// Convenience init that tags the session to a project.
    convenience init(name: String, projectID: UUID?, colorHex: String? = nil) {
        self.init(name: name, colorHex: colorHex)
        self.projectID = projectID
    }

    /// Initialize from persisted state.
    init(
        id: UUID, name: String, splitTree: SplitTree, focusedPaneID: UUID?, createdAt: Date,
        colorHex: String, projectID: UUID?
    ) {
        self.id = id
        self.name = name
        self.splitTree = splitTree
        self.focusedPaneID = focusedPaneID
        self.paneStatus = .idle
        self.createdAt = createdAt
        self.colorHex = colorHex
        self.projectID = projectID
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
        let projectID: UUID?

        init(from session: Session) {
            self.id = session.id
            self.name = session.name
            self.splitTree = SplitTree.CodableRepresentation(from: session.splitTree)
            self.focusedPaneID = session.focusedPaneID
            self.createdAt = session.createdAt
            self.colorHex = session.colorHex
            self.projectID = session.projectID
        }

        func toSession() -> Session {
            return Session(
                id: id,
                name: name,
                splitTree: splitTree.toSplitTree(),
                focusedPaneID: focusedPaneID,
                createdAt: createdAt,
                colorHex: colorHex ?? Session.randomColorHex(),
                projectID: projectID
            )
        }
    }

    // MARK: - Split the focused pane

    /// Split the currently focused pane in the given direction.
    /// Returns the new pane's ID, or nil if no pane is focused.
    @discardableResult
    func splitFocusedPane(direction: SplitDirection) -> UUID? {
        guard let focusedID = focusedPaneID else { return nil }
        guard
            let (_, newID) = splitTree.insert(
                splitting: focusedID, direction: direction
            )
        else {
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
            nextFocusID =
                splitTree.focusTarget(from: focusedID, direction: .next)
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

    // MARK: - Layout presets

    @discardableResult
    func applyLayoutPreset(_ preset: PaneLayoutPreset) -> Bool {
        let existingPaneIDs = splitTree.allPaneIDs()
        guard !existingPaneIDs.isEmpty else { return false }
        guard existingPaneIDs.count <= preset.paneCount else { return false }

        let missingPaneCount = preset.paneCount - existingPaneIDs.count
        let paneIDs = existingPaneIDs + (0..<missingPaneCount).map { _ in UUID() }

        splitTree.root = preset.makeRoot(paneIDs: paneIDs)
        splitTree.zoomedPaneID = nil

        if let focusedPaneID, paneIDs.contains(focusedPaneID) {
            self.focusedPaneID = focusedPaneID
        } else {
            focusedPaneID = paneIDs.first
        }

        return true
    }
}
