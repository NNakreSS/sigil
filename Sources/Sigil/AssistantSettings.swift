import Security
import SigilCore
import SwiftUI

/// Which assistant the terminal uses, and the user's own Claude key (kept in the Keychain, never on disk).
@MainActor
@Observable
final class AssistantSettings {
    static let shared = AssistantSettings()

    var provider: AssistantProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "assistantProvider") }
    }
    var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "assistantClaudeModel") }
    }
    private(set) var hasClaudeKey: Bool

    private static let service = "com.nakres.sigil.claude-api"

    private init() {
        let d = UserDefaults.standard
        let saved = AssistantProvider(rawValue: d.string(forKey: "assistantProvider") ?? "")
        provider = saved ?? (AssistantProvider.onDeviceAvailable ? .onDevice : .off)
        claudeModel = d.string(forKey: "assistantClaudeModel") ?? ClaudeAssistant.models[0].id
        hasClaudeKey = Self.readKey() != nil
    }

    var isEnabled: Bool {
        switch provider {
        case .off: return false
        case .onDevice: return AssistantProvider.onDeviceAvailable
        case .claude: return hasClaudeKey
        }
    }

    /// Short label shown next to every answer, so it is clear where it came from.
    var sourceLabel: String {
        provider == .claude ? "Claude · isteğin ve sunucunun işletim sistemi Anthropic’e gönderildi" : "Cihaz içi model · Mac’ten hiçbir şey çıkmadı"
    }

    func makeAssistant() -> CommandAssistant? {
        switch provider {
        case .off: return nil
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26, *), AssistantProvider.onDeviceAvailable { return OnDeviceAssistant() }
            #endif
            return nil
        case .claude:
            return Self.readKey().map { ClaudeAssistant(apiKey: $0, model: claudeModel) }
        }
    }

    func saveClaudeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: "default"]
        SecItemDelete(base as CFDictionary)
        if !trimmed.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
        hasClaudeKey = Self.readKey() != nil
    }

    private static func readKey() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "default", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Settings → Terminal → Kod yardımı.
struct AssistantSettingsSection: View {
    @State private var keyDraft = ""
    private let settings = AssistantSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section("Kod yardımı") {
            Picker("Öneriler", selection: $settings.provider) {
                ForEach(AssistantProvider.allCases) { p in
                    Text(p == .onDevice && !AssistantProvider.onDeviceAvailable ? "\(p.title) (kullanılamıyor)" : p.title).tag(p)
                }
            }
            switch settings.provider {
            case .off:
                Text("⌘P yalnızca hazır komut kütüphanesini gösterir.").font(.caption).foregroundStyle(.secondary)
            case .onDevice:
                Text(AssistantProvider.onDeviceAvailable
                     ? "Apple’ın cihaz içi modeli. İsteğin ve seçtiğin metin Mac’ten çıkmaz. Küçük bir model olduğu için önerileri her zaman kontrol et; Sigil emin olamadığı komutları işaretler."
                     : "Apple Intelligence bu Mac’te açık değil: Sistem Ayarları → Apple Intelligence ve Siri.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .claude:
                Picker("Model", selection: $settings.claudeModel) {
                    ForEach(ClaudeAssistant.models, id: \.id) { Text($0.title).tag($0.id) }
                }
                LabeledContent("API anahtarı") {
                    HStack {
                        SecureField(settings.hasClaudeKey ? "Kayıtlı (değiştirmek için yenisini yaz)" : "sk-ant-…", text: $keyDraft)
                            .frame(width: 240)
                        Button("Kaydet") { settings.saveClaudeKey(keyDraft); keyDraft = "" }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if settings.hasClaudeKey {
                            Button("Sil", role: .destructive) { settings.saveClaudeKey("") }
                        }
                    }
                }
                Text("Anahtar yalnızca bu Mac’in Keychain’inde durur. Bir öneri istediğinde Anthropic’e yalnızca isteğin (ya da seçtiğin terminal metni) ve sunucunun işletim sistemi ile kurulu araçların listesi gider; sunucu adresi, kullanıcı ve anahtarlar gitmez.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
