import AppKit
import Foundation

class Project: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var rootPath: String
    let createdAt: Date
    let colorHex: String

    var color: NSColor {
        NSColor(hexString: colorHex) ?? NSColor.gray
    }

    var displayName: String {
        name.isEmpty ? URL(fileURLWithPath: rootPath).lastPathComponent : name
    }

    var rootURL: URL {
        URL(fileURLWithPath: rootPath)
    }

    init(name: String? = nil, rootPath: String, colorHex: String? = nil) {
        self.id = UUID()
        self.rootPath = rootPath
        self.name = name ?? URL(fileURLWithPath: rootPath).lastPathComponent
        self.colorHex = colorHex ?? Project.randomColorHex()
        self.createdAt = Date()
    }

    init(id: UUID, name: String, rootPath: String, createdAt: Date, colorHex: String) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.colorHex = colorHex
    }

    // MARK: - Color Palette

    static let palette: [String] = [
        "61afef", "98c379", "e5c07b", "c678dd",
        "56b6c2", "e06c75", "d19a66", "7ec8e3",
        "c3a6ff", "f4a261", "a8d8b9", "ff6b8a",
        "ffd93d", "6bcb77", "4d96ff", "be5046",
    ]

    static func randomColorHex() -> String {
        palette.randomElement()!
    }

    // MARK: - Codable Support

    struct CodableRepresentation: Codable {
        let id: UUID
        let name: String
        let rootPath: String
        let createdAt: Date
        let colorHex: String

        init(from project: Project) {
            self.id = project.id
            self.name = project.name
            self.rootPath = project.rootPath
            self.createdAt = project.createdAt
            self.colorHex = project.colorHex
        }

        func toProject() -> Project {
            Project(
                id: id,
                name: name,
                rootPath: rootPath,
                createdAt: createdAt,
                colorHex: colorHex
            )
        }
    }
}
