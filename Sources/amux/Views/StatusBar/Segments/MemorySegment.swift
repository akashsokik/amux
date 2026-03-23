import AppKit
import Darwin

class MemorySegment: StatusBarSegment {
    let id = "memory"
    let label = "Memory Usage"
    let icon = "memorychip"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 5.0

    private let valueLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let hostPort = mach_host_self()

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        iconView.image = NSImage(
            systemSymbolName: "memorychip",
            accessibilityDescription: "Memory"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = dim
        iconView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        valueLabel.font = font
        valueLabel.textColor = dim
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false

        iconView.alphaValue = 0.5

        let stack = HoverableSegmentStack(views: [iconView, valueLabel])
        stack.segmentIcon = iconView
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        return stack
    }

    func update() {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            valueLabel.stringValue = "--"
            return
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedGB = Double(used) / 1_073_741_824
        let totalGB = Double(totalBytes) / 1_073_741_824
        valueLabel.stringValue = String(format: "%.1f/%.0fG", usedGB, totalGB)
    }
}
