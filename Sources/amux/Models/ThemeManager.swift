import AppKit
import Foundation

class ThemeManager {
    static let shared = ThemeManager()

    private(set) var current: ThemeDefinition
    let available: [ThemeDefinition] = ThemeDefinition.allBuiltIn

    private let prefsURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prefs.json")
    }()

    private init() {
        let savedID = ThemeManager.loadSavedThemeID()
        current = ThemeDefinition.allBuiltIn.first { $0.id == savedID }
            ?? .kineticMonolith
    }

    func applyTheme(_ theme: ThemeDefinition) {
        current = theme
        savePref(themeID: theme.id)
        NotificationCenter.default.post(name: Theme.didChangeNotification, object: nil)
    }

    // MARK: - Persistence

    private static func loadSavedThemeID() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        let url = dir.appendingPathComponent("prefs.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = dict["themeID"] as? String else { return nil }
        return id
    }

    private func savePref(themeID: String) {
        let dict: [String: Any] = ["themeID": themeID]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }
        try? data.write(to: prefsURL, options: .atomic)
    }
}
