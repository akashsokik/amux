import Foundation

// MARK: - Enums

enum SplitDirection: Codable, Equatable {
    case vertical   // left | right
    case horizontal // top / bottom
}

enum FocusDirection {
    case up, down, left, right
    case next, previous
}

enum SplitPosition {
    case first  // left or top
    case second // right or bottom
}

// MARK: - PaneInfo

struct PaneInfo {
    let id: UUID
    var rect: CGRect // normalized 0-1 rect within the session view
}

// MARK: - SplitNode

indirect enum SplitNode: Identifiable, Codable {
    case leaf(id: UUID)
    case split(SplitContainer)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, id, container
    }

    private enum NodeType: String, Codable {
        case leaf, split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .leaf:
            let id = try container.decode(UUID.self, forKey: .id)
            self = .leaf(id: id)
        case .split:
            let splitContainer = try container.decode(SplitContainer.self, forKey: .container)
            self = .split(splitContainer)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(id, forKey: .id)
        case .split(let splitContainer):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(splitContainer, forKey: .container)
        }
    }

    var id: UUID {
        switch self {
        case .leaf(let id):
            return id
        case .split(let container):
            return container.id
        }
    }

    struct SplitContainer: Identifiable, Codable {
        let id: UUID
        var direction: SplitDirection
        var ratio: Double
        var first: SplitNode  // left or top
        var second: SplitNode // right or bottom

        init(
            id: UUID = UUID(),
            direction: SplitDirection,
            ratio: Double = 0.5,
            first: SplitNode,
            second: SplitNode
        ) {
            self.id = id
            self.direction = direction
            self.ratio = ratio
            self.first = first
            self.second = second
        }
    }

    // MARK: - Queries

    /// Collect all leaf pane IDs in order (left-to-right, top-to-bottom).
    func allPaneIDs() -> [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(let container):
            return container.first.allPaneIDs() + container.second.allPaneIDs()
        }
    }

    /// Determine whether this subtree contains a leaf with the given ID.
    func contains(paneID: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneID
        case .split(let container):
            return container.first.contains(paneID: paneID)
                || container.second.contains(paneID: paneID)
        }
    }

    /// Collect all PaneInfo values with normalized rects computed from the given bounding rect.
    func paneInfos(in rect: CGRect) -> [PaneInfo] {
        switch self {
        case .leaf(let id):
            return [PaneInfo(id: id, rect: rect)]
        case .split(let container):
            let (firstRect, secondRect) = SplitNode.childRects(
                for: container, in: rect
            )
            return container.first.paneInfos(in: firstRect)
                + container.second.paneInfos(in: secondRect)
        }
    }

    /// Compute the sub-rects for the two children of a SplitContainer.
    static func childRects(
        for container: SplitContainer,
        in rect: CGRect
    ) -> (CGRect, CGRect) {
        let ratio = CGFloat(container.ratio)
        switch container.direction {
        case .vertical:
            let firstWidth = rect.width * ratio
            let firstRect = CGRect(
                x: rect.minX, y: rect.minY,
                width: firstWidth, height: rect.height
            )
            let secondRect = CGRect(
                x: rect.minX + firstWidth, y: rect.minY,
                width: rect.width - firstWidth, height: rect.height
            )
            return (firstRect, secondRect)
        case .horizontal:
            let firstHeight = rect.height * ratio
            let firstRect = CGRect(
                x: rect.minX, y: rect.minY,
                width: rect.width, height: firstHeight
            )
            let secondRect = CGRect(
                x: rect.minX, y: rect.minY + firstHeight,
                width: rect.width, height: rect.height - firstHeight
            )
            return (firstRect, secondRect)
        }
    }

    // MARK: - Mutations (return new trees -- value semantics)

    /// Split the leaf with the given paneID, creating a new split container.
    /// Returns the updated subtree and the new pane's ID.
    func inserting(
        splitting paneID: UUID,
        direction: SplitDirection
    ) -> (SplitNode, UUID)? {
        switch self {
        case .leaf(let id) where id == paneID:
            let newID = UUID()
            let container = SplitContainer(
                direction: direction,
                ratio: 0.5,
                first: .leaf(id: id),
                second: .leaf(id: newID)
            )
            return (.split(container), newID)

        case .leaf:
            return nil

        case .split(var container):
            if let (newFirst, newID) = container.first.inserting(
                splitting: paneID, direction: direction
            ) {
                container.first = newFirst
                return (.split(container), newID)
            }
            if let (newSecond, newID) = container.second.inserting(
                splitting: paneID, direction: direction
            ) {
                container.second = newSecond
                return (.split(container), newID)
            }
            return nil
        }
    }

    /// Split the leaf with the given paneID, placing the new leaf at the given position.
    func inserting(
        splitting paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (SplitNode, UUID)? {
        switch self {
        case .leaf(let id) where id == paneID:
            let newID = UUID()
            let container: SplitContainer
            switch position {
            case .first:
                container = SplitContainer(
                    direction: direction,
                    ratio: 0.5,
                    first: .leaf(id: newID),
                    second: .leaf(id: id)
                )
            case .second:
                container = SplitContainer(
                    direction: direction,
                    ratio: 0.5,
                    first: .leaf(id: id),
                    second: .leaf(id: newID)
                )
            }
            return (.split(container), newID)

        case .leaf:
            return nil

        case .split(var container):
            if let (newFirst, newID) = container.first.inserting(
                splitting: paneID, direction: direction, position: position
            ) {
                container.first = newFirst
                return (.split(container), newID)
            }
            if let (newSecond, newID) = container.second.inserting(
                splitting: paneID, direction: direction, position: position
            ) {
                container.second = newSecond
                return (.split(container), newID)
            }
            return nil
        }
    }

    /// Remove the leaf with the given paneID.
    /// Returns the updated subtree, or nil if this entire subtree collapses.
    func removing(paneID: UUID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            // If this is the target leaf, signal removal by returning nil.
            return id == paneID ? nil : self

        case .split(var container):
            let firstContains = container.first.contains(paneID: paneID)
            let secondContains = container.second.contains(paneID: paneID)

            if firstContains {
                if let newFirst = container.first.removing(paneID: paneID) {
                    container.first = newFirst
                    return .split(container)
                } else {
                    // First child was removed entirely -- promote second.
                    return container.second
                }
            } else if secondContains {
                if let newSecond = container.second.removing(paneID: paneID) {
                    container.second = newSecond
                    return .split(container)
                } else {
                    // Second child was removed entirely -- promote first.
                    return container.first
                }
            }
            return self
        }
    }

    /// Adjust the ratio of the split that directly contains the given paneID.
    mutating func resize(
        paneID: UUID,
        direction: SplitDirection,
        delta: CGFloat
    ) {
        switch self {
        case .leaf:
            return
        case .split(var container):
            // Check if this container directly holds the target pane
            // and matches the requested direction.
            let firstHas = container.first.directlyContainsLeaf(paneID)
            let secondHas = container.second.directlyContainsLeaf(paneID)

            if container.direction == direction && (firstHas || secondHas) {
                let newRatio: Double
                if firstHas {
                    newRatio = container.ratio + Double(delta)
                } else {
                    newRatio = container.ratio - Double(delta)
                }
                container.ratio = min(0.9, max(0.1, newRatio))
                self = .split(container)
                return
            }

            // Otherwise recurse into whichever child contains the pane.
            if container.first.contains(paneID: paneID) {
                container.first.resize(
                    paneID: paneID, direction: direction, delta: delta
                )
            } else if container.second.contains(paneID: paneID) {
                container.second.resize(
                    paneID: paneID, direction: direction, delta: delta
                )
            }
            self = .split(container)
        }
    }

    /// Returns true if this node is a leaf with the given ID, or is a split
    /// whose immediate child is the target leaf.
    private func directlyContainsLeaf(_ paneID: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneID
        case .split:
            return false
        }
    }

    /// Set all split ratios to 0.5 recursively.
    mutating func equalize() {
        switch self {
        case .leaf:
            return
        case .split(var container):
            container.ratio = 0.5
            container.first.equalize()
            container.second.equalize()
            self = .split(container)
        }
    }

    /// Swap two leaf panes by exchanging their IDs.
    mutating func swapPanes(a: UUID, b: UUID) {
        switch self {
        case .leaf(let id):
            if id == a {
                self = .leaf(id: b)
            } else if id == b {
                self = .leaf(id: a)
            }
        case .split(var container):
            container.first.swapPanes(a: a, b: b)
            container.second.swapPanes(a: a, b: b)
            self = .split(container)
        }
    }
}

// MARK: - SplitTree

class SplitTree: ObservableObject {
    @Published var root: SplitNode?
    @Published var zoomedPaneID: UUID?

    /// Initialize with a single pane.
    init() {
        let initialID = UUID()
        self.root = .leaf(id: initialID)
    }

    /// Initialize empty (for testing or special cases).
    init(root: SplitNode?) {
        self.root = root
    }

    // MARK: - Insert

    /// Split an existing pane, returns the new tree state and the new pane's ID.
    @discardableResult
    func insert(
        splitting paneID: UUID,
        direction: SplitDirection
    ) -> (SplitTree, UUID)? {
        guard let currentRoot = root else { return nil }
        guard let (newRoot, newID) = currentRoot.inserting(
            splitting: paneID, direction: direction
        ) else {
            return nil
        }
        root = newRoot
        // If we were zoomed, exit zoom since the layout changed.
        zoomedPaneID = nil
        return (self, newID)
    }

    /// Split an existing pane with positional control, returns the new tree state and the new pane's ID.
    @discardableResult
    func insert(
        splitting paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (SplitTree, UUID)? {
        guard let currentRoot = root else { return nil }
        guard let (newRoot, newID) = currentRoot.inserting(
            splitting: paneID, direction: direction, position: position
        ) else {
            return nil
        }
        root = newRoot
        zoomedPaneID = nil
        return (self, newID)
    }

    // MARK: - Remove

    /// Remove a pane, promoting its sibling. Returns nil if the last pane was removed.
    @discardableResult
    func remove(paneID: UUID) -> SplitTree? {
        guard let currentRoot = root else { return nil }

        // If the root is a single leaf and it matches, tree becomes empty.
        if case .leaf(let id) = currentRoot, id == paneID {
            root = nil
            zoomedPaneID = nil
            return nil
        }

        if let newRoot = currentRoot.removing(paneID: paneID) {
            root = newRoot
            if zoomedPaneID == paneID {
                zoomedPaneID = nil
            }
            return self
        }
        return self
    }

    // MARK: - Resize

    func resize(paneID: UUID, direction: SplitDirection, delta: CGFloat) {
        guard root != nil else { return }
        root?.resize(paneID: paneID, direction: direction, delta: delta)
    }

    // MARK: - Find Pane

    func findPane(id: UUID) -> PaneInfo? {
        guard let currentRoot = root else { return nil }
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let allInfos = currentRoot.paneInfos(in: unitRect)
        return allInfos.first(where: { $0.id == id })
    }

    // MARK: - All Pane IDs

    func allPaneIDs() -> [UUID] {
        return root?.allPaneIDs() ?? []
    }

    // MARK: - Focus Target

    /// Navigate to an adjacent pane using spatial reasoning.
    func focusTarget(from paneID: UUID, direction: FocusDirection) -> UUID? {
        guard let currentRoot = root else { return nil }
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let allInfos = currentRoot.paneInfos(in: unitRect)

        guard let sourceInfo = allInfos.first(where: { $0.id == paneID }) else {
            return nil
        }

        switch direction {
        case .next:
            return focusNext(from: paneID)
        case .previous:
            return focusPrevious(from: paneID)
        case .left, .right, .up, .down:
            return focusSpatial(
                from: sourceInfo, direction: direction, candidates: allInfos
            )
        }
    }

    /// Cycle to the next pane in tree order.
    private func focusNext(from paneID: UUID) -> UUID? {
        let ids = allPaneIDs()
        guard let index = ids.firstIndex(of: paneID) else { return nil }
        let nextIndex = (index + 1) % ids.count
        return ids[nextIndex]
    }

    /// Cycle to the previous pane in tree order.
    private func focusPrevious(from paneID: UUID) -> UUID? {
        let ids = allPaneIDs()
        guard let index = ids.firstIndex(of: paneID) else { return nil }
        let prevIndex = (index - 1 + ids.count) % ids.count
        return ids[prevIndex]
    }

    /// Find the best candidate pane in the given spatial direction.
    private func focusSpatial(
        from source: PaneInfo,
        direction: FocusDirection,
        candidates: [PaneInfo]
    ) -> UUID? {
        let sourceCenter = CGPoint(
            x: source.rect.midX, y: source.rect.midY
        )

        var bestCandidate: PaneInfo?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for candidate in candidates {
            guard candidate.id != source.id else { continue }
            let candidateCenter = CGPoint(
                x: candidate.rect.midX, y: candidate.rect.midY
            )

            let isInDirection: Bool
            switch direction {
            case .left:
                isInDirection = candidateCenter.x < sourceCenter.x - 0.001
            case .right:
                isInDirection = candidateCenter.x > sourceCenter.x + 0.001
            case .up:
                isInDirection = candidateCenter.y < sourceCenter.y - 0.001
            case .down:
                isInDirection = candidateCenter.y > sourceCenter.y + 0.001
            default:
                isInDirection = false
            }

            guard isInDirection else { continue }

            // Compute distance, weighting the primary axis more heavily.
            let dx = candidateCenter.x - sourceCenter.x
            let dy = candidateCenter.y - sourceCenter.y
            let distance: CGFloat

            switch direction {
            case .left, .right:
                // Primary axis is horizontal; penalize vertical offset.
                distance = abs(dx) + abs(dy) * 2.0
            case .up, .down:
                // Primary axis is vertical; penalize horizontal offset.
                distance = abs(dy) + abs(dx) * 2.0
            default:
                distance = abs(dx) + abs(dy)
            }

            if distance < bestDistance {
                bestDistance = distance
                bestCandidate = candidate
            }
        }

        return bestCandidate?.id
    }

    // MARK: - Equalize

    func equalize() {
        root?.equalize()
    }

    // MARK: - Swap Panes

    func swapPanes(a: UUID, b: UUID) {
        root?.swapPanes(a: a, b: b)
    }

    // MARK: - Codable Support

    struct CodableRepresentation: Codable {
        var root: SplitNode?

        init(from splitTree: SplitTree) {
            self.root = splitTree.root
        }

        func toSplitTree() -> SplitTree {
            return SplitTree(root: root)
        }
    }
}
