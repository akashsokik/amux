import Foundation

enum EditorTabLoadResult {
    case text(content: String, encoding: String.Encoding)
    case unsupported
}

class EditorTab: Identifiable {
    let id: UUID
    let filePath: String
    let isEditable: Bool
    var content: String
    var isDirty: Bool = false
    var encoding: String.Encoding
    private var savedContent: String

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    var fileExtension: String {
        URL(fileURLWithPath: filePath).pathExtension
    }

    init(
        filePath: String,
        content: String,
        encoding: String.Encoding,
        isEditable: Bool = true
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.isEditable = isEditable
        self.content = content
        self.encoding = encoding
        self.savedContent = content
    }

    init(filePath: String) throws {
        switch try Self.load(from: filePath) {
        case .text(let content, let encoding):
            self.id = UUID()
            self.filePath = filePath
            self.isEditable = true
            self.content = content
            self.encoding = encoding
            self.savedContent = content
        case .unsupported:
            self.id = UUID()
            self.filePath = filePath
            self.isEditable = false
            self.content = ""
            self.encoding = .utf8
            self.savedContent = ""
        }
    }

    init(unsupportedFileAt filePath: String) {
        self.id = UUID()
        self.filePath = filePath
        self.isEditable = false
        self.content = ""
        self.encoding = .utf8
        self.savedContent = ""
    }

    func updateContent(_ newContent: String) {
        guard isEditable else { return }
        content = newContent
        isDirty = (content != savedContent)
    }

    func save() throws {
        guard isEditable else { return }
        try content.write(toFile: filePath, atomically: true, encoding: encoding)
        savedContent = content
        isDirty = false
    }

    static func load(from filePath: String) throws -> EditorTabLoadResult {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])

        if data.contains(0) {
            return .unsupported
        }

        if let str = String(data: data, encoding: .utf8) {
            return .text(content: str, encoding: .utf8)
        }

        if let str = String(data: data, encoding: .ascii) {
            return .text(content: str, encoding: .ascii)
        }

        return .unsupported
    }
}
