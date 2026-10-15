import SigilCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Görünüm", systemImage: "paintpalette") }
            GeneralSettings().tabItem { Label("Genel", systemImage: "gearshape") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            KeySettings().tabItem { Label("Anahtarlar", systemImage: "key") }
            UpdateSettings(updater: updater).tabItem { Label("Güncellemeler", systemImage: "arrow.down.circle") }
        }
        .frame(width: 620, height: 560)
    }
}

private struct AppearanceSettings: View {
    var body: some View {
        Form {
            Section {
                ThemePicker().padding(.vertical, 6)
            } header: {
                Text("Tema")
            } footer: {
                Text("Tüm pencerelere anında uygulanır. Terminalin kendi renkleri Terminal sekmesinden ayrıca seçilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WindowBackdrop())
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
    @Environment(AppRouter.self) private var router
    @AppStorage("terminalApp") private var terminalApp = TerminalApp.preferred.rawValue
    private let appearance = TerminalAppearance.shared

    var body: some View {
        @Bindable var appearance = appearance
        @Bindable var terminals = router.terminals
        Form {
            Section {
                Picker("Bağlanınca aç", selection: $terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.isAvailable ? app.title : "\(app.title) (kurulu değil)").tag(app.rawValue)
                            .disabled(!app.isAvailable)
                    }
                }
            }

            Section("Görünüm") {
                TerminalPreview(fontSize: terminals.fontSize)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    PaletteSwatch(palette: TerminalPalette.matching(ThemeStore.shared.current),
                                  selected: appearance.paletteID == TerminalPalette.appID) { appearance.paletteID = TerminalPalette.appID }
                    ForEach(TerminalPalette.all) { p in
                        PaletteSwatch(palette: p, selected: p.id == appearance.paletteID) { appearance.paletteID = p.id }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Yazı") {
                Picker("Yazı tipi", selection: $appearance.fontFamily) {
                    Text("Sistem (SF Mono)").tag("")
                    Divider()
                    ForEach(TerminalAppearance.monospacedFamilies, id: \.self) { Text($0).font(.custom($0, size: 12)).tag($0) }
                }
                LabeledContent("Boyut") {
                    HStack {
                        Slider(value: $terminals.fontSize, in: 9...24, step: 1).frame(width: 200)
                        Text("\(Int(terminals.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("İmleç ve klavye") {
                Picker("İmleç", selection: $appearance.cursor) {
                    ForEach(TerminalAppearance.Cursor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("İmleç yanıp sönsün", isOn: $appearance.cursorBlinks)
                Toggle("⌥ tuşu Meta olarak çalışsın", isOn: $appearance.optionAsMeta)
                Text("Açıkken ⌥B / ⌥F gibi kabuk kısayolları çalışır, ama ⌥ ile yazılan @ € gibi karakterler yazılamaz.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Yazarken komut öner, Tab ile tamamla", isOn: $appearance.suggestions)
            }

            AssistantSettingsSection()

            Section("Kısayollar") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("⌘P komut paleti · ⇧⌘E seçili metni açıkla · ⌘F bul · ⌘G sonraki · ⌥⌘K temizle")
                    Text("⌘+ / ⌘- yazı boyutu · ⌥⌘0 sıfırla · ⌘D yan yana böl · ⇧⌘D birleştir")
                    Text("⌘T bağlan · ⌘J terminaller · ⌘0 genel bakış · ⌘1…9 sekmeler")
                }
                .font(.caption.monospaced())
            }
        }
        .formStyle(.grouped)
    }
}

/// A few lines of a shell session in the chosen palette, font and size.
private struct TerminalPreview: View {
    let fontSize: CGFloat

    var body: some View {
        let a = TerminalAppearance.shared
        let p = a.palette
        let c = { (i: Int) in Color(nsColor: TerminalPalette.color(p.ansi[i])) }
        let font = Font(a.font(size: fontSize))
        VStack(alignment: .leading, spacing: 2) {
            (Text("root@sunucu").foregroundColor(c(2)) + Text(":").foregroundColor(c(7)) + Text("~").foregroundColor(c(4))
             + Text("# ").foregroundColor(c(7)) + Text("systemctl status nginx").foregroundColor(Color(nsColor: TerminalPalette.color(p.foreground))))
            (Text("● ").foregroundColor(c(10)) + Text("nginx.service").foregroundColor(Color(nsColor: TerminalPalette.color(p.foreground)))
             + Text(" — active (running)").foregroundColor(c(2)))
            (Text("uyarı: ").foregroundColor(c(3)) + Text("disk %91 dolu").foregroundColor(c(1)))
            HStack(spacing: 0) {
                Text("root@sunucu:~# ").foregroundColor(c(2))
                Rectangle().fill(Color(nsColor: TerminalPalette.color(p.cursor)))
                    .frame(width: a.cursor == .bar ? 2 : fontSize * 0.6, height: a.cursor == .underline ? 2 : fontSize * 1.15)
                    .frame(height: fontSize * 1.15, alignment: .bottom)
            }
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: TerminalPalette.color(p.background)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PaletteSwatch: View {
    let palette: TerminalPalette
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                        Circle().fill(Color(nsColor: TerminalPalette.color(palette.ansi[i]))).frame(width: 9, height: 9)
                    }
                }
                Text(palette.name).font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: TerminalPalette.color(palette.foreground)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: TerminalPalette.color(palette.background)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentInk : Color.hairline, lineWidth: selected ? 2.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct KeySettings: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @AppStorage("defaultKeyStore") private var defaultKeyStore = KeyStoreKind.preferredDefault.rawValue
    @AppStorage("defaultRotationDays") private var defaultRotationDays = 30
    @AppStorage("approvalWindowMinutes") private var approvalWindow = 15

    var body: some View {
        Form {
            Picker("Yeni sunucularda anahtar deposu", selection: $defaultKeyStore) {
                ForEach(KeyStoreKind.available) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            Picker("Varsayılan yenileme", selection: $defaultRotationDays) {
                ForEach(RotationChoice.all, id: \.days) { Text($0.label).tag($0.days) }
            }
            Picker(selection: $approvalWindow) {
                Text("Her bağlantıda sor").tag(0)
                Text("5 dakika").tag(5)
                Text("15 dakika").tag(15)
                Text("1 saat").tag(60)
            } label: {
                HStack(spacing: 4) { Text("Touch ID onayı geçerli kalsın"); HelpButton(topic: .approvalWindow) }
            }
            .onChange(of: approvalWindow) { _, m in model.approvalWindowMinutes = m }
            Text(approvalWindow == 0
                 ? "Secure Enclave ve 1Password anahtarları her bağlantıda onay ister."
                 : "Bir sunucuya onay verdikten sonra, bu süre boyunca aynı sunucuya açılan bağlantılar (Sigil, terminal sekmeleri, Terminal’den ssh) tekrar sormaz. Ekran kilitlenince, Mac uyuyunca ya da Sigil kapanınca hemen sona erer. Anahtar yenileme ve sertleştirme her zaman yeni bir onay ister.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .task {
            if model.usesOnePassword(defaultStore: KeyStoreKind(rawValue: defaultKeyStore)) { await model.refreshOnePasswordStatus() }
        }
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
