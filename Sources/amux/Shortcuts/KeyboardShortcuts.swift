import AppKit

enum ShortcutAction: String, CaseIterable {
    // Session
    case newSession
    case closeSession
    case renameSession
    case nextSession
    case previousSession

    // Pane
    case splitVertical
    case splitHorizontal
    case layoutThreeVerticalPanes
    case layoutThreeHorizontalPanes
    case layoutFourEqualPanes
    case closePane
    case navigateUp
    case navigateDown
    case navigateLeft
    case navigateRight
    case resizeUp
    case resizeDown
    case resizeLeft
    case resizeRight
    case zoomPane
    case equalizePanes

    // View
    case toggleSidebar
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize

    var displayName: String {
        switch self {
        case .newSession: return "New Session"
        case .closeSession: return "Close Session"
        case .renameSession: return "Rename Session"
        case .nextSession: return "Next Session"
        case .previousSession: return "Previous Session"
        case .splitVertical: return "Split Vertical"
        case .splitHorizontal: return "Split Horizontal"
        case .layoutThreeVerticalPanes: return "Layout: 3 Vertical Panes"
        case .layoutThreeHorizontalPanes: return "Layout: 3 Horizontal Panes"
        case .layoutFourEqualPanes: return "Layout: 4 Equal Panes"
        case .closePane: return "Close Pane"
        case .navigateUp: return "Navigate Up"
        case .navigateDown: return "Navigate Down"
        case .navigateLeft: return "Navigate Left"
        case .navigateRight: return "Navigate Right"
        case .resizeUp: return "Resize Up"
        case .resizeDown: return "Resize Down"
        case .resizeLeft: return "Resize Left"
        case .resizeRight: return "Resize Right"
        case .zoomPane: return "Zoom Pane"
        case .equalizePanes: return "Equalize Panes"
        case .toggleSidebar: return "Toggle Sidebar"
        case .increaseFontSize: return "Increase Font Size"
        case .decreaseFontSize: return "Decrease Font Size"
        case .resetFontSize: return "Reset Font Size"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .newSession: return "t"
        case .closeSession: return "W"
        case .renameSession: return "N"
        case .nextSession: return "]"
        case .previousSession: return "["
        case .splitVertical: return "d"
        case .splitHorizontal: return "D"
        case .layoutThreeVerticalPanes: return "v"
        case .layoutThreeHorizontalPanes: return "h"
        case .layoutFourEqualPanes: return "g"
        case .closePane: return "w"
        case .navigateUp: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .navigateDown: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .navigateLeft: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .navigateRight: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .resizeUp: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .resizeDown: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .resizeLeft: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .resizeRight: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .zoomPane: return "\r"
        case .equalizePanes: return "="
        case .toggleSidebar: return "b"
        case .increaseFontSize: return "+"
        case .decreaseFontSize: return "-"
        case .resetFontSize: return "0"
        }
    }

    var modifierMask: NSEvent.ModifierFlags {
        switch self {
        case .newSession: return [.command]
        case .closeSession: return [.command, .shift]
        case .renameSession: return [.command, .shift]
        case .nextSession: return [.command, .shift]
        case .previousSession: return [.command, .shift]
        case .splitVertical: return [.command]
        case .splitHorizontal: return [.command, .shift]
        case .layoutThreeVerticalPanes: return [.command, .option]
        case .layoutThreeHorizontalPanes: return [.command, .option]
        case .layoutFourEqualPanes: return [.command, .option]
        case .closePane: return [.command]
        case .navigateUp: return [.command, .option]
        case .navigateDown: return [.command, .option]
        case .navigateLeft: return [.command, .option]
        case .navigateRight: return [.command, .option]
        case .resizeUp: return [.command, .shift]
        case .resizeDown: return [.command, .shift]
        case .resizeLeft: return [.command, .shift]
        case .resizeRight: return [.command, .shift]
        case .zoomPane: return [.command, .shift]
        case .equalizePanes: return [.command, .option]
        case .toggleSidebar: return [.command]
        case .increaseFontSize: return [.command]
        case .decreaseFontSize: return [.command]
        case .resetFontSize: return [.command]
        }
    }
}
