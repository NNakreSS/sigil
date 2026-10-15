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
    var help: HelpTopic? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label {
                    Text(title).font(.engraved(15))
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(Color.accentInk)
                }
                if let help { HelpButton(topic: help) }
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

/// A small (?) next to a title: hover for a one-line hint, click for what it is and how to use it.
struct HelpButton: View {
    let topic: HelpTopic
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(topic.hint)
        .accessibilityLabel("\(topic.title) hakkında")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label(topic.title, systemImage: topic.symbol).font(.engraved(15)).foregroundStyle(Color.accentInk)
                Text(topic.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let example = topic.example {
                    Text(example).font(.caption).foregroundStyle(.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}

/// Plain-language explanations shown behind the (?) buttons, kept in one place.
enum HelpTopic {
    case tunnels, grants, foreignKeys, health, keyAndSeal, connection, logins, events
    case hardening, quickActions, jumpServer, keyStore, rotation, approvalWindow, allowList

    var title: String {
        switch self {
        case .tunnels: return "Tünel nedir?"
        case .grants: return "Erişim vermek"
        case .foreignKeys: return "Sunucudaki anahtarlar"
        case .health: return "Sağlık"
        case .keyAndSeal: return "Mühür ve anahtar"
        case .connection: return "Bağlantı"
        case .logins: return "Sunucudaki son girişler"
        case .events: return "Geçmiş"
        case .hardening: return "Güvenliği güçlendirme"
        case .quickActions: return "Hızlı eylemler"
        case .jumpServer: return "Üzerinden bağlanmak"
        case .keyStore: return "Anahtar nerede durur?"
        case .rotation: return "Anahtar yenileme"
        case .approvalWindow: return "Onay ne kadar geçerli?"
        case .allowList: return "SSH izin listesi"
        }
    }

    var symbol: String {
        switch self {
        case .tunnels: return "point.topleft.down.to.point.bottomright.curvepath"
        case .grants: return "person.badge.key"
        case .foreignKeys: return "key.viewfinder"
        case .health: return "waveform.path.ecg"
        case .keyAndSeal: return "seal"
        case .connection: return "point.3.connected.trianglepath.dotted"
        case .logins: return "person.badge.clock"
        case .events: return "list.bullet.below.rectangle"
        case .hardening: return "lock.shield"
        case .quickActions: return "bolt"
        case .jumpServer: return "arrow.triangle.turn.up.right.diamond"
        case .keyStore: return "key.horizontal"
        case .rotation: return "arrow.triangle.2.circlepath"
        case .approvalWindow: return "touchid"
        case .allowList: return "network.badge.shield.half.filled"
        }
    }

    /// One line for the hover tooltip.
    var hint: String {
        switch self {
        case .tunnels: return "Sunucudaki bir servisi, internete açmadan Mac’ine getirir."
        case .grants: return "Bir başkasına kendi anahtarıyla, şifre paylaşmadan giriş izni ver."
        case .foreignKeys: return "Sunucuya Sigil dışından eklenmiş anahtarlar."
        case .health: return "Disk, bellek, güncellemeler ve çöken servisler; sunucuda hiçbir şeyi değiştirmez."
        case .keyAndSeal: return "Bu sunucuya özel anahtar ve ondan üretilen mühür."
        case .connection: return "Adres ve son denetimin ne zaman yapıldığı."
        case .logins: return "Sunucunun kendi tuttuğu giriş kaydı (last)."
        case .events: return "Sigil’in bu sunucuda yaptığı her şey."
        case .hardening: return "Saldırılara karşı sunucunun ayarlarını sıkılaştırır; hata olursa kendini geri alır."
        case .quickActions: return "Kayıtlı bir komutu birden çok sunucuda aynı anda çalıştırır."
        case .jumpServer: return "Bu sunucuya yalnızca başka bir sunucunun içinden erişiliyorsa."
        case .keyStore: return "Gizli anahtarın tutulacağı yer."
        case .rotation: return "Anahtar düzenli olarak yenilenir; eskisi sunucudan silinir."
        case .approvalWindow: return "Bir Touch ID onayının ne kadar süre geçerli kalacağı."
        case .allowList: return "SSH’a yalnızca izin verdiğin IP adreslerinden bağlanılabilsin."
        }
    }

    var text: String {
        switch self {
        case .tunnels:
            return "Sunucundaki bazı servisler (veritabanı, Redis, yönetim paneli) dışarıya kapalıdır ve öyle kalmalıdır. Tünel, böyle bir servisi şifreli SSH bağlantısı üzerinden kendi Mac’ine getirir: Mac’teki bir porta bağlandığında aslında sunucudaki servise konuşursun. Sunucuda hiçbir port açılmaz; tüneli kapatınca erişim de biter, Sigil kapanınca tüm tüneller kapanır."
        case .grants:
            return "Arkadaşın kendi bilgisayarında bir anahtar üretir ve sana yalnızca açık anahtarını (.pub satırını) gönderir. Sigil bu anahtarı sunucuya, seçtiğin sınırlarla kurar: kendi hesabı ya da seninki, süre (sunucu kendisi uygular), izin verilen IP’ler. Şifre ya da senin anahtarın hiç paylaşılmaz; erişimi tek tıkla geri alırsın."
        case .foreignKeys:
            return "Sunucunun authorized_keys dosyasında, Sigil’in kurmadığı anahtarlar. Bunlar senin eski anahtarların, bir ekip arkadaşınınki ya da hiç tanımadığın biri olabilir. Tanıdıklarını “tanıdık” diye işaretle; tanımadığını kaldır: o anahtarın sahibi bir daha giremez. Bu Mac’teki anahtarlarla eşleşenler ayrıca etiketlenir."
        case .health:
            return "Sigil sunucuya bağlanıp yalnızca okur: disk ve bellek doluluğu, yük, bekleyen güncellemeler (hangileri), çöken servisler (hangileri), yeniden başlatma gerekip gerekmediği ve SSL sertifikalarının bitiş tarihleri. Ölçüm sunucuda hiçbir şeyi değiştirmez. Ayrıca sunucuda hangi araçların kurulu olduğunu da öğrenir; ⌘P komut listesi buna göre daralır."
        case .keyAndSeal:
            return "Bu sunucuya girmek için kullanılan anahtar yalnızca bu sunucuya özeldir; başka bir sunucunun anahtarı ele geçse bile buraya giremez. Mühür, anahtarın parmak izinden çizilir: anahtar yenilenince mühür de biçim değiştirir, aynı anahtar hep aynı mührü verir."
        case .connection:
            return "Sunucunun adresi, Sigil’in bağlandığı kullanıcı ve sunucuya en son ne zaman bağlanılabildiği. Secure Enclave sunucularına Sigil arka planda hiç bağlanmaz; durum yalnızca sen istediğinde denetlenir."
        case .logins:
            return "Sunucunun kendi kaydı (last komutu): kim, nereden, ne zaman girdi. Sigil dışından, başka bilgisayarlardan yapılan girişler de burada görünür; tanımadığın bir IP görürsen anahtarları yenile."
        case .events:
            return "Bu sunucuda Sigil’in yaptığı her şeyin kaydı: eklenme, anahtar yenileme, güvenlik güçlendirme, erişim verme, uyarılar. Kayıtlar yalnızca bu Mac’te tutulur."
        case .hardening:
            return "Şifreli girişi ve root ile şifreli girişi kapatır, güvenlik duvarını (ufw) ve kaba kuvvet korumasını (fail2ban) kurar, otomatik güvenlik güncellemelerini açar. Girişi etkileyen her değişiklik sunucuda bir bekçiyle uygulanır: Sigil 45 saniye içinde yeni bir bağlantıyla doğrulayamazsa sunucu değişikliği kendisi geri alır, yani dışarıda kalmazsın."
        case .quickActions:
            return "Sık kullandığın komutları (disk durumu, servis yeniden başlatma…) kaydedip seçtiğin sunucularda aynı anda çalıştırır; her sunucunun çıktısı ayrı gösterilir. Kayıtlı komutlar terminaldeki ⌘P paletinde de çıkar."
        case .jumpServer:
            return "Bazı sunucular internete kapalıdır ve yalnızca bir “bastion” sunucusunun içinden erişilir. Buradan o sunucuyu seçersen Sigil önce ona bağlanır, oradan bu sunucuya geçer (ProxyJump). Doğrudan erişilebiliyorsa “Doğrudan” bırak."
        case .keyStore:
            return "Secure Enclave: anahtar Mac’in güvenlik çipinde, dışarı çıkarılamaz; girişte Touch ID ister. 1Password: anahtar 1Password’de durur, kullanımda onay ister. Keychain: anahtar bu Mac’te şifreli dosyada durur, hiç sormaz ama Mac’in kilidi açıkken herkes kullanabilir."
        case .rotation:
            return "Anahtar seçtiğin aralıkla yenilenir: önce yeni anahtar kurulur, yeni anahtarla giriş denenir, ancak o zaman eskisi sunucudan silinir; dışarıda kalma riski yoktur. Secure Enclave ve 1Password anahtarları onayın gerektiği için sen “Yeni mühür bas”a basınca yenilenir."
        case .allowList:
            return "Sunucunun SSH portuna normalde internetteki herkes bağlanmayı deneyebilir; loglardaki binlerce şifre denemesi buradan gelir. İzin listesi açıkken güvenlik duvarı (ufw) yalnızca listedeki adreslerin bağlanmasına izin verir; diğerleri kapıya bile ulaşamaz. Web gibi diğer servisler etkilenmez. Sigil bu Mac’in adresini kendisi bulur ve listede olmadan uygulamaz; uyguladıktan sonra 45 saniye içinde yeni bir bağlantıyla giremezse sunucu eski kurallara döner."
        case .approvalWindow:
            return "Secure Enclave ve 1Password anahtarları kullanımda onay ister. Bir onaydan sonra, seçtiğin süre boyunca aynı sunucuya açılan bağlantılar tekrar sormaz. Ekran kilitlenince, Mac uyuyunca ya da Sigil kapanınca hemen sona erer; menü çubuğundaki kilitle de anında kapatabilirsin."
        }
    }

    var example: String? {
        switch self {
        case .tunnels: return "Örnek: Mac’te 15432 → sunucuda 5432. TablePlus ile localhost:15432’ye bağlanırsın, sunucudaki PostgreSQL’e konuşursun."
        case .grants: return "Arkadaşın şunu çalıştırıp çıkan satırı gönderir:\nssh-keygen -t ed25519\ncat ~/.ssh/id_ed25519.pub"
        case .quickActions: return "Örnek: “Disk durumu” (df -h /) eylemini tüm production sunucularında tek tıkla çalıştır."
        case .allowList: return "Dikkat: ev internetinde IP değişebilir. Değişirse girmek için sağlayıcının web konsolundan “ufw disable” demen gerekir; mümkünse sabit bir IP ya da VPN adresi de ekle."
        default: return nil
        }
    }
}
