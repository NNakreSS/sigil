import AppKit
import SwiftUI

/// One look for the whole app: surfaces, text accents, the call-to-action gradient and the glow behind the window.
struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    /// Window background.
    let page: UInt32
    /// Cards and raised surfaces.
    let surface: UInt32
    /// Primary buttons and seal bodies; text on it is `onBrand`.
    let brand: UInt32
    let onBrand: UInt32
    /// Links, selection, icons.
    let accent: UInt32
    let success: UInt32
    let danger: UInt32
    let warning: UInt32
    let soft: UInt32
    /// Call-to-action gradient (start → end) and the glow behind the window.
    let gradient: (UInt32, UInt32)
    let glow: UInt32
    /// Headings: serif for the parchment look, rounded elsewhere.
    let headingDesign: Font.Design

    static func == (a: AppTheme, b: AppTheme) -> Bool { a.id == b.id }

    static let night = AppTheme(
        id: "night", name: "Gece", isDark: true,
        page: 0x0D0C1D, surface: 0x18162F, brand: 0x6E5EF5, onBrand: 0xFFFFFF, accent: 0xA99BFF,
        success: 0x3EE0A1, danger: 0xFF6B5E, warning: 0xF6B44C, soft: 0xB8B0FF,
        gradient: (0x8B6CF6, 0x4F46E5), glow: 0x6E5EF5, headingDesign: .rounded)
    static let graphite = AppTheme(
        id: "graphite", name: "Grafit", isDark: true,
        page: 0x111214, surface: 0x1C1E23, brand: 0x3B82F6, onBrand: 0xFFFFFF, accent: 0x7DB4FF,
        success: 0x34D399, danger: 0xF87171, warning: 0xFBBF24, soft: 0xA5C8FF,
        gradient: (0x60A5FA, 0x2563EB), glow: 0x2563EB, headingDesign: .rounded)
    static let forest = AppTheme(
        id: "forest", name: "Orman gecesi", isDark: true,
        page: 0x0B1512, surface: 0x14231D, brand: 0x14A06F, onBrand: 0xFFFFFF, accent: 0x6EE7B7,
        success: 0x4ADE80, danger: 0xFF7A6B, warning: 0xF2C14E, soft: 0xA7F3D0,
        gradient: (0x34D399, 0x047857), glow: 0x10B981, headingDesign: .rounded)
    static let ink = AppTheme(
        id: "ink", name: "Mürekkep", isDark: false,
        page: 0xF7F4EC, surface: 0xFFFDF8, brand: 0x26215C, onBrand: 0xEEEDFE, accent: 0x534AB7,
        success: 0x0F6E56, danger: 0xC2491F, warning: 0x9A5B0C, soft: 0xAFA9EC,
        gradient: (0x3C3489, 0x1E1A4D), glow: 0xAFA9EC, headingDesign: .serif)
    static let daylight = AppTheme(
        id: "daylight", name: "Gün ışığı", isDark: false,
        page: 0xF5F5FA, surface: 0xFFFFFF, brand: 0x6E5EF5, onBrand: 0xFFFFFF, accent: 0x5B4BE0,
        success: 0x0E9F6E, danger: 0xE04B3A, warning: 0xB7791F, soft: 0xC7C0FF,
        gradient: (0x8B7CF6, 0x5B4BE0), glow: 0x8B7CF6, headingDesign: .rounded)

    static let all: [AppTheme] = [.night, .graphite, .forest, .ink, .daylight]
}

/// The chosen theme ("auto" follows macOS: Gün ışığı by day, Gece by night), saved across launches.
/// Not main-actor bound: colour tokens are read from anywhere; only `applyAppearance` touches AppKit.
@Observable
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()
    static let autoID = "auto"

    var selectedID: String {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "appTheme")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.applyAppearance() } }
        }
    }
    /// macOS is in dark mode (kept up to date by the app); decides "auto".
    var systemIsDark = false

    private init() {
        selectedID = UserDefaults.standard.string(forKey: "appTheme") ?? AppTheme.night.id
    }

    /// Light and dark variants in use (the same theme twice unless "auto").
    var pair: (light: AppTheme, dark: AppTheme) {
        if selectedID == Self.autoID { return (.daylight, .night) }
        let t = AppTheme.all.first { $0.id == selectedID } ?? .night
        return (t, t)
    }

    /// The theme for the current appearance.
    var current: AppTheme {
        let p = pair
        if p.light == p.dark { return p.light }
        return systemIsDark ? p.dark : p.light
    }

    /// Fixed themes force their light/dark appearance so system controls (forms, menus, pickers) match; auto follows macOS.
    @MainActor
    func applyAppearance() {
        let p = pair
        NSApp.appearance = p.light == p.dark ? NSAppearance(named: p.light.isDark ? .darkAqua : .aqua) : nil
    }

    /// A colour that follows the theme and, for "auto", the window's appearance.
    func color(_ value: KeyPath<AppTheme, UInt32>, alpha: CGFloat = 1) -> Color {
        let p = pair
        let light = AppTheme.hex(p.light[keyPath: value], alpha), dark = AppTheme.hex(p.dark[keyPath: value], alpha)
        if light == dark { return Color(nsColor: light) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

extension AppTheme {
    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}

/// Behind every window: the theme's page colour with a soft glow of its accent in one corner and its success colour
/// in the other, so dark themes read as depth rather than flat black.
struct WindowBackdrop: View {
    var body: some View {
        let theme = ThemeStore.shared
        let t = theme.current
        ZStack {
            Color.parchment
            RadialGradient(colors: [Color(nsColor: AppTheme.hex(t.glow, t.isDark ? 0.22 : 0.10)), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color(nsColor: AppTheme.hex(t.success, t.isDark ? 0.08 : 0.04)), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// Settings → Görünüm: pick a theme, see it.
struct ThemePicker: View {
    private let store = ThemeStore.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            swatch(id: ThemeStore.autoID, name: "Otomatik", subtitle: "macOS’a göre", light: .daylight, dark: .night)
            ForEach(AppTheme.all) { t in swatch(id: t.id, name: t.name, subtitle: t.isDark ? "Koyu" : "Açık", light: t, dark: t) }
        }
    }

    private func swatch(id: String, name: String, subtitle: String, light: AppTheme, dark: AppTheme) -> some View {
        let selected = store.selectedID == id
        return Button { withAnimation(Motion.gentle) { store.selectedID = id } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    preview(light)
                    if light != dark { preview(dark) }
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.callout.weight(.semibold))
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentInk : .secondary)
                }
            }
            .padding(8)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentInk : Color.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func preview(_ t: AppTheme) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: AppTheme.hex(t.page))
            RadialGradient(colors: [Color(nsColor: AppTheme.hex(t.glow, 0.35)), .clear], center: .topLeading, startRadius: 0, endRadius: 80)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: AppTheme.hex(t.surface))).frame(width: 52, height: 14)
                Capsule().fill(LinearGradient(colors: [Color(nsColor: AppTheme.hex(t.gradient.0)), Color(nsColor: AppTheme.hex(t.gradient.1))],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: 40, height: 10)
            }
            .padding(8)
        }
    }
}
