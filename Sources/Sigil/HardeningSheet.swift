import SigilCore
import SwiftUI

struct HardeningSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server

    private enum Phase: Equatable { case loading, review, working, done(String, Bool), failed(String) }
    @State private var phase: Phase = .loading
    @State private var state = HardeningState()
    @State private var plan = HardeningPlan()
    @State private var steps: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SigilMark(geometry: server.sigil, size: 46, busy: phase == .working || phase == .loading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(server.alias) sertleştir").font(.engraved(22, weight: .bold))
                    Text("Erişimi etkileyen her değişiklik doğrulanana kadar geçicidir; doğrulanamazsa sunucu kendiliğinden geri alır.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            switch phase {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Sunucunun güvenlik ayarları okunuyor…") }
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .review:
                review
            case .working:
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(spacing: 10) {
                            if i == steps.count - 1 { ProgressView().controlSize(.small).frame(width: 18) }
                            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.verdigris).frame(width: 18) }
                            Text(step)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.stamp, value: steps.count)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            case .done(let message, let ok):
                VStack(spacing: 12) {
                    Image(systemName: ok ? "checkmark.seal.fill" : "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(ok ? Color.verdigris : Color.amberInk)
                        .stampIn()
                    Text(message).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(isFinal ? "Kapat" : "Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .working)
                if phase == .review {
                    Button("Uygula") { Task { await apply() } }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan.isEmpty || !state.canAdminister)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Color.parchment)
        .interactiveDismissDisabled(phase == .working)
        .animation(Motion.gentle, value: phase)
        .task { await load() }
    }

    private var isFinal: Bool {
        if case .done = phase { return true }
        if case .failed = phase { return true }
        return false
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.canAdminister {
                Label("“\(state.user)” root değil ve şifresiz sudo yetkisi yok. Sigil sadece durumu gösterebilir.", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.callout).foregroundStyle(Color.amberInk)
            }
            if keepsPasswordForRecovery {
                Label("Secure Enclave anahtarı bu Mac’e bağlı: Mac kaybolursa sunucuya şifreyle girebilmen için şifreli giriş varsayılan olarak açık bırakılıyor.",
                      systemImage: "lifepreserver")
                    .font(.caption).foregroundStyle(Color.accentInk).fixedSize(horizontal: false, vertical: true)
            }
            item(isOn: $plan.disablePasswordLogin, done: !state.passwordLoginOpen,
                 title: "Şifreyle girişi kapat",
                 detail: keepsPasswordForRecovery
                     ? "Kapatırsan bu Mac kaybolduğunda sunucuya yalnızca sağlayıcının konsolundan girebilirsin."
                     : "Brute-force denemelerinin hedefi ortadan kalkar. Girişler yalnızca anahtarla olur.",
                 enabled: state.sshdIncludesDropIns)
            item(isOn: $plan.restrictRootLogin, done: !state.rootPasswordLoginOpen,
                 title: state.isRoot ? "Root için şifreyi kapat" : "Root girişini kapat",
                 detail: state.isRoot ? "Sigil root ile bağlandığı için root yalnızca anahtarla girebilir (prohibit-password)."
                                      : "Root ile doğrudan giriş tamamen engellenir; işler sudo ile yapılır.",
                 enabled: state.sshdIncludesDropIns)
            item(isOn: $plan.enableFirewall, done: state.ufw == "active",
                 title: "Firewall’u aç (ufw)",
                 detail: "Yalnızca şu portlar açık kalır: " + Set(plan.firewallPorts + [state.sshPort]).sorted().map(String.init).joined(separator: ", "),
                 enabled: state.isDebianLike)
            item(isOn: $plan.installFail2ban, done: state.fail2ban == "active",
                 title: "fail2ban kur",
                 detail: "Tekrarlayan başarısız girişleri yapan IP’leri geçici olarak engeller.",
                 enabled: state.isDebianLike)
            item(isOn: $plan.enableUnattendedUpgrades, done: state.unattendedUpgrades == "active",
                 title: "Güvenlik güncellemelerini otomatik kur",
                 detail: "unattended-upgrades açılır; yeniden başlatma kararı sende kalır.",
                 enabled: state.isDebianLike)
        }
    }

    private func item(isOn: Binding<Bool>, done: Bool, title: String, detail: String, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if done {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.verdigris).font(.title3).frame(width: 22)
            } else {
                Toggle("", isOn: isOn).labelsHidden().disabled(!enabled || !state.canAdminister).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).fontWeight(.medium)
                    if done { Text("zaten yapılmış").font(.caption).foregroundStyle(Color.verdigris) }
                    else if !enabled { Text("bu sunucuda desteklenmiyor").font(.caption).foregroundStyle(.secondary) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline))
        .opacity(enabled || done ? 1 : 0.55)
    }

    /// Secure Enclave keys cannot be backed up, so the server's password stays the way back in if the Mac is lost.
    private var keepsPasswordForRecovery: Bool { server.store == .secureEnclave }

    private func load() async {
        do {
            state = try await model.hardeningState(server.id)
            // Keep public services reachable when the firewall goes up.
            plan.firewallPorts = state.listeningPorts
            plan.disablePasswordLogin = state.passwordLoginOpen && state.sshdIncludesDropIns && !keepsPasswordForRecovery
            plan.restrictRootLogin = state.rootPasswordLoginOpen && state.sshdIncludesDropIns
                && !(keepsPasswordForRecovery && state.isRoot)
            plan.installFail2ban = state.fail2ban != "active" && state.isDebianLike
            phase = .review
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply() async {
        steps = []
        phase = .working
        do {
            let outcome = try await model.harden(server.id, plan: plan) { steps.append($0) }
            switch outcome {
            case .applied(let newState):
                state = newState
                Haptics.success()
                phase = .done("Uygulandı ve yeni bağlantıyla doğrulandı.", true)
            case .rolledBack(let message):
                phase = .done(message, false)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
