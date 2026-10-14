import SigilCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Genel", systemImage: "gearshape") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            KeySettings().tabItem { Label("Anahtarlar", systemImage: "key") }
            UpdateSettings(updater: updater).tabItem { Label("Güncellemeler", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 380)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var loginItemOn = LoginItem.isEnabled
    @State private var notificationsOn = false
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Mac açılınca başlat", isOn: Binding(get: { loginItemOn }, set: { on in
                do { try LoginItem.set(on); error = nil } catch { self.error = error.localizedDescription }
                loginItemOn = LoginItem.isEnabled
            }))
            .disabled(!Platform.isBundled)
            if LoginItem.needsApproval {
                Text("Sistem Ayarları → Genel → Giriş Öğeleri’nden onay ver.").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Menü çubuğunda göster", isOn: $showMenuBarIcon)
            LabeledContent("Bildirimler") {
                if notificationsOn {
                    Text("Açık").foregroundStyle(.green)
                } else {
                    Button("İzin Ver") { Task { notificationsOn = await Notifier.requestPermission() } }
                        .disabled(!Platform.isBundled)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Pencereyi kapatınca uygulama menü çubuğunda çalışmaya devam eder; çıkmak için menüdeki güç düğmesini kullan.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { notificationsOn = await Notifier.authorized() }
    }
}

private struct TerminalSettings: View {
    @AppStorage("terminalApp") private var terminalApp = TerminalApp.preferred.rawValue

    var body: some View {
        Form {
            Picker("Bağlanınca aç", selection: $terminalApp) {
                ForEach(TerminalApp.allCases) { app in
                    Text(app.isAvailable ? app.title : "\(app.title) (kurulu değil)").tag(app.rawValue)
                        .disabled(!app.isAvailable)
                }
            }
            Text("Uygulama içi terminal sekmeli çalışır: sunucular arasında tek tıkla ya da ⌘1…9 ile geçersin. Dış terminaller kendi pencerelerinde açılır.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Kısayollar") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("⌘T bağlan · ⌘J terminaller · ⌘0 genel bakış")
                    Text("⇧⌘] / ⇧⌘[ sekme değiştir · ⇧⌘W sekmeyi kapat")
                }
                .font(.caption.monospaced())
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeySettings: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @AppStorage("defaultKeyStore") private var defaultKeyStore = KeyStoreKind.preferredDefault.rawValue
    @AppStorage("defaultRotationDays") private var defaultRotationDays = 30

    var body: some View {
        Form {
            Picker("Yeni sunucularda anahtar deposu", selection: $defaultKeyStore) {
                ForEach(KeyStoreKind.available) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            Picker("Varsayılan yenileme", selection: $defaultRotationDays) {
                ForEach(RotationChoice.all, id: \.days) { Text($0.label).tag($0.days) }
            }
            LabeledContent("1Password") {
                HStack {
                    Image(systemName: model.onePasswordStatus.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.onePasswordStatus.isReady ? .green : .orange)
                    Text(model.onePasswordStatus.isReady ? "Hazır" : "Kurulum eksik")
                    Button("Kurulumu Aç") { router.showingSetup = true; openWindow(id: "main") }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshOnePasswordStatus() }
    }
}

private struct UpdateSettings: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Form {
            LabeledContent("Sürüm", value: Platform.version)
            if updater.isAvailable {
                Toggle("Güncellemeleri otomatik denetle", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }
                ))
                CheckForUpdatesButton(updater: updater)
            } else {
                Text("Bu derlemede güncelleme kanalı yapılandırılmamış (geliştirme sürümü).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

enum RotationChoice {
    static let all: [(label: String, days: Int)] = [
        ("Kapalı", 0), ("7 günde bir", 7), ("30 günde bir", 30), ("60 günde bir", 60), ("90 günde bir", 90), ("180 günde bir", 180),
    ]

    static func label(_ days: Int) -> String {
        all.first { $0.days == days }?.label ?? "\(days) günde bir"
    }
}
