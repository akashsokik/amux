import AppKit
import CGhostty

/// Delegate for terminal view events that bubble up to the container.
protocol GhosttyTerminalViewDelegate: AnyObject {
    func terminalViewDidUpdateTitle(_ view: GhosttyTerminalView, title: String)
    func terminalViewDidUpdatePwd(_ view: GhosttyTerminalView, pwd: String)
    func terminalViewProcessTerminated(_ view: GhosttyTerminalView)
    func terminalViewBell(_ view: GhosttyTerminalView)
    func terminalViewDidGainFocus(_ view: GhosttyTerminalView)
}

/// An NSView that hosts a single Ghostty terminal surface.
/// This is the equivalent of Ghostty's SurfaceView in SurfaceView_AppKit.swift,
/// but simplified for amux's needs.
class GhosttyTerminalView: NSView, NSTextInputClient {
    let paneID: UUID

    /// When true, layout defers ghostty_surface_set_size calls to avoid flickering
    /// during animated sidebar toggles. Set by MainWindowController before/after animation.
    static var deferSurfaceResize = false

    /// The underlying ghostty surface handle. nil means the surface failed to create.
    private(set) var surface: ghostty_surface_t?

    /// Delegate for events
    weak var delegate: GhosttyTerminalViewDelegate?

    /// Whether this view currently has focus
    var isFocused: Bool = false {
        didSet {
            updateFocusBorder()
            guard let surface = surface else { return }
            ghostty_surface_set_focus(surface, isFocused)
        }
    }

    /// The current terminal title
    var title: String = "Terminal"

    /// The current working directory
    var currentDirectory: String?

    /// Whether a surface has been created
    private var surfaceCreated = false

    /// Text queued before the surface existed; flushed shortly after
    /// createSurface(app:) succeeds. Used so callers can pre-type a command
    /// (e.g. `docker exec -it X sh\n`) when spawning a new tab.
    private var pendingText: String?

    /// Marked text for input method support
    private var markedText = NSMutableAttributedString()

    /// Text accumulated during keyDown for composition
    private var keyTextAccumulator: [String]?

    /// Focus border layer
    private var focusBorderLayer: CALayer?

    /// Track the previous pressure stage for force click
    private var prevPressureStage: Int = 0

    /// Accumulated magnification for pinch-to-zoom (threshold-based)
    private var magnificationAccumulator: CGFloat = 0

    /// Accumulated scroll delta for Cmd+scroll zoom
    private var scrollZoomAccumulator: CGFloat = 0

    // MARK: - Init

    init(paneID: UUID) {
        self.paneID = paneID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        // We need a CAMetalLayer for GPU rendering
        let metalLayer = CAMetalLayer()
        metalLayer.isOpaque = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.pixelFormat = .bgra8Unorm
        self.layer = metalLayer
        self.wantsLayer = true

        setupFocusBorder()
        updateTrackingAreas()

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: Theme.didChangeNotification, object: nil
        )
    }

    @objc private func themeDidChange() {
        updateFocusBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        print(
            "[GhosttyTerminalView] DEINIT pane \(String(paneID.uuidString.prefix(4))) surface=\(surface != nil)"
        )
        trackingAreas.forEach { removeTrackingArea($0) }
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Surface Creation

    /// Create the ghostty surface. Must be called after the view is in the window hierarchy
    /// and the GhosttyApp is ready.
    func createSurface(app: ghostty_app_t) {
        guard !surfaceCreated else { return }
        surfaceCreated = true

        // Build the surface config
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        )
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(
            self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0  // Use config default
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        let workingDir: String
        if let projectRoot = ProcessInfo.processInfo.environment["AMUX_PROJECT_ROOT"] {
            workingDir = projectRoot
        } else {
            workingDir = NSHomeDirectory()
        }
        let workingDirCStr = strdup(workingDir)
        cfg.working_directory = UnsafePointer(workingDirCStr)

        let surface = ghostty_surface_new(app, &cfg)
        free(workingDirCStr)
        guard let surface = surface else {
            print("[GhosttyTerminalView] ghostty_surface_new failed for pane \(paneID)")
            return
        }
        self.surface = surface
        print(
            "[GhosttyTerminalView] SURFACE CREATED for pane \(String(paneID.uuidString.prefix(4)))")

        // Set initial content scale
        let scale = self.window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)

        // Set initial size
        let scaledSize = self.convertToBacking(self.bounds.size)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))

        // Set focus state
        ghostty_surface_set_focus(surface, isFocused)

        // Flush text queued before the surface existed. Defer one tick so the
        // shell's prompt has a chance to draw first.
        if pendingText != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.flushPendingTextIfReady()
            }
        }
    }

    /// Write text directly to the PTY as if typed. Caller supplies any
    /// trailing newline. Safe before the surface is ready: text is buffered
    /// and flushed once the surface comes up.
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        if let surface = surface, surfaceCreated {
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
        } else {
            pendingText = (pendingText ?? "") + text
        }
    }

    private func flushPendingTextIfReady() {
        guard let surface = surface, surfaceCreated, let text = pendingText, !text.isEmpty else {
            return
        }
        pendingText = nil
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    // MARK: - Focus Border

    private func setupFocusBorder() {
        let border = CALayer()
        border.borderWidth = 0
        border.borderColor = NSColor.clear.cgColor
        border.zPosition = 1000
        layer?.addSublayer(border)
        focusBorderLayer = border
    }

    private func updateFocusBorder() {
        if isFocused {
            focusBorderLayer?.shadowColor = Theme.primary.cgColor
            focusBorderLayer?.shadowOpacity = 0.10
            focusBorderLayer?.shadowOffset = .zero
            focusBorderLayer?.shadowRadius = 60
        } else {
            focusBorderLayer?.shadowOpacity = 0
        }
        focusBorderLayer?.borderColor = NSColor.clear.cgColor
        alphaValue = isFocused ? 1.0 : 0.65
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        focusBorderLayer?.frame = bounds
        syncSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize(for: newSize)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        syncSurfaceSize(for: newSize)
    }

    private func syncSurfaceSize(for size: NSSize? = nil) {
        guard let surface = surface else { return }

        // Skip surface resize during animated sidebar toggles to avoid flickering.
        // The final size is applied once the animation completes.
        if GhosttyTerminalView.deferSurfaceResize { return }

        let targetSize = size ?? bounds.size
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        let scaledSize = convertToBacking(targetSize)
        guard scaledSize.width > 0, scaledSize.height > 0 else { return }

        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Update the Metal layer's contents scale
        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface = surface else { return }

        // Update content scale
        let fbFrame = self.convertToBacking(self.frame)
        let xScale = fbFrame.size.width / self.frame.size.width
        let yScale = fbFrame.size.height / self.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        syncSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }

        // Update backing properties when we get a window
        layer?.contentsScale = window.backingScaleFactor

        if let surface = surface, let screen = window.screen {
            ghostty_surface_set_display_id(surface, screen.displayID ?? 0)
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            isFocused = true
            delegate?.terminalViewDidGainFocus(self)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            isFocused = false
        }
        return result
    }

    func focus() {
        window?.makeFirstResponder(self)
    }

    // MARK: - Mouse Events

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .inVisibleRect,
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil
            ))
    }

    /// Send the current mouse position to Ghostty from an NSEvent.
    private func updateMousePos(from event: NSEvent) {
        guard let surface = surface else { return }
        let pos = self.convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.size.height - pos.y, mods)
    }

    override func mouseDown(with event: NSEvent) {
        // Ensure this view becomes first responder on click
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        guard let surface = surface else { return }
        updateMousePos(from: event)
        let mods = ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        prevPressureStage = 0
        guard let surface = surface else { return }
        updateMousePos(from: event)
        let mods = ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return super.rightMouseDown(with: event) }
        updateMousePos(from: event)
        let mods = ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return super.rightMouseUp(with: event) }
        updateMousePos(from: event)
        let mods = ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        updateMousePos(from: event)
        let mods = ghosttyMods(event.modifierFlags)
        let button = mouseButton(from: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        updateMousePos(from: event)
        let mods = ghosttyMods(event.modifierFlags)
        let button = mouseButton(from: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        updateMousePos(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateMousePos(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = ghosttyMods(event.modifierFlags)
        // Negative position indicates cursor left
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }

        // Cmd+scroll = font zoom (per-pane)
        if event.modifierFlags.contains(.command) {
            let delta =
                event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 10
            scrollZoomAccumulator += delta
            let threshold: CGFloat = 10
            while scrollZoomAccumulator >= threshold {
                scrollZoomAccumulator -= threshold
                increaseFontSize()
            }
            while scrollZoomAccumulator <= -threshold {
                scrollZoomAccumulator += threshold
                decreaseFontSize()
            }
            return
        }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY

        if event.hasPreciseScrollingDeltas {
            // 2x speed multiplier for trackpad scrolling
            x *= 2
            y *= 2
        }

        // Build scroll mods as a packed int
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= (1 << 0)  // precision bit
        }
        // Momentum phase
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        scrollMods |= (momentum << 1)

        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        prevPressureStage = event.stage
    }

    // MARK: - Pinch-to-Zoom

    override func magnify(with event: NSEvent) {
        guard surface != nil else { return }
        if event.phase == .began {
            magnificationAccumulator = 0
        }
        magnificationAccumulator += event.magnification
        let threshold: CGFloat = 0.1
        while magnificationAccumulator >= threshold {
            magnificationAccumulator -= threshold
            increaseFontSize()
        }
        while magnificationAccumulator <= -threshold {
            magnificationAccumulator += threshold
            decreaseFontSize()
        }
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            self.interpretKeyEvents([event])
            return
        }

        // Translate mods for option-as-alt etc.
        // ghostty_surface_key_translation_mods returns ghostty_input_mods_e directly --
        // do NOT round-trip through NSEvent.ModifierFlags (different bit layout).
        let translationModsGhostty = ghostty_surface_key_translation_mods(
            surface, ghosttyMods(event.modifierFlags))

        // Build translation mods -- keep hidden bits, swap known ones.
        // Only translate control/option/command; always preserve shift from
        // the original event so the input system produces correct shifted
        // characters (e.g. shift+/ → "?").
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.control, .option, .command] {
            let ghosttyFlag = ghosttyMods(flag)
            if translationModsGhostty.rawValue & ghosttyFlag.rawValue != 0 {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent =
                NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Start accumulating text from interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        self.interpretKeyEvents([translationEvent])

        // Sync preedit state
        if markedText.length > 0 {
            markedText.string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(markedText.string.utf8.count))
            }
        } else if markedTextBefore {
            ghostty_surface_preedit(surface, nil, 0)
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            // We have composed text from the input system
            for text in list {
                _ = sendKeyAction(
                    action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // Regular key event
            _ = sendKeyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKeyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Check if the correct side is pressed
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = sendKeyAction(action, event: event)
    }

    /// Key equivalents that amux's menu bar owns. These must NOT be
    /// swallowed by the terminal -- return false so the menu system handles them.
    private static let appMenuShortcuts: Set<String> = [
        "d", "D", "w", "W", "t", "T", "N", "p", "f", "\\", "+", "-", "0", "=",
        "]", "[", "}", "{", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard isFocused else { return false }
        guard let surface = surface else { return false }

        // If Cmd is held and the key matches one of our app menu shortcuts,
        // let the menu bar handle it instead of the terminal.
        if event.modifierFlags.contains(.command) {
            let chars = event.charactersIgnoringModifiers ?? ""
            if GhosttyTerminalView.appMenuShortcuts.contains(chars) {
                return false
            }

            // Arrow keys with Cmd (pane nav, resize) -- let menu handle them
            let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]  // left, right, down, up
            if arrowKeyCodes.contains(event.keyCode) {
                return false
            }
        }

        // Check if this is a ghostty keybinding
        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ghosttyEvent.text = ptr
            var flags = ghostty_binding_flags_e(0)
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
        }

        if isBinding {
            self.keyDown(with: event)
            return true
        }

        // Handle C-/ as C-_ (prevents system beep)
        if event.charactersIgnoringModifiers == "/" && event.modifierFlags.contains(.control)
            && event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
        {
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "_",
                charactersIgnoringModifiers: "_",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
            if let finalEvent = finalEvent {
                self.keyDown(with: finalEvent)
                return true
            }
        }

        // Handle C-Enter (prevent context menu)
        if event.charactersIgnoringModifiers == "\r" && event.modifierFlags.contains(.control) {
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
            if let finalEvent = finalEvent {
                self.keyDown(with: finalEvent)
                return true
            }
        }

        return false
    }

    /// Send a key action to the ghostty surface.
    @discardableResult
    private func sendKeyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = surface else { return false }

        var keyEv = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEv.composing = composing

        // Ghostty should encode physical editing keys like Backspace/Delete
        // from the key event, not as literal control-text bytes.
        if let text = text, !text.isEmpty, !text.isSingleControlScalar {
            return text.withCString { ptr in
                keyEv.text = ptr
                return ghostty_surface_key(surface, keyEv)
            }
        } else {
            return ghostty_surface_key(surface, keyEv)
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        // If we have a key text accumulator, this is from interpretKeyEvents
        // during keyDown and we should accumulate it
        let str: String
        if let s = string as? NSAttributedString {
            str = s.string
        } else if let s = string as? String {
            str = s
        } else {
            return
        }

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(str)
        } else {
            // Direct insert (e.g. from IME)
            guard let surface = surface else { return }
            str.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(str.utf8.count))
            }
        }

        // Clear marked text on insert
        markedText.mutableString.setString("")
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: s)
        } else if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
        guard let surface = surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = surface else {
            return NSRect(x: 0, y: 0, width: 0, height: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        // Convert from view coordinates to screen coordinates
        let viewPoint = NSPoint(x: x, y: frame.height - y)
        let windowPoint = self.convert(viewPoint, to: nil)
        let screenPoint = window?.convertPoint(toScreen: windowPoint) ?? windowPoint

        return NSRect(x: screenPoint.x, y: screenPoint.y - h, width: w, height: h)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    // For doCommandBySelector, handle as noop so interpretKeyEvents works
    override func doCommand(by selector: Selector) {
        // If we're inside keyDown (accumulating text), just ignore the command
        // so the key event goes through our normal path
        if keyTextAccumulator != nil {
            return
        }
        super.doCommand(by: selector)
    }

    // MARK: - Font Size

    func increaseFontSize() {
        guard let surface = surface else { return }
        let action = "increase_font_size:1"
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func decreaseFontSize() {
        guard let surface = surface else { return }
        let action = "decrease_font_size:1"
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func resetFontSize() {
        guard let surface = surface else { return }
        let action = "reset_font_size"
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - Helpers

    private func mouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        case 8: return GHOSTTY_MOUSE_NINE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// Get the CGDirectDisplayID for this screen.
    var displayID: UInt32? {
        guard
            let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return screenNumber.uint32Value
    }
}
