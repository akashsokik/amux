import AppKit
import CGhostty

// MARK: - Modifier Conversion

extension String {
    /// True when this string is a single Unicode control scalar such as ASCII DEL.
    var isSingleControlScalar: Bool {
        guard count == 1, let scalar = unicodeScalars.first else { return false }
        return scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}

/// Convert NSEvent modifier flags to Ghostty modifier flags.
func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift)   { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option)  { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    // Detect right-side modifiers using device-specific masks
    let rawFlags = flags.rawValue
    if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0   { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0    { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0    { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(rawValue: mods)
}

// MARK: - NSEvent Key Event Conversion

extension NSEvent {
    /// Build a ghostty_input_key_s from this NSEvent.
    /// Does NOT set `text` or `composing` -- caller must do that.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false

        ev.mods = ghosttyMods(modifierFlags)
        // Consumed mods: everything except control and command
        ev.consumed_mods = ghosttyMods(
            (translationMods ?? modifierFlags)
                .subtracting([.control, .command])
        )

        // Unshifted codepoint
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                ev.unshifted_codepoint = codepoint.value
            }
        }

        return ev
    }

    /// The text suitable for passing to ghostty as key event text.
    var ghosttyCharacters: String? {
        guard let characters = characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // Control characters: let Ghostty handle encoding
            if characters.isSingleControlScalar {
                let baseCharacters = self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
                if let baseCharacters, !baseCharacters.isSingleControlScalar {
                    return baseCharacters
                }
                return nil
            }
            // PUA range (function keys) -- don't pass to Ghostty
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
