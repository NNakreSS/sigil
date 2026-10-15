import Security
import SigilCore
import SwiftUI

/// Which assistant the terminal uses, and the user's own API keys (kept in the Keychain, never on disk).
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
    var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "assistantGeminiModel") }
    }
    /// Models the saved Gemini key can use (fetched from Google once the key is saved).
    var geminiModels: [String] = []
    private(set) var savedKeys: Set<AssistantProvider> = []

    private init() {
        let d = UserDefaults.standard
        let saved = AssistantProvider(rawValue: d.string(forKey: "assistantProvider") ?? "")
        provider = saved ?? (AssistantProvider.onDeviceAvailable ? .onDevice : .off)
        claudeModel = d.string(forKey: "assistantClaudeModel") ?? ClaudeAssistant.models[0].id
        geminiModel = d.string(forKey: "assistantGeminiModel") ?? GeminiAssistant.defaultModel
        savedKeys = Set([AssistantProvider.claude, .gemini].filter { Self.readKey($0) != nil })
    }

    func hasKey(_ p: AssistantProvider) -> Bool { savedKeys.contains(p) }

    var isEnabled: Bool {
        switch provider {
        case .off: return false
        case .onDevice: return AssistantProvider.onDeviceAvailable
        case .claude, .gemini: return hasKey(provider)
        }
    }

    /// Short label shown next to every answer, so it is clear where it came from.
    var sourceLabel: String {
        switch provider {
        case .claude: return "Claude · isteğin ve sunucunun işletim sistemi Anthropic’e gönderildi"
        case .gemini: return "Gemini · isteğin ve sunucunun işletim sistemi Google’a gönderildi"
        case .onDevice, .off: return "Cihaz içi model · Mac’ten hiçbir şey çıkmadı"
        }
    }

    /// The row in the palette that asks the assistant.
    var askSubtitle: String {
        switch provider {
        case .claude: return "Claude bir komut önerir"
        case .gemini: return "Gemini bir komut önerir"
        case .onDevice, .off: return "Cihaz içi model bir komut önerir; Mac’ten bir şey çıkmaz"
        }
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
            return Self.readKey(.claude).map { ClaudeAssistant(apiKey: $0, model: claudeModel) }
        case .gemini:
            return Self.readKey(.gemini).map { GeminiAssistant(apiKey: $0, model: geminiModel) }
        }
    }

    func saveKey(_ key: String, for p: AssistantProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service(p),
                                   kSecAttrAccount as String: "default"]
        SecItemDelete(base as CFDictionary)
        if !trimmed.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
        if Self.readKey(p) != nil { savedKeys.insert(p) } else { savedKeys.remove(p) }
        if p == .gemini { geminiModels = [] }
    }

    /// Asks Google which models the saved key may use; keeps the current choice if it is among them.
    func refreshGeminiModels() async throws {
        guard let key = Self.readKey(.gemini) else { return }
        let models = try await GeminiAssistant(apiKey: key).availableModels()
        geminiModels = models
        if !models.isEmpty, !models.contains(geminiModel) {
            geminiModel = models.first { $0 == GeminiAssistant.defaultModel } ?? models.first { $0.contains("flash") } ?? models[0]
        }
    }

    private static func service(_ p: AssistantProvider) -> String {
        p == .claude ? "com.nakres.sigil.claude-api" : "com.nakres.sigil.\(p.rawValue)-api"
    }

    private static func readKey(_ p: AssistantProvider) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(p),
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
    @State private var modelError: String?
    @State private var loadingModels = false
    private let settings = AssistantSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section("Kod yardımı") {
            Picker("Öneriler", selection: $settings.provider) {
                ForEach(AssistantProvider.allCases) { p in
                    Text(p == .onDevice && !AssistantProvider.onDeviceAvailable ? "\(p.title) (kullanılamıyor)" : p.title).tag(p)
                }
            }
            .onChange(of: settings.provider) { _, _ in keyDraft = ""; modelError = nil }
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
                keyRow(.claude, placeholder: "sk-ant-…")
                Text("Anahtar yalnızca bu Mac’in Keychain’inde durur. Bir öneri istediğinde Anthropic’e yalnızca isteğin (ya da seçtiğin terminal metni) ve sunucunun işletim sistemi ile kurulu araçların listesi gider; sunucu adresi, kullanıcı ve anahtarlar gitmez.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .gemini:
                keyRow(.gemini, placeholder: "AIza…")
                if settings.hasKey(.gemini) {
                    LabeledContent("Model") {
                        HStack {
                            if settings.geminiModels.isEmpty {
                                TextField("gemini-2.5-flash", text: $settings.geminiModel).frame(width: 200).font(.terminalSmall)
                            } else {
                                Picker("", selection: $settings.geminiModel) {
                                    ForEach(settings.geminiModels, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden().frame(width: 240)
                            }
                            Button { Task { await loadModels() } } label: {
                                if loadingModels { ProgressView().controlSize(.small) } else { Text("Modelleri getir") }
                            }
                        }
                    }
                    if let modelError { Text(modelError).font(.caption).foregroundStyle(Color.cinnabar) }
                }
                Text("Anahtar yalnızca bu Mac’in Keychain’inde durur ve istek başlığında gönderilir. Bir öneri istediğinde Google’a yalnızca isteğin (ya da seçtiğin terminal metni) ve sunucunun işletim sistemi ile kurulu araçların listesi gider. Dikkat: ücretsiz Gemini API katmanında Google gönderilenleri ürünlerini geliştirmek için kullanabilir; ücretli katmanda kullanmaz.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: settings.provider) {
            if settings.provider == .gemini, settings.hasKey(.gemini), settings.geminiModels.isEmpty { await loadModels() }
        }
    }

    private func keyRow(_ p: AssistantProvider, placeholder: String) -> some View {
        LabeledContent("API anahtarı") {
            HStack {
                SecureField(settings.hasKey(p) ? "Kayıtlı (değiştirmek için yenisini yaz)" : placeholder, text: $keyDraft)
                    .frame(width: 240)
                Button("Kaydet") {
                    settings.saveKey(keyDraft, for: p)
                    keyDraft = ""
                    if p == .gemini { Task { await loadModels() } }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasKey(p) {
                    Button("Sil", role: .destructive) { settings.saveKey("", for: p) }
                }
            }
        }
    }

    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            try await settings.refreshGeminiModels()
            modelError = nil
        } catch { modelError = error.localizedDescription }
    }
}
