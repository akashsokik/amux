import AppKit

class PaneStatusBar: NSView {
    static let barHeight: CGFloat = 22

    private let leftStack = NSStackView()
    private let centerStack = NSStackView()
    private let rightStack = NSStackView()
    private let topBorder = NSView()

    private var segments: [StatusBarSegment] = []
    private var timers: [String: Timer] = [:]
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
        for segment in segments {
            StatusBarConfig.shared.register(id: segment.id, label: segment.label)
        }
    }

    private func registerCustomSegments() {
        for def in StatusBarConfig.shared.customDefinitions {
            let segment = ShellSegment(definition: def)
            segments.append(segment)
            StatusBarConfig.shared.register(id: segment.id, label: segment.label)
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
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()

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

            segment.update()

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
