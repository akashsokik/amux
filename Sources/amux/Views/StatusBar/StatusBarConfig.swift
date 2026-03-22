import Foundation

struct CustomSegmentDefinition: Codable {
    let id: String
    let label: String
    let icon: String
    let position: String  // "left", "center", "right"
    let command: String
    let format: String?
    let interval: TimeInterval?
}

struct StatusBarConfigFile: Codable {
    var enabled: [String]
    var custom: [CustomSegmentDefinition]?
}

class StatusBarConfig {
    static let shared = StatusBarConfig()
    static let didChangeNotification = Notification.Name("StatusBarConfigDidChange")

    private let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("statusbar.json")
    }()

    private(set) var enabledIDs: Set<String> = []
    private(set) var customDefinitions: [CustomSegmentDefinition] = []

    // For command palette integration
    struct SegmentInfo {
        let id: String
        let label: String
    }
    private(set) var registeredSegments: [SegmentInfo] = []

    private init() {
        load()
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    func toggle(_ id: String) {
        if enabledIDs.contains(id) {
            enabledIDs.remove(id)
        } else {
            enabledIDs.insert(id)
        }
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func register(id: String, label: String) {
        if !registeredSegments.contains(where: { $0.id == id }) {
            registeredSegments.append(SegmentInfo(id: id, label: label))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(StatusBarConfigFile.self, from: data) else {
            return
        }
        enabledIDs = Set(config.enabled)
        customDefinitions = config.custom ?? []
    }

    private func save() {
        let config = StatusBarConfigFile(
            enabled: Array(enabledIDs).sorted(),
            custom: customDefinitions.isEmpty ? nil : customDefinitions
        )
        guard let data = try? JSONEncoder().encode(config) else { return }
        if let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? pretty.write(to: configURL)
        } else {
            try? data.write(to: configURL)
        }
    }
}
