import SwiftUI
import SigilCore

/// Shown where an action needs root and the user is neither root nor has password-less sudo: hands Sigil the sudo
/// password (checked once on the server), optionally kept in the Keychain and opened with Touch ID.
struct SudoUnlockView: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    /// Reload whatever depends on admin rights.
    var onChange: () async -> Void

    @State private var asking = false
    @State private var password = ""
    @State private var remember = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isSudoUnlocked(server.id) {
                HStack(spacing: 8) {
                    Label(model.hasSavedSudo(server.id) ? "Sudo şifresi kullanılıyor (bu Mac’te saklı, Touch ID ile açıldı)"
                          : "Sudo şifresi bu oturumda kullanılıyor", systemImage: "key.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Unut") {
                        model.forgetSudo(server.id)
                        Task { await onChange() }
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            } else {
                Text("“\(server.user)” kullanıcısının sudo’su şifre istiyorsa şifreyi Sigil’e verebilirsin. Şifre sunucuya yalnızca şifreli SSH bağlantısından gider; komut satırında, işlem listesinde ya da günlüklerde görünmez.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if model.hasSavedSudo(server.id) {
                        Button { Task { await openSaved() } } label: { Label("Kayıtlı şifreyle aç", systemImage: "touchid") }
                            .buttonStyle(InkButtonStyle())
                    }
                    if !asking {
                        Button("Sudo şifresini gir…") { asking = true }.buttonStyle(GlassButtonStyle())
                    }
                    if working { ProgressView().controlSize(.small) }
                }
                if asking {
                    HStack(spacing: 8) {
                        SecureField("Sudo şifresi", text: $password).textFieldStyle(.roundedBorder).frame(width: 200)
                            .onSubmit { Task { await unlock() } }
                        Button("Aç") { Task { await unlock() } }.buttonStyle(InkButtonStyle()).disabled(password.isEmpty)
                        Button("Vazgeç") { asking = false; password = "" }.buttonStyle(.borderless)
                    }
                    Toggle("Bu Mac’te hatırla (Keychain’de; açmak için Touch ID ya da Mac şifresi)", isOn: $remember).font(.caption)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.cinnabar)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(working)
    }

    private func unlock() async {
        guard !password.isEmpty else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.unlockSudo(server.id, password: password, remember: remember)
            password = ""
            asking = false
            await onChange()
        } catch { self.error = error.localizedDescription }
    }

    private func openSaved() async {
        working = true
        error = nil
        defer { working = false }
        do {
            if try await model.unlockSavedSudo(server.id) { await onChange() }
        } catch { self.error = error.localizedDescription }
    }
}
