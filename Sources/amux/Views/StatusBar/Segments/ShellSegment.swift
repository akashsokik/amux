import AppKit

class ShellSegment: StatusBarSegment {
    let id: String
    let label: String
    let icon: String
    let position: SegmentPosition
    let refreshInterval: TimeInterval

    private let command: String
    private let format: String?
    private let valueLabel = NSTextField(labelWithString: "")

    init(definition: CustomSegmentDefinition) {
        self.id = definition.id
        self.label = definition.label
        self.icon = definition.icon
        self.command = definition.command
        self.format = definition.format
        self.refreshInterval = definition.interval ?? 10.0
        switch definition.position {
        case "left": self.position = .left
        case "center": self.position = .center
        default: self.position = .right
        }
    }

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        valueLabel.font = font
        valueLabel.textColor = Theme.quaternaryText
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        return valueLabel
    }

    func update() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", self.command]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                // Read pipe before waiting to avoid deadlock if buffer fills
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let display: String
                if let fmt = self.format {
                    display = fmt.replacingOccurrences(of: "{}", with: output)
                } else {
                    display = output
                }
                DispatchQueue.main.async {
                    self.valueLabel.stringValue = display
                }
            } catch {
                DispatchQueue.main.async {
                    self.valueLabel.stringValue = "--"
                }
            }
        }
    }
}
