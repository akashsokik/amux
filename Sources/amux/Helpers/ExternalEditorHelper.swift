import AppKit

struct EditorInfo {
    let name: String
    let bundleID: String
}

enum ExternalEditorHelper {
    private static let defaultsKey = "defaultExternalEditorBundleID"

    /// Known GUI editors — detection order when no default is set.
    static let knownEditors: [EditorInfo] = [
        EditorInfo(name: "VS Code", bundleID: "com.microsoft.VSCode"),
        EditorInfo(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        EditorInfo(name: "Zed", bundleID: "dev.zed.Zed"),
        EditorInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        EditorInfo(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        EditorInfo(name: "Nova", bundleID: "com.panic.Nova"),
        EditorInfo(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        EditorInfo(name: "CotEditor", bundleID: "com.coteditor.CotEditor"),
        EditorInfo(name: "TextMate", bundleID: "com.macromates.TextMate"),
        EditorInfo(name: "Fleet", bundleID: "fleet.app"),
        EditorInfo(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        EditorInfo(name: "PyCharm", bundleID: "com.jetbrains.pycharm"),
        EditorInfo(name: "WebStorm", bundleID: "com.jetbrains.WebStorm"),
        EditorInfo(name: "Android Studio", bundleID: "com.google.android.studio"),
        EditorInfo(name: "Emacs", bundleID: "org.gnu.Emacs"),
    ]

    /// Returns only the editors that are installed on this machine.
    static func installedEditors() -> [EditorInfo] {
        knownEditors.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    /// The user's chosen default editor, falling back to the first installed one.
    static func defaultEditor() -> EditorInfo? {
        if let savedID = UserDefaults.standard.string(forKey: defaultsKey),
           let editor = knownEditors.first(where: { $0.bundleID == savedID }),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: savedID) != nil {
            return editor
        }
        return installedEditors().first
    }

    /// Persist the user's preferred editor.
    static func setDefaultEditor(_ bundleID: String) {
        UserDefaults.standard.set(bundleID, forKey: defaultsKey)
    }

    /// App icon for an editor (scaled to menu size).
    static func appIcon(for bundleID: String, size: CGFloat = 16) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    /// Opens a file in a specific editor by bundle ID.
    static func openIn(filePath: String, bundleID: String) {
        let url = URL(fileURLWithPath: filePath)

        if let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a file in the user's default editor.
    static func openInEditor(filePath: String) {
        if let editor = defaultEditor() {
            openIn(filePath: filePath, bundleID: editor.bundleID)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
        }
    }

    /// Short label for the button.
    static func editorButtonLabel() -> String {
        if let editor = defaultEditor() {
            return editor.name
        }
        return "Open"
    }
}
