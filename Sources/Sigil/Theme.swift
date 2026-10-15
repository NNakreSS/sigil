import AppKit
import SigilCore
import SwiftUI

// MARK: - Design tokens
//
// Sigil's language: ink, parchment, one accent. Seals are inked onto parchment; everything else stays quiet so the
// sigils carry the identity. Serif for names and headings (the "engraved" voice), monospace for anything a terminal
// would print, the system sans for everything else.

extension Color {
    // Every token follows the chosen app theme (Settings → Görünüm). Reading them in a view body makes SwiftUI
    // redraw when the theme changes.

    /// Seal body, primary buttons.
    static var ink: Color { ThemeStore.shared.color(\.brand) }
    /// Text and lines on `ink`.
    static var inkLine: Color { ThemeStore.shared.color(\.onBrand) }
    static var inkSoft: Color { ThemeStore.shared.color(\.soft) }
    /// Page.
    static var parchment: Color { ThemeStore.shared.color(\.page) }
    /// Raised surfaces on the page (glass-like on dark themes).
    static var vellum: Color {
        ThemeStore.shared.color(\.surface, alpha: ThemeStore.shared.current.isDark ? 0.82 : 1)
    }
    static var hairline: Color {
        ThemeStore.shared.current.isDark ? Color.white.opacity(0.09) : ThemeStore.shared.color(\.brand, alpha: 0.10)
    }
    /// Healthy, verified, go.
    static var verdigris: Color { ThemeStore.shared.color(\.success) }
    /// Alarm.
    static var cinnabar: Color { ThemeStore.shared.color(\.danger) }
    static var amberInk: Color { ThemeStore.shared.color(\.warning) }
    static var accentInk: Color { ThemeStore.shared.color(\.accent) }

    /// The call-to-action gradient.
    static var brandGradient: LinearGradient {
        let t = ThemeStore.shared.current
        return LinearGradient(colors: [Color(nsColor: AppTheme.hex(t.gradient.0)), Color(nsColor: AppTheme.hex(t.gradient.1))],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Font {
    /// Engraved voice: server names, headings.
    static func engraved(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: ThemeStore.shared.current.headingDesign)
    }
    static let terminal = Font.system(.body, design: .monospaced)
    static let terminalSmall = Font.system(.caption, design: .monospaced)
}

enum Motion {
    /// The seal settling after being pressed.
    static let stamp = Animation.spring(response: 0.42, dampingFraction: 0.62)
    /// A sigil re-forming into a new key.
    static let morph = Animation.spring(response: 0.75, dampingFraction: 0.58)
    static let quick = Animation.snappy(duration: 0.22)
    static let gentle = Animation.easeInOut(duration: 0.35)
}

enum Haptics {
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func success() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}

// MARK: - Status

enum ServerStatusStyle {
    static func color(_ reachable: Bool?) -> Color {
        switch reachable {
        case .some(true): return .verdigris
        case .some(false): return .cinnabar
        case .none: return .secondary
        }
    }

    static func text(_ reachable: Bool?) -> String {
        switch reachable {
        case .some(true): return "Ulaşılabilir"
        case .some(false): return "Ulaşılamıyor"
        case .none: return "Denetlenmedi"
        }
    }

    static func symbol(_ reachable: Bool?) -> String {
        switch reachable {
        case .some(true): return "checkmark.seal.fill"
        case .some(false): return "exclamationmark.octagon.fill"
        case .none: return "questionmark.circle"
        }
    }
}

extension KeyStoreKind {
    var symbol: String {
        switch self {
        case .onePassword: return "lock.shield.fill"
        case .keychain: return "key.horizontal.fill"
        case .secureEnclave: return "touchid"
        }
    }
    var tint: Color {
        switch self {
        case .onePassword: return .accentInk
        case .keychain: return .amberInk
        case .secureEnclave: return .verdigris
        }
    }
    /// What the approval prompt will look like, so a system name in it does not come as a surprise.
    var promptNote: String? {
        switch self {
        case .secureEnclave:
            return "Touch ID penceresinde istekte bulunan olarak “ctkcard” yazar: bu, anahtarı Secure Enclave’de tutan macOS servisidir."
        case .onePassword, .keychain:
            return nil
        }
    }

    var explanation: String {
        switch self {
        case .secureEnclave:
            return "Anahtar Mac’in güvenlik çipinde üretilir; hiçbir şekilde dışarı çıkarılamaz. Giriş Touch ID ister, Terminal’den bile; onay bir süre geçerli kalır (Ayarlar’dan değiştirilir), ekran kilitlenince biter. Sigil bu sunuculara arka planda hiç bağlanmaz."
        case .onePassword:
            return "Anahtar 1Password’de üretilir, hiç diske yazılmaz. Her kullanım Touch ID ile onaylanır; yenileme onay ister."
        case .keychain:
            return "Anahtar bu Mac’te şifreli dosyada durur, parolası Keychain’de. Yenileme tamamen kendiliğinden."
        }
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title).font(.engraved(15))
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Color.accentInk)
            }
            content
        }
        .padding(18)
        // Fills the height it is offered, so cards side by side (with a fixed-size row) come out equally tall.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(cornerRadius: 16)
    }
}

struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

extension InfoRow where Value == Text {
    init(_ label: String, _ text: String) {
        self.label = label
        self.value = Text(text)
    }
}

struct Chip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()   // never wraps, so chips in a row share one height
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Pressable surface with a soft press-in and hover lift: the house style for large tappable things.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (hovering ? 1.01 : 1)))
                .animation(Motion.quick, value: configuration.isPressed)
                .animation(Motion.quick, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Primary call to action: the theme's gradient, with a soft glow on dark themes.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = ThemeStore.shared.current.isDark
        let pressed = configuration.isPressed
        return configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(Color.inkLine)
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)   // text sits in the seal, like an impression
            .background {
                ZStack {
                    Capsule().fill(Color.brandGradient)
                    // Light catching the top edge; gone while pressed, as if the seal were pushed in.
                    Capsule().fill(LinearGradient(colors: [Color.white.opacity(pressed ? 0 : 0.22), .clear],
                                                  startPoint: .top, endPoint: .center))
                    Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), Color.black.opacity(0.15)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .shadow(color: Color.ink.opacity(dark && isEnabled ? (pressed ? 0.2 : 0.4) : 0.15), radius: pressed ? 4 : (dark ? 10 : 5), y: pressed ? 1 : 3)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.965 : 1)
            .animation(Motion.stamp, value: pressed)
    }
}

/// Secondary actions: a quiet glass capsule that lights up its border on hover.
struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.vellum.opacity(configuration.isPressed ? 1 : 0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(hovering ? Color.accentInk.opacity(0.6) : Color.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .animation(Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Raised surface: glass on dark themes (translucent fill, light top edge, soft shadow), paper on light ones.
    func glassSurface(cornerRadius: CGFloat = 14) -> some View {
        let dark = ThemeStore.shared.current.isDark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.vellum, in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.16 : 0.5), Color.hairline],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.06), radius: dark ? 16 : 8, y: dark ? 8 : 3)
    }
}

let trLocale = Locale(identifier: "tr_TR")
