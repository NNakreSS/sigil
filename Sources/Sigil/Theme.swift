import AppKit
import SigilCore
import SwiftUI

// MARK: - Design tokens
//
// Sigil's language: ink, parchment, one accent. Seals are inked onto parchment; everything else stays quiet so the
// sigils carry the identity. Serif for names and headings (the "engraved" voice), monospace for anything a terminal
// would print, the system sans for everything else.

extension Color {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Seal body.
    static let ink = adaptive(light: hex(0x26215C), dark: hex(0x3C3489))
    /// Lines engraved on the seal.
    static let inkLine = adaptive(light: hex(0xEEEDFE), dark: hex(0xEEEDFE))
    static let inkSoft = adaptive(light: hex(0xAFA9EC), dark: hex(0xAFA9EC))
    /// Page.
    static let parchment = adaptive(light: hex(0xF7F4EC), dark: hex(0x1C1B19))
    /// Raised surfaces on the page.
    static let vellum = adaptive(light: hex(0xFFFDF8), dark: hex(0x262522))
    static let hairline = adaptive(light: hex(0x26215C).withAlphaComponent(0.10), dark: NSColor.white.withAlphaComponent(0.09))
    /// The one accent: healthy, verified, go.
    static let verdigris = adaptive(light: hex(0x0F6E56), dark: hex(0x5DCAA5))
    /// Warm alarm instead of stock red.
    static let cinnabar = adaptive(light: hex(0xC2491F), dark: hex(0xF0997B))
    static let amberInk = adaptive(light: hex(0x9A5B0C), dark: hex(0xEF9F27))
    static let accentInk = adaptive(light: hex(0x534AB7), dark: hex(0xAFA9EC))
}

extension Font {
    /// Engraved voice: server names, headings.
    static func engraved(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
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
        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
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

/// Primary call to action: an inked capsule.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(Color.inkLine)
            .background(Color.ink.opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

let trLocale = Locale(identifier: "tr_TR")
