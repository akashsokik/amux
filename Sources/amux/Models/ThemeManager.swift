import AppKit
import Foundation

class ThemeManager {
    static let shared = ThemeManager()

    private(set) var current: ThemeDefinition
    private(set) var glassmorphismEnabled: Bool = false
    let available: [ThemeDefinition] = ThemeDefinition.allBuiltIn

    private let prefsURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prefs.json")
    }()

    private init() {
        let prefs = ThemeManager.loadPrefs()
        current = ThemeDefinition.allBuiltIn.first { $0.id == prefs.themeID }
            ?? .kineticMonolith
        glassmorphismEnabled = prefs.glassmorphism
    }

    func applyTheme(_ theme: ThemeDefinition) {
        current = theme
        savePrefs()
        NotificationCenter.default.post(name: Theme.didChangeNotification, object: nil)
    }

    /// Switch between dark and light variant of the current theme family.
    func toggleAppearance() {
        guard let companion = current.companion else { return }
        applyTheme(companion)
    }

    func toggleGlassmorphism() {
        glassmorphismEnabled.toggle()
        savePrefs()
        NotificationCenter.default.post(name: Theme.didChangeNotification, object: nil)
    }

    // MARK: - Persistence

    private struct SavedPrefs {
        var themeID: String?
        var glassmorphism: Bool
    }

    private static func loadPrefs() -> SavedPrefs {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux")
        let url = dir.appendingPathComponent("prefs.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SavedPrefs(themeID: nil, glassmorphism: false)
        }
        return SavedPrefs(
            themeID: dict["themeID"] as? String,
            glassmorphism: dict["glassmorphism"] as? Bool ?? false
        )
    }

    private func savePrefs() {
        let dict: [String: Any] = [
            "themeID": current.id,
            "glassmorphism": glassmorphismEnabled,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }
        try? data.write(to: prefsURL, options: .atomic)
    }
}
