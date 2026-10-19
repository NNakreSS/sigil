import SigilCore
import SwiftUI

/// Server screen card: whether SSH is open to everyone or only to some addresses, with a one-click "only me".
struct AllowListCard: View {
    let server: Server
    @Binding var showing: Bool

    var body: some View {
        Card(title: "SSH izin listesi", systemImage: "network.badge.shield.half.filled", help: .allowList) {
            if let list = server.allowList, !list.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Color.verdigris)
                    Text("SSH yalnızca \(list.count) adrese açık").font(.callout.weight(.semibold))
                }
                FlowLayout(spacing: 6) {
                    ForEach(list) { a in Chip(text: "\(a.label) · \(a.address)", systemImage: "checkmark.shield", tint: .verdigris) }
                }
            } else {
                Text("SSH portu internetteki herkese açık. Yalnızca senin IP’ne (ve seçtiğin adreslere) izin verirsen, dünyanın geri kalanı bağlanmayı deneyemez bile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { showing = true } label: {
                Label(server.allowList == nil ? "Yalnızca benim IP’me izin ver…" : "Yönet…", systemImage: "network.badge.shield.half.filled")
            }
            .buttonStyle(GlassButtonStyle())
        }
    }
}

/// Reads the firewall, suggests "this Mac" (the address the server sees), and applies with the 45 s watchdog.
struct AllowListSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server

    private enum Phase: Equatable { case loading, editing, working, done(String), rolledBack(String), failed(String) }
    @State private var phase: Phase = .loading
    @State private var state = AllowListState()
    @State private var list: [AllowedAddress] = []
    @State private var newAddress = ""
    @State private var newLabel = ""
    @State private var steps: [String] = []
    @State private var productionOK = false
    @State private var riskOK = false

    private var me: String? { state.clientAddress }
    private var includesMe: Bool { me.map { m in list.contains { AllowList.contains($0.address, m) } } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SigilMark(geometry: server.sigil, size: 44, busy: phase == .loading || phase == .working)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("SSH izin listesi").font(.engraved(22, weight: .bold))
                        HelpButton(topic: .allowList)
                    }
                    Text(server.alias).font(.terminalSmall).foregroundStyle(.secondary)
                }
            }
            switch phase {
            case .loading:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Güvenlik duvarı okunuyor…").foregroundStyle(.secondary) }
            case .editing:
                editor
            case .working:
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 10) {
                            if i == steps.count - 1 { ProgressView().controlSize(.small).frame(width: 18) }
                            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.verdigris).frame(width: 18) }
                            Text(s)
                        }
                    }
                }
            case .done(let text):
                Label(text, systemImage: "checkmark.seal.fill").foregroundStyle(Color.verdigris).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            case .rolledBack(let text):
                Label(text, systemImage: "arrow.uturn.backward.circle.fill").foregroundStyle(Color.amberInk).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24)
        .frame(width: 580)
        .background(WindowBackdrop())
        .interactiveDismissDisabled(phase == .working)
        .task { await load() }
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.canAdminister {
                Label("Bu kullanıcı root değil ve şifresiz sudo yetkisi yok; güvenlik duvarı değiştirilemez.", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.callout).foregroundStyle(Color.amberInk)
            }
            if !state.canAdminister || model.isSudoUnlocked(server.id) {
                SudoUnlockView(server: server) { await load() }
            }
            HStack(spacing: 8) {
                Image(systemName: state.isOn ? "lock.fill" : "lock.open").foregroundStyle(state.isOn ? Color.verdigris : Color.amberInk)
                Text(state.isOn ? "Şu an SSH yalnızca aşağıdaki adreslere açık." : "Şu an SSH portu (\(state.sshPort)) herkese açık.")
                    .font(.callout.weight(.semibold))
            }

            if let me {
                HStack {
                    Label("Bu Mac sunucuya \(me) adresinden bağlanıyor", systemImage: "laptopcomputer")
                        .font(.callout)
                    Spacer()
                    if !includesMe {
                        Button("Ekle") { add(me, "Bu Mac") }.buttonStyle(InkButtonStyle())
                    } else {
                        Chip(text: "Listede", systemImage: "checkmark", tint: .verdigris)
                    }
                }
                .padding(10)
                .glassSurface(cornerRadius: 10)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(list) { a in
                    HStack(spacing: 10) {
                        Image(systemName: me.map { AllowList.contains(a.address, $0) } == true ? "laptopcomputer" : "network")
                            .foregroundStyle(Color.accentInk).frame(width: 18)
                        Text(a.address).font(.terminal)
                        Text(a.label).foregroundStyle(.secondary)
                        Spacer()
                        Button { list.removeAll { $0.address == a.address } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Listeden çıkar")
                    }
                }
                if list.isEmpty {
                    Text("Liste boş. En azından bu Mac’i ekle.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("IP ya da ağ (203.0.113.7, 198.51.100.0/24)", text: $newAddress).textFieldStyle(.roundedBorder).font(.terminalSmall)
                    TextField("Ad (Ofis, VPN…)", text: $newLabel).textFieldStyle(.roundedBorder).frame(width: 140)
                    Button("Ekle") { add(newAddress, newLabel.isEmpty ? "Adres" : newLabel) }
                        .disabled((try? AllowList.validate(newAddress)) == nil)
                }
            }

            Label("Ev internetinde IP’n değişebilir. Değişirse sunucuya giremezsin; o zaman sağlayıcının web konsolundan ufw’yi kapatman gerekir. Mümkünse sabit bir IP (ofis, VPN) ya da bir ağ aralığı da ekle.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Color.amberInk).fixedSize(horizontal: false, vertical: true)

            if !includesMe && !list.isEmpty {
                Toggle("Bu Mac listede değil; bağlantımı kesebileceğini biliyorum.", isOn: $riskOK).font(.callout)
                    .foregroundStyle(Color.cinnabar)
            }
            if server.isProduction {
                Toggle("Bu bir production sunucusu; erişimi kısıtlamak istediğimden eminim.", isOn: $productionOK).font(.callout)
            }
            Text("Uygulanınca Sigil 45 saniye içinde yeni bir bağlantıyla dener; giremezse sunucu eski kurallara kendisi döner.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if phase == .editing, state.isOn {
                Button("İzin listesini kapat", role: .destructive) { Task { await disable() } }
            }
            Spacer()
            switch phase {
            case .editing:
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(state.isOn ? "Değişiklikleri uygula" : "Uygula") { Task { await apply() } }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(list.isEmpty || (!includesMe && !riskOK) || (server.isProduction && !productionOK))
            case .working, .loading:
                EmptyView()
            default:
                Button("Kapat") { dismiss() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Actions

    private func add(_ address: String, _ label: String) {
        guard let a = try? AllowList.validate(address), !list.contains(where: { $0.address == a }) else { return }
        list.append(AllowedAddress(address: a, label: label.trimmingCharacters(in: .whitespaces)))
        newAddress = ""
        newLabel = ""
    }

    private func load() async {
        do {
            state = try await model.allowListState(server.id)
            list = state.allowed
            // One click: when there is no list yet, start from "this Mac".
            if list.isEmpty, let me { list = [AllowedAddress(address: me, label: "Bu Mac")] }
            phase = .editing
        } catch { phase = .failed(error.localizedDescription) }
    }

    private func apply() async {
        steps = []
        phase = .working
        do {
            let outcome = try await model.applyAllowList(server.id, list, allowLockingMeOut: riskOK) { step in
                withAnimation(Motion.gentle) { steps.append(step) }
            }
            switch outcome {
            case .applied:
                Haptics.success()
                phase = .done("SSH artık yalnızca \(list.count) adrese açık; yeni bağlantıyla doğrulandı.")
            case .rolledBack(let message):
                phase = .rolledBack(message)
            }
        } catch { phase = .failed(error.localizedDescription) }
    }

    private func disable() async {
        steps = ["İzin listesi kapatılıyor"]
        phase = .working
        do {
            try await model.disableAllowList(server.id)
            phase = .done("SSH yeniden her yerden erişilebilir.")
        } catch { phase = .failed(error.localizedDescription) }
    }
}
