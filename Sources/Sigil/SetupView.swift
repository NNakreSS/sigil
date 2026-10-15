import SigilCore
import SwiftUI

/// First-run setup (also reachable from Settings): where keys live, the 1Password checklist,
/// notifications and open-at-login.
struct SetupView: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultKeyStore") private var defaultKeyStore = KeyStoreKind.preferredDefault.rawValue
    @AppStorage("onboardingDone") private var onboardingDone = false

    @State private var notificationsOn = false
    @State private var loginItemOn = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var checking = false
    @State private var justInstalled = UserDefaults.standard.bool(forKey: Installer.justInstalledKey)

    private var store: KeyStoreKind { KeyStoreKind(rawValue: defaultKeyStore) ?? .preferredDefault }
    private var status: OnePasswordStatus { model.onePasswordStatus }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    LivingSigil(size: 58)
                    if justInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(Color.verdigris)
                            .background(Circle().fill(Color.parchment).padding(2))
                            .offset(x: 6, y: 6)
                            .stampIn()
                    }
                }
                .stampIn()
                VStack(alignment: .leading, spacing: 2) {
                    Text(justInstalled ? "Sigil kuruldu" : "Sigil’e hoş geldin").font(.engraved(24, weight: .bold))
                    Text("Her sunucuna kendi mührü: şifresiz, güvenli ve kendiliğinden yenilenen bir anahtar.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "Anahtarlar nerede saklansın?") {
                        VStack(spacing: 10) {
                            ForEach(KeyStoreKind.available) { kind in storeOption(kind) }
                        }
                    }

                    if store == .onePassword {
                        step(2, "1Password kurulumu") {
                            VStack(alignment: .leading, spacing: 10) {
                                check(status.appInstalled, "1Password uygulaması",
                                      fix: "1Password for Mac’i kur.", action: ("İndir", { Links.openURL("https://1password.com/downloads/mac") }))
                                check(status.cliPath != nil, "1Password CLI (op)" + (status.cliVersion.map { " · \($0)" } ?? ""),
                                      fix: "Terminalde çalıştır:", command: "brew install 1password-cli")
                                check(status.cliIntegrationWorks == true, "CLI entegrasyonu",
                                      fix: status.cliIntegrationWorks == nil
                                          ? "1Password → Settings → Developer → “Integrate with 1Password CLI”. Sonra “Kontrol Et”e bas; 1Password, Sigil’in op aracına izin vermeni ister."
                                          : "1Password → Settings → Developer → “Integrate with 1Password CLI”.",
                                      action: ("1Password’ü Aç", Links.open1Password))
                                check(status.agentRunning, "SSH Agent",
                                      fix: "1Password → Settings → Developer → “Use the SSH Agent”.",
                                      action: ("1Password’ü Aç", Links.open1Password))
                                HStack {
                                    Button {
                                        Task { checking = true; await model.refreshOnePasswordStatus(verifyIntegration: true); checking = false }
                                    } label: {
                                        if checking { ProgressView().controlSize(.small) } else { Label("Kontrol Et", systemImage: "arrow.clockwise") }
                                    }
                                    if status.isReady && status.cliIntegrationWorks == true {
                                        Label("Hazır", systemImage: "checkmark.seal.fill").foregroundStyle(Color.verdigris)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }

                    step(store == .onePassword ? 3 : 2, "Arka planda çalışma") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(get: { loginItemOn }, set: setLoginItem)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac açılınca başlat")
                                    Text("Menü çubuğunda çalışır; durum denetimleri ve otomatik yenilemeler pencere kapalıyken de sürer.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!Platform.isBundled)
                            if let loginItemError { Text(loginItemError).font(.caption).foregroundStyle(.red) }

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bildirimler")
                                    Text("Sunucu düşerse, yenileme başarısız olursa ya da onay gerekirse haber verir.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if notificationsOn {
                                    Label("Açık", systemImage: "checkmark.circle.fill").foregroundStyle(Color.verdigris)
                                } else {
                                    Button("İzin Ver") { Task { notificationsOn = await Notifier.requestPermission() } }
                                        .disabled(!Platform.isBundled)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                if store == .onePassword && !status.isReady {
                    Text("1Password hazır olmadan da başlayabilirsin; o zaman yeni sunucular \(KeyStoreKind.usable(.onePassword, onePasswordReady: false).title) kullanır.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Başla") {
                    onboardingDone = true
                    UserDefaults.standard.removeObject(forKey: Installer.justInstalledKey)
                    Haptics.success()
                    dismiss()
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 660)
        .background(Color.parchment)
        .animation(Motion.gentle, value: status)
        .animation(Motion.gentle, value: defaultKeyStore)
        .task {
            notificationsOn = await Notifier.authorized()
            // Keep the checklist live while the user flips switches in 1Password.
            while !Task.isCancelled && !status.isReady && store == .onePassword {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await model.refreshOnePasswordStatus()
            }
        }
    }

    // MARK: Pieces

    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(n)")
                    .font(.callout.bold()).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.ink))
                Text(title).font(.engraved(16))
            }
            content().padding(.leading, 34)
        }
    }

    private func storeOption(_ kind: KeyStoreKind) -> some View {
        let selected = store == kind
        return Button {
            defaultKeyStore = kind.rawValue
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.symbol).font(.title2).foregroundStyle(kind.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(kind.title).font(.engraved(16))
                        if kind == .preferredDefault { Chip(text: "Önerilen", systemImage: "star.fill", tint: .accentInk) }
                    }
                    Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentInk : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentInk : Color.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .animation(Motion.quick, value: selected)
        }
        .buttonStyle(PressableStyle())
    }

    private func check(_ ok: Bool, _ title: String, fix: String, command: String? = nil,
                       action: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.verdigris : Color.amberInk)
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.stamp, value: ok)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                if !ok {
                    Text(fix).font(.caption).foregroundStyle(.secondary)
                    if let command {
                        HStack(spacing: 6) {
                            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            Button { Links.copy(command) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Kopyala")
                        }
                    }
                }
            }
            Spacer()
            if !ok, let action {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItemOn = LoginItem.isEnabled
            loginItemError = LoginItem.needsApproval ? "Sistem Ayarları → Genel → Giriş Öğeleri’nden onay ver." : nil
        } catch {
            loginItemError = error.localizedDescription
            loginItemOn = LoginItem.isEnabled
        }
    }
}
