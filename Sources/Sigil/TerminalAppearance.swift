import AppKit
import SwiftUI

/// A terminal colour scheme: background, text, cursor, selection and the 16 ANSI colours.
struct TerminalPalette: Identifiable, Equatable {
    let id: String
    let name: String
    let isLight: Bool
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selection: UInt32
    let ansi: [UInt32]

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let all: [TerminalPalette] = [
        .init(id: "ink", name: "Mürekkep", isLight: false, background: 0x17152E, foreground: 0xEEEBE2, cursor: 0x5DCAA5, selection: 0x534AB7,
              ansi: [0x1B1936, 0xE06C4A, 0x5DCAA5, 0xEFB75A, 0x859EF0, 0xC38BE8, 0x6FC8D8, 0xD8D4C8,
                     0x5A5580, 0xF0997B, 0x9FE1CB, 0xFAC775, 0xAFBEF6, 0xDAB4F2, 0x9CDFEA, 0xFFFDF8]),
        .init(id: "parchment", name: "Parşömen", isLight: true, background: 0xF7F4EC, foreground: 0x26215C, cursor: 0x0F6E56, selection: 0xAFA9EC,
              ansi: [0x3B3561, 0xC2491F, 0x0F6E56, 0x9A5B0C, 0x3A57B7, 0x8A3FA8, 0x1F7A8C, 0x8C8778,
                     0x6B6690, 0xE0623A, 0x138A6C, 0xB87514, 0x5470D6, 0xA65BC6, 0x2795A8, 0x26215C]),
        .init(id: "night", name: "Kutup gecesi", isLight: false, background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0x88C0D0, selection: 0x4C566A,
              ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                     0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]),
        .init(id: "amber", name: "Kehribar", isLight: false, background: 0x282828, foreground: 0xEBDBB2, cursor: 0xFE8019, selection: 0x504945,
              ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                     0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]),
        .init(id: "midnight", name: "Gece yarısı", isLight: false, background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, selection: 0x44475A,
              ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                     0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]),
        .init(id: "solar-dark", name: "Güneş · koyu", isLight: false, background: 0x002B36, foreground: 0x93A1A1, cursor: 0x93A1A1, selection: 0x073642,
              ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                     0x586E75, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0x6C71C4, 0x2AA198, 0xFDF6E3]),
        .init(id: "solar-light", name: "Güneş · açık", isLight: true, background: 0xFDF6E3, foreground: 0x586E75, cursor: 0x586E75, selection: 0xEEE8D5,
              ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0x93A1A1,
                     0x586E75, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0x6C71C4, 0x2AA198, 0x002B36]),
        .init(id: "plain", name: "Sade", isLight: false, background: 0x1E1E1E, foreground: 0xD4D4D4, cursor: 0xD4D4D4, selection: 0x264F78,
              ansi: [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                     0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF]),
    ]

    static func named(_ id: String) -> TerminalPalette {
        if id == appID { return matching(ThemeStore.shared.current) }
        return all.first { $0.id == id } ?? all[0]
    }

    /// "Uygulamayla aynı": the terminal takes the app theme's page as its background, so the two never clash.
    static let appID = "app"

    static func matching(_ t: AppTheme) -> TerminalPalette {
        let base = t.isDark ? named("ink") : named("parchment")
        var ansi = base.ansi
        // Blue and magenta lean towards the theme's own accent and brand.
        ansi[4] = t.isDark ? t.accent : t.brand
        ansi[12] = t.isDark ? t.soft : t.accent
        ansi[2] = t.success
        ansi[10] = t.success
        return TerminalPalette(id: appID, name: "Uygulamayla aynı", isLight: !t.isDark, background: t.page,
                               foreground: t.isDark ? 0xECEAF6 : 0x1F1B4D, cursor: t.success,
                               selection: t.isDark ? t.brand : t.soft, ansi: ansi)
    }
}

/// Everything about how the in-app terminal looks and types, saved across launches.
@MainActor
@Observable
final class TerminalAppearance {
    static let shared = TerminalAppearance()

    enum Cursor: String, CaseIterable, Identifiable {
        case block, bar, underline
        var id: String { rawValue }
        var title: String {
            switch self {
            case .block: return "Blok"
            case .bar: return "Çizgi"
            case .underline: return "Alt çizgi"
            }
        }
    }

    /// "" = the system monospaced font (SF Mono).
    var fontFamily: String { didSet { save("terminalFontFamily", fontFamily) } }
    var paletteID: String { didSet { save("terminalPalette", paletteID) } }
    var cursor: Cursor { didSet { save("terminalCursor", cursor.rawValue) } }
    var cursorBlinks: Bool { didSet { save("terminalCursorBlinks", cursorBlinks) } }
    /// ⌥ sends Meta (Esc-prefixed) instead of typing special characters like @ or €.
    var optionAsMeta: Bool { didSet { save("terminalOptionAsMeta", optionAsMeta) } }
    /// Show command suggestions under the prompt and complete them with Tab.
    var suggestions: Bool { didSet { save("terminalSuggestions", suggestions) } }

    var palette: TerminalPalette { TerminalPalette.named(paletteID) }

    private init() {
        let d = UserDefaults.standard
        fontFamily = d.string(forKey: "terminalFontFamily") ?? ""
        paletteID = d.string(forKey: "terminalPalette") ?? TerminalPalette.appID
        cursor = Cursor(rawValue: d.string(forKey: "terminalCursor") ?? "") ?? .block
        cursorBlinks = d.object(forKey: "terminalCursorBlinks") as? Bool ?? true
        optionAsMeta = d.object(forKey: "terminalOptionAsMeta") as? Bool ?? false
        suggestions = d.object(forKey: "terminalSuggestions") as? Bool ?? true
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    func font(size: CGFloat) -> NSFont {
        if !fontFamily.isEmpty, let f = NSFont(name: fontFamily, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-width font families, for the picker.
    static let monospacedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let f = NSFont(name: family, size: 12) else { return false }
            return f.isFixedPitch && !family.hasPrefix(".")
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()
}

/// Terminal colours, following the chosen palette (read through the observable appearance, so views update).
@MainActor
enum TerminalTheme {
    private static var p: TerminalPalette { TerminalAppearance.shared.palette }
    static var background: NSColor { TerminalPalette.color(p.background) }
    /// Tab strip: a step darker (or, on light palettes, a touch darker) than the terminal.
    static var chrome: NSColor { background.blended(withFraction: p.isLight ? 0.06 : 0.28, of: .black) ?? background }
    static var foreground: NSColor { TerminalPalette.color(p.foreground) }
    static var caret: NSColor { TerminalPalette.color(p.cursor) }
    static var selection: NSColor { TerminalPalette.color(p.selection, alpha: 0.55) }
    static var isLight: Bool { p.isLight }
    /// Panels drawn over the terminal (palette, find, explain): solid and in the terminal's own colours, never a
    /// translucent material that would pick up the app's light or dark look.
    static var panel: Color { Color(nsColor: background.blended(withFraction: p.isLight ? 0.04 : 0.10, of: p.isLight ? .black : .white) ?? background) }
    static var colorScheme: ColorScheme { p.isLight ? .light : .dark }

    // Semantic colours for panels over the terminal, taken from the terminal's own (bright, on dark) ANSI colours so
    // they always contrast with it, whatever the app theme is.
    private static func ansiColor(_ dark: Int, _ light: Int) -> Color { Color(nsColor: TerminalPalette.color(p.ansi[p.isLight ? light : dark])) }
    static var accent: Color { ansiColor(12, 4) }
    static var good: Color { ansiColor(10, 2) }
    static var warn: Color { ansiColor(11, 3) }
    static var bad: Color { ansiColor(9, 1) }
    static var text: Color { Color(nsColor: foreground) }
    static var muted: Color { Color(nsColor: foreground).opacity(0.62) }
    static var panelStroke: Color { Color(nsColor: foreground).opacity(p.isLight ? 0.14 : 0.16) }
    static var ansi: [(UInt16, UInt16, UInt16)] {
        p.ansi.map { (UInt16(($0 >> 16) & 0xFF), UInt16(($0 >> 8) & 0xFF), UInt16($0 & 0xFF)) }
    }
}
