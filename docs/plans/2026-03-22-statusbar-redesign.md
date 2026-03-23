# Status Bar Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the hardcoded status bar with a pluggable segment system where every item is toggleable via command palette and user-extensible via config file.

**Architecture:** A `StatusBarSegment` protocol defines the contract. Built-in segments (process, cwd, git, cpu, memory, battery, pane count, uptime, exit code) and user-defined shell segments all conform to it. A `StatusBarConfig` singleton manages persistence via `~/.config/amux/statusbar.json`. `PaneStatusBar` renders enabled segments into three stack views (left/center/right).

**Tech Stack:** Swift, AppKit, Mach APIs (host_statistics), IOKit (battery), NSStackView

---

### Task 1: StatusBarSegment Protocol and SegmentPosition Enum

**Files:**
- Create: `Sources/amux/Views/StatusBar/StatusBarSegment.swift`

**Step 1: Create the protocol file**

```swift
import AppKit

enum SegmentPosition {
    case left, center, right
}

protocol StatusBarSegment: AnyObject {
    var id: String { get }
    var label: String { get }
    var icon: String { get }
    var position: SegmentPosition { get }
    var refreshInterval: TimeInterval { get }
    func render() -> NSView
    func update()
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Views/StatusBar/StatusBarSegment.swift
git commit -m "feat: add StatusBarSegment protocol"
```

---

### Task 2: StatusBarConfig (persistence layer)

**Files:**
- Create: `Sources/amux/Views/StatusBar/StatusBarConfig.swift`

**Step 1: Create the config manager**

```swift
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
        // Pretty print for human readability
        if let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? pretty.write(to: configURL)
        } else {
            try? data.write(to: configURL)
        }
    }
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Views/StatusBar/StatusBarConfig.swift
git commit -m "feat: add StatusBarConfig for persistence"
```

---

### Task 3: Built-in Segments -- Process, CWD, Git

These replace the existing hardcoded elements from `PaneStatusBar`.

**Files:**
- Create: `Sources/amux/Views/StatusBar/Segments/ProcessSegment.swift`
- Create: `Sources/amux/Views/StatusBar/Segments/CWDSegment.swift`
- Create: `Sources/amux/Views/StatusBar/Segments/GitSegment.swift`

**Step 1: ProcessSegment**

```swift
import AppKit

class ProcessSegment: StatusBarSegment {
    let id = "process"
    let label = "Process"
    let icon = "terminal"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 3.0

    private let nameLabel = NSTextField(labelWithString: "")
    var shellPid: pid_t?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        nameLabel.font = font
        nameLabel.textColor = Theme.quaternaryText
        nameLabel.backgroundColor = .clear
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80).isActive = true
        return nameLabel
    }

    func update() {
        guard let pid = shellPid else {
            nameLabel.stringValue = "shell"
            return
        }
        let shellName = ProcessHelper.name(of: pid) ?? "shell"
        if let fgPid = ProcessHelper.foregroundChild(of: pid),
           let fgName = ProcessHelper.name(of: fgPid) {
            nameLabel.stringValue = fgName
        } else {
            nameLabel.stringValue = shellName
        }
    }
}
```

**Step 2: CWDSegment**

```swift
import AppKit

class CWDSegment: StatusBarSegment {
    let id = "cwd"
    let label = "Working Directory"
    let icon = "folder"
    let position = SegmentPosition.center
    let refreshInterval: TimeInterval = 3.0

    private let pathButton = NSButton()
    private var lastCwd: String?
    var shellPid: pid_t?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathButton.title = ""
        pathButton.font = font
        pathButton.contentTintColor = Theme.tertiaryText
        pathButton.isBordered = false
        pathButton.bezelStyle = .accessoryBarAction
        pathButton.setButtonType(.momentaryChange)
        pathButton.target = self
        pathButton.action = #selector(copyPath)
        pathButton.alignment = .center
        if let cell = pathButton.cell as? NSButtonCell {
            cell.highlightsBy = .contentsCellMask
        }
        return pathButton
    }

    func update() {
        guard let pid = shellPid else {
            pathButton.title = "~"
            lastCwd = nil
            return
        }
        if let cwd = ProcessHelper.cwd(of: pid) {
            let home = NSHomeDirectory()
            pathButton.title = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            lastCwd = cwd
        } else {
            pathButton.title = "~"
            lastCwd = nil
        }
    }

    /// Returns the current working directory (used by GitSegment).
    var currentCwd: String? { lastCwd }

    @objc private func copyPath() {
        guard let cwd = lastCwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
        let original = pathButton.contentTintColor
        pathButton.contentTintColor = Theme.primaryText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pathButton.contentTintColor = original
        }
    }
}
```

**Step 3: GitSegment**

```swift
import AppKit

class GitSegment: StatusBarSegment {
    let id = "git"
    let label = "Git Branch"
    let icon = "arrow.triangle.branch"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 3.0

    private let container = NSStackView()
    private let dirtyDot = NSView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")

    /// Reference to CWDSegment to get current path.
    weak var cwdSegment: CWDSegment?

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let dim = Theme.quaternaryText

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 2.5
        dirtyDot.layer?.backgroundColor = NSColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1.0).cgColor
        dirtyDot.isHidden = true
        dirtyDot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dirtyDot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        branchIcon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Branch"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        branchIcon.contentTintColor = dim
        branchIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        branchIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        branchLabel.font = font
        branchLabel.textColor = dim
        branchLabel.backgroundColor = .clear
        branchLabel.isBezeled = false
        branchLabel.isEditable = false
        branchLabel.isSelectable = false
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100).isActive = true

        container.orientation = .horizontal
        container.spacing = 4
        container.alignment = .centerY
        container.addArrangedSubview(dirtyDot)
        container.addArrangedSubview(branchIcon)
        container.addArrangedSubview(branchLabel)

        return container
    }

    func update() {
        guard let cwd = cwdSegment?.currentCwd,
              let branch = ProcessHelper.gitBranch(at: cwd) else {
            container.isHidden = true
            return
        }
        container.isHidden = false
        branchLabel.stringValue = branch
        dirtyDot.isHidden = !ProcessHelper.gitIsDirty(at: cwd)
    }
}
```

**Step 4: Commit**

```bash
git add Sources/amux/Views/StatusBar/Segments/
git commit -m "feat: add Process, CWD, and Git segments"
```

---

### Task 4: System Segments -- CPU, Memory, Battery

**Files:**
- Create: `Sources/amux/Views/StatusBar/Segments/CPUSegment.swift`
- Create: `Sources/amux/Views/StatusBar/Segments/MemorySegment.swift`
- Create: `Sources/amux/Views/StatusBar/Segments/BatterySegment.swift`

**Step 1: CPUSegment**

Uses `host_statistics` Mach API (no subprocess).

```swift
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
        var count = mach_msg_type_number_t(HOST_CPU_LOAD_INFO_COUNT)
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
```

**Step 2: MemorySegment**

```swift
import AppKit
import Darwin

class MemorySegment: StatusBarSegment {
    let id = "memory"
    let label = "Memory Usage"
    let icon = "memorychip"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 5.0

    private let valueLabel = NSTextField(labelWithString: "")

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
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            valueLabel.stringValue = "MEM --"
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
        valueLabel.stringValue = String(format: "MEM %.1f/%.0fG", usedGB, totalGB)
    }
}
```

**Step 3: BatterySegment**

```swift
import AppKit
import IOKit.ps

class BatterySegment: StatusBarSegment {
    let id = "battery"
    let label = "Battery"
    let icon = "battery.100"
    let position = SegmentPosition.right
    let refreshInterval: TimeInterval = 30.0

    private let valueLabel = NSTextField(labelWithString: "")

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
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any],
              let capacity = desc[kIOPSCurrentCapacityKey] as? Int else {
            valueLabel.stringValue = "BAT --"
            return
        }
        let charging = (desc[kIOPSIsChargingKey] as? Bool) == true
        valueLabel.stringValue = "BAT \(capacity)%\(charging ? "+" : "")"
    }
}
```

**Step 4: Commit**

```bash
git add Sources/amux/Views/StatusBar/Segments/
git commit -m "feat: add CPU, Memory, and Battery segments"
```

---

### Task 5: Session Segments -- Pane Count, Uptime, Exit Code

**Files:**
- Create: `Sources/amux/Views/StatusBar/Segments/PaneCountSegment.swift`
- Create: `Sources/amux/Views/StatusBar/Segments/UptimeSegment.swift`
- Create: `Sources/amux/Views/StatusBar/Segments/ExitCodeSegment.swift`

**Step 1: PaneCountSegment**

```swift
import AppKit

class PaneCountSegment: StatusBarSegment {
    let id = "pane-count"
    let label = "Pane Count"
    let icon = "rectangle.split.3x1"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 2.0

    private let valueLabel = NSTextField(labelWithString: "")
    var paneCountProvider: (() -> Int)?

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
        let count = paneCountProvider?() ?? 0
        valueLabel.stringValue = "\(count) pane\(count == 1 ? "" : "s")"
    }
}
```

**Step 2: UptimeSegment**

```swift
import AppKit

class UptimeSegment: StatusBarSegment {
    let id = "uptime"
    let label = "Session Uptime"
    let icon = "clock"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 60.0

    private let valueLabel = NSTextField(labelWithString: "")
    private let startDate = Date()

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
        let elapsed = Int(Date().timeIntervalSince(startDate))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        if hours > 0 {
            valueLabel.stringValue = "\(hours)h \(minutes)m"
        } else {
            valueLabel.stringValue = "\(minutes)m"
        }
    }
}
```

**Step 3: ExitCodeSegment**

```swift
import AppKit

class ExitCodeSegment: StatusBarSegment {
    let id = "exit-code"
    let label = "Exit Code"
    let icon = "exclamationmark.circle"
    let position = SegmentPosition.left
    let refreshInterval: TimeInterval = 0  // updated externally, not polled

    private let valueLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private var lastExitCode: Int32 = 0

    func render() -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        valueLabel.font = font
        valueLabel.textColor = NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
        valueLabel.backgroundColor = .clear
        valueLabel.isBezeled = false
        valueLabel.isEditable = false
        valueLabel.isSelectable = false

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: container.topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func setExitCode(_ code: Int32) {
        lastExitCode = code
        update()
    }

    func update() {
        if lastExitCode != 0 {
            valueLabel.stringValue = "exit \(lastExitCode)"
            container.isHidden = false
        } else {
            valueLabel.stringValue = ""
            container.isHidden = true
        }
    }
}
```

**Step 4: Commit**

```bash
git add Sources/amux/Views/StatusBar/Segments/
git commit -m "feat: add PaneCount, Uptime, and ExitCode segments"
```

---

### Task 6: ShellSegment (custom user-defined segments)

**Files:**
- Create: `Sources/amux/Views/StatusBar/Segments/ShellSegment.swift`

**Step 1: Create ShellSegment**

```swift
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
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
```

**Step 2: Commit**

```bash
git add Sources/amux/Views/StatusBar/Segments/ShellSegment.swift
git commit -m "feat: add ShellSegment for custom user-defined segments"
```

---

### Task 7: Rewrite PaneStatusBar to use segments

**Files:**
- Modify: `Sources/amux/Views/PaneStatusBar.swift` (full rewrite)

**Step 1: Rewrite PaneStatusBar**

Replace the entire file with a segment-driven implementation:

```swift
import AppKit

class PaneStatusBar: NSView {
    static let barHeight: CGFloat = 22

    private let leftStack = NSStackView()
    private let centerStack = NSStackView()
    private let rightStack = NSStackView()
    private let topBorder = NSView()

    private var segments: [StatusBarSegment] = []
    private var timers: [String: Timer] = []
    private var renderedViews: [String: NSView] = [:]

    // Built-in segments (kept as properties for external wiring)
    let processSegment = ProcessSegment()
    let cwdSegment = CWDSegment()
    let gitSegment = GitSegment()
    let cpuSegment = CPUSegment()
    let memorySegment = MemorySegment()
    let batterySegment = BatterySegment()
    let paneCountSegment = PaneCountSegment()
    let uptimeSegment = UptimeSegment()
    let exitCodeSegment = ExitCodeSegment()

    override init(frame: NSRect) {
        super.init(frame: frame)
        gitSegment.cwdSegment = cwdSegment
        registerBuiltInSegments()
        registerCustomSegments()
        setupUI()
        rebuild()

        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange),
            name: StatusBarConfig.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timers.values.forEach { $0.invalidate() }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Registration

    private func registerBuiltInSegments() {
        segments = [
            processSegment, cwdSegment, gitSegment,
            cpuSegment, memorySegment, batterySegment,
            paneCountSegment, uptimeSegment, exitCodeSegment,
        ]
    }

    private func registerCustomSegments() {
        for def in StatusBarConfig.shared.customDefinitions {
            segments.append(ShellSegment(definition: def))
        }
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.borderPrimary.cgColor
        addSubview(topBorder)

        for stack in [leftStack, centerStack, rightStack] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            addSubview(stack)
        }

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: centerStack.leadingAnchor, constant: -12),

            centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: centerStack.trailingAnchor, constant: 12),
        ])
    }

    // MARK: - Rebuild

    private func rebuild() {
        // Stop all timers
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()

        // Clear stacks
        for stack in [leftStack, centerStack, rightStack] {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        renderedViews.removeAll()

        let config = StatusBarConfig.shared

        for segment in segments {
            guard config.isEnabled(segment.id) else { continue }

            let view = segment.render()
            renderedViews[segment.id] = view

            switch segment.position {
            case .left: leftStack.addArrangedSubview(view)
            case .center: centerStack.addArrangedSubview(view)
            case .right: rightStack.addArrangedSubview(view)
            }

            // Initial update
            segment.update()

            // Start timer if interval > 0
            if segment.refreshInterval > 0 {
                let timer = Timer.scheduledTimer(
                    withTimeInterval: segment.refreshInterval, repeats: true
                ) { [weak segment] _ in
                    segment?.update()
                }
                timers[segment.id] = timer
            }
        }
    }

    // MARK: - Public

    func setShellPid(_ pid: pid_t?) {
        processSegment.shellPid = pid
        cwdSegment.shellPid = pid
        refresh()
    }

    func refresh() {
        for segment in segments where StatusBarConfig.shared.isEnabled(segment.id) {
            segment.update()
        }
    }

    /// All registered segments (for command palette listing).
    var allSegments: [StatusBarSegment] { segments }

    // MARK: - Notifications

    @objc private func configDidChange() {
        rebuild()
    }

    @objc private func themeDidChange() {
        layer?.backgroundColor = Theme.background.cgColor
        topBorder.layer?.backgroundColor = Theme.borderPrimary.cgColor
        rebuild()
    }
}
```

**Step 2: Commit**

```bash
git add Sources/amux/Views/PaneStatusBar.swift
git commit -m "feat: rewrite PaneStatusBar with segment architecture"
```

---

### Task 8: Add command palette toggle commands

**Files:**
- Modify: `Sources/amux/App/AppDelegate.swift:326-352` (add toggle commands)

**Step 1: Add status bar toggle commands to the palette**

After the existing theme commands (around line 352), add segment toggle commands. Find the closing `]` of the commands array and insert before it:

```swift
// After the theme commands, before the closing bracket:
+ StatusBarConfig.shared.allSegmentLabels.map { segment in
    let enabled = StatusBarConfig.shared.isEnabled(segment.id)
    let checkmark = enabled ? "checkmark.circle.fill" : "circle"
    return PaletteCommand(
        name: "Status Bar: \(segment.label)",
        shortcut: "",
        icon: checkmark
    ) {
        StatusBarConfig.shared.toggle(segment.id)
    }
}
```

This requires adding a helper to `StatusBarConfig`:

```swift
// Add to StatusBarConfig
struct SegmentInfo {
    let id: String
    let label: String
}

private(set) var registeredSegments: [SegmentInfo] = []

func register(id: String, label: String) {
    if !registeredSegments.contains(where: { $0.id == id }) {
        registeredSegments.append(SegmentInfo(id: id, label: label))
    }
}
```

And have `PaneStatusBar` register each segment on init. The palette commands are rebuilt each time the palette opens, so the checkmark icon stays current.

**Step 2: Commit**

```bash
git add Sources/amux/App/AppDelegate.swift Sources/amux/Views/StatusBar/StatusBarConfig.swift
git commit -m "feat: add status bar toggle commands to command palette"
```

---

### Task 9: Wire up TerminalPane and verify

**Files:**
- Modify: `Sources/amux/Views/TerminalPane.swift:147-158` (setupStatusBar stays the same)
- Modify: `Sources/amux/Views/TerminalPane.swift:465,490` (setShellPid calls stay the same)

**Step 1: Verify TerminalPane integration**

The existing `TerminalPane` code already calls `statusBar.setShellPid(pid)` which still exists on the new `PaneStatusBar`. No changes needed to `TerminalPane` -- just verify it compiles.

**Step 2: Build and test**

```bash
swift build 2>&1 | head -30
```

Expected: clean build with no errors.

**Step 3: Manual test**

- Launch the app
- Open command palette
- Search "Status Bar"
- Toggle "Status Bar: CPU Usage" -- CPU should appear in right zone
- Toggle "Status Bar: Working Directory" -- cwd should appear in center
- Quit and relaunch -- toggled segments should persist

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: complete status bar redesign with pluggable segments"
```

---

## File Summary

```
Sources/amux/Views/StatusBar/
  StatusBarSegment.swift          (protocol + enum)
  StatusBarConfig.swift           (persistence + toggle)
  Segments/
    ProcessSegment.swift
    CWDSegment.swift
    GitSegment.swift
    CPUSegment.swift
    MemorySegment.swift
    BatterySegment.swift
    PaneCountSegment.swift
    UptimeSegment.swift
    ExitCodeSegment.swift
    ShellSegment.swift

Modified:
  Sources/amux/Views/PaneStatusBar.swift    (full rewrite)
  Sources/amux/App/AppDelegate.swift        (add toggle commands)
```
