import AppKit
import Darwin

class CPUSegment: StatusBarSegment {
    let id = "cpu"
    let label = "CPU Usage"
    let icon = "cpu"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 3.0

    private let valueLabel = NSTextField(labelWithString: "")
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        valueLabel.font = font
        valueLabel.textColor = Theme.quaternaryText
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        return valueLabel
    }

    func update() {
        let host = mach_host_self()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            valueLabel.stringValue = "CPU --"
            return
        }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        if let prev = previousTicks {
            let dUser = user - prev.user
            let dSystem = system - prev.system
            let dIdle = idle - prev.idle
            let dNice = nice - prev.nice
            let total = dUser + dSystem + dIdle + dNice
            if total > 0 {
                let usage = Double(dUser + dSystem + dNice) / Double(total) * 100
                valueLabel.stringValue = String(format: "CPU %.0f%%", usage)
            }
        } else {
            valueLabel.stringValue = "CPU --"
        }
        previousTicks = (user, system, idle, nice)
    }
}
