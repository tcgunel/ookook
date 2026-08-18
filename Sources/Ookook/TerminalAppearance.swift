import AppKit
import Combine
import SwiftTerm

/// A named terminal palette.
///
/// Only the 16 ANSI colours plus background/foreground/cursor are defined:
/// SwiftTerm generates the 256-colour cube itself, and a theme that tried to
/// override that would have to ship 240 more values to change nothing visible.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    /// Hex strings, `#rrggbb`, in ANSI order: black, red, green, yellow, blue,
    /// magenta, cyan, white, then the eight bright variants.
    let ansi: [String]
    let background: String
    let foreground: String
    let cursor: String

    static let system = TerminalTheme(
        id: "system", name: "System",
        ansi: ["#000000", "#c23621", "#25bc26", "#adad27", "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
               "#818383", "#fc391f", "#31e722", "#eaec23", "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb"],
        background: "#1e1e1e", foreground: "#d4d4d4", cursor: "#d4d4d4")

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
               "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"],
        background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2")

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark",
        ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
               "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
        background: "#002b36", foreground: "#839496", cursor: "#93a1a1")

    static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
               "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"],
        background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9")

    static let light = TerminalTheme(
        id: "light", name: "Light",
        ansi: ["#000000", "#c91b00", "#00c200", "#c7c400", "#0225c7", "#ca30c7", "#00c5c7", "#c7c7c7",
               "#686868", "#ff6e67", "#5ff967", "#fefb67", "#6871ff", "#ff77ff", "#5ffdff", "#ffffff"],
        background: "#fffffe", foreground: "#262626", cursor: "#262626")

    static let all: [TerminalTheme] = [.system, .dracula, .solarizedDark, .nord, .light]

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .system
    }
}

/// Terminal font and colours, applied to every live terminal at once.
///
/// The views are long-lived and shared with the grid, so this pushes changes to
/// the existing ones rather than expecting them to be rebuilt - a rebuild would
/// throw away scrollback, which is the one thing a terminal must not lose.
enum TerminalAppearance {
    static let changed = Notification.Name("ookook.terminalAppearanceChanged")

    enum Key {
        static let fontName = "terminalFontName"
        static let fontSize = "terminalFontSize"
        static let theme = "terminalTheme"
    }

    static let defaultSize: Double = 13

    static var fontName: String {
        UserDefaults.standard.string(forKey: Key.fontName) ?? ""
    }

    static var fontSize: Double {
        let stored = UserDefaults.standard.double(forKey: Key.fontSize)
        // 0 is both "unset" and an impossible size, so it means the default.
        return stored > 0 ? stored : defaultSize
    }

    static var themeID: String {
        UserDefaults.standard.string(forKey: Key.theme) ?? TerminalTheme.system.id
    }

    /// An empty stored name means the system monospaced face, which is not
    /// available by name and so cannot be round-tripped through the picker.
    static var font: NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Every installed fixed-pitch face, for the picker.
    static var availableFonts: [String] {
        let names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return names.sorted()
    }

    static func apply(to view: TerminalView) {
        view.font = font
        let theme = TerminalTheme.theme(id: themeID)
        view.installColors(theme.ansi.map { SwiftTerm.Color(hex: $0) })
        view.nativeBackgroundColor = NSColor(hex: theme.background)
        view.nativeForegroundColor = NSColor(hex: theme.foreground)
        view.caretColor = NSColor(hex: theme.cursor)
    }

    /// Called by the settings pane after a change.
    static func broadcast() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

extension SwiftTerm.Color {
    /// SwiftTerm colour components are 16-bit, so each 8-bit channel is scaled
    /// rather than truncated - `0xff` must become `0xffff`, not `0xff00`.
    convenience init(hex: String) {
        let (r, g, b) = Self.components(hex)
        self.init(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    static func components(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return (0, 0, 0) }
        return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = SwiftTerm.Color.components(hex)
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
