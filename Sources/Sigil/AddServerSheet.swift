import SigilCore
import SwiftUI

/// Three-step flow: details → verify the server's identity → inscribe. The seal on the left tells the story:
/// a preview while typing, the server's own seal while verifying, drawn stroke by stroke while installing,
/// then stamped with the real key's seal.
struct AddServerSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @AppStorage("defaultKeyStore") private var defaultKeyStore = KeyStoreKind.preferredDefault.rawValue
    @AppStorage("defaultRotationDays") private var defaultRotationDays = 30
    let onAdded: (Server) -> Void

    private enum Phase: Equatable { case form, scanning, confirming, working, done }

    @State private var alias = ""
    @State private var host = ""
    @State private var port = 22
    @State private var user = "root"
    @State private var password = ""
    @State private var interval = 30
    @State private var keyStore: KeyStoreKind = .keychain
    @State private var jumpID: UUID?

    @State private var phase: Phase = .form
    @State private var scanned: [HostKey] = []
    @State private var validDraft: ServerDraft?
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var added: Server?
    @FocusState private var focus: Field?

    private enum Field { case alias, host, user, password }
    private static let totalSteps = 6.0

    private var canSubmit: Bool {
        !alias.trimmed.isEmpty && !host.trimmed.isEmpty && !user.trimmed.isEmpty && !password.isEmpty
            && (keyStore != .onePassword || model.onePasswordStatus.isReady)
    }

    var body: some View {
        HStack(spacing: 0) {
            sealColumn
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .background(Color.ink.opacity(0.04))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                stepper.padding(.bottom, 18)
                Group {
                    switch phase {
                    case .form, .scanning: form
                    case .confirming: confirm
                    case .working, .done: working
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                Spacer(minLength: 0)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 520)
        .background(Color.parchment)
        .animation(Motion.stamp, value: phase)
        .interactiveDismissDisabled(phase == .working || phase == .scanning || phase == .done)
        .onAppear {
            interval = defaultRotationDays
            let preferred = KeyStoreKind(rawValue: defaultKeyStore) ?? .preferredDefault
            keyStore = KeyStoreKind.usable(preferred, onePasswordReady: model.onePasswordStatus.isReady)
            focus = .alias
        }
    }

    // MARK: Seal column

    private var sealColumn: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                if phase == .scanning || phase == .working { PulseRing(color: .accentInk) }
                SigilMark(geometry: sealGeometry, size: 150, inscribe: inscribe,
                          busy: phase == .scanning, reachable: true, showsDisc: phase != .form || !alias.trimmed.isEmpty)
                    .opacity(phase == .form && alias.trimmed.isEmpty ? 0.35 : 1)
                    .scaleEffect(phase == .done ? 1.06 : 1)
            }
            .frame(width: 150, height: 150)
            .id(phase == .done ? "done" : "live")
            .modifier(StampOnDone(active: phase == .done))

            VStack(spacing: 4) {
                Text(sealTitle).font(.engraved(16)).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                Text(sealCaption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            Spacer()
        }
    }

    private var sealGeometry: SigilGeometry {
        switch phase {
        case .form, .scanning: return SigilGeometry(seed: "preview:" + alias.trimmed.lowercased())
        case .confirming: return SigilGeometry(seed: scanned.first?.blob ?? host)
        case .working: return SigilGeometry(seed: "preview:" + alias.trimmed.lowercased())
        case .done: return added?.sigil ?? .brand
        }
    }

    private var inscribe: Double {
        phase == .working ? max(0.08, Double(steps.count) / Self.totalSteps) : 1
    }

    private var sealTitle: String {
        switch phase {
        case .form: return alias.trimmed.isEmpty ? "Yeni mühür" : alias.trimmed
        case .scanning: return "Sunucuya bakılıyor"
        case .confirming: return "Sunucunun mührü"
        case .working: return "Mühür kazınıyor"
        case .done: return "\(alias.trimmed) hazır"
        }
    }

    private var sealCaption: String {
        switch phase {
        case .form: return "Önizleme. Asıl mühür, üretilecek anahtardan doğar."
        case .scanning: return "Kimlik bilgileri alınıyor."
        case .confirming: return "Bu mühür sunucunun parmak izinden üretildi. Bir dahaki sefere farklı görünürse dikkat et."
        case .working: return steps.last ?? "Başlıyor"
        case .done: return "Terminalde: ssh \(alias.trimmed)"
        }
    }

    // MARK: Stepper

    private var stepper: some View {
        let current: Int = {
            switch phase {
            case .form, .scanning: return 0
            case .confirming: return 1
            case .working, .done: return 2
            }
        }()
        return HStack(spacing: 8) {
            ForEach(Array(["Bilgiler", "Kimlik", "Mühür"].enumerated()), id: \.offset) { i, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i <= current ? Color.ink : Color.hairline).frame(width: 20, height: 20)
                        if i < current || phase == .done {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.inkLine)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(i <= current ? Color.inkLine : .secondary)
                        }
                    }
                    Text(title).font(.callout.weight(i == current ? .semibold : .regular))
                        .foregroundStyle(i <= current ? .primary : .secondary)
                }
                if i < 2 {
                    Capsule().fill(i < current ? Color.ink : Color.hairline).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .animation(Motion.stamp, value: current)
    }

    // MARK: Phases

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 11) {
                GridRow {
                    label("İsim")
                    TextField("", text: $alias, prompt: Text("webserver")).focused($focus, equals: .alias)
                }
                GridRow {
                    label("Adres")
                    HStack {
                        TextField("", text: $host, prompt: Text("203.0.113.10")).focused($focus, equals: .host)
                        Text(":").foregroundStyle(.secondary)
                        TextField("", value: $port, format: .number.grouping(.never)).frame(width: 60)
                    }
                }
                if !model.servers.filter({ $0.jumpServerID == nil }).isEmpty {
                    GridRow {
                        label("Üzerinden", help: .jumpServer)
                        Picker("", selection: $jumpID) {
                            Text("Doğrudan").tag(UUID?.none)
                            ForEach(model.servers.filter { $0.jumpServerID == nil }) { Text($0.alias).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden().frame(maxWidth: 220, alignment: .leading)
                        .help("Sunucuya yalnızca bir bastion/atlama sunucusu üzerinden erişiliyorsa seç (ProxyJump).")
                    }
                }
                GridRow {
                    label("Kullanıcı")
                    TextField("", text: $user).focused($focus, equals: .user)
                }
                GridRow {
                    label("Şifre")
                    SecureField("", text: $password, prompt: Text("Bir kez kullanılır, saklanmaz")).focused($focus, equals: .password)
                }
                GridRow {
                    label("Anahtar", help: .keyStore)
                    Picker("", selection: $keyStore) {
                        ForEach(KeyStoreKind.available) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    label("Yenileme", help: .rotation)
                    Picker("", selection: $interval) {
                        ForEach(RotationChoice.all, id: \.days) { Text($0.label).tag($0.days) }
                    }
                    .labelsHidden().frame(maxWidth: 200, alignment: .leading)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(phase == .scanning)

            Text(keyStore.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = keyStore.promptNote {
                Label(note, systemImage: "touchid").font(.caption).foregroundStyle(Color.verdigris)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if keyStore == .onePassword && !model.onePasswordStatus.isReady {
                HStack {
                    Label("1Password kurulumu tamamlanmamış.", systemImage: "exclamationmark.circle").foregroundStyle(Color.amberInk)
                    Button("Kurulumu aç") { dismiss(); router.showingSetup = true }.controlSize(.small)
                }
                .font(.callout)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.cinnabar).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Vazgeç") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await scan() }
                } label: {
                    if phase == .scanning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Bakılıyor…") }
                    } else {
                        Text("Devam")
                    }
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || phase == .scanning)
                .opacity(!canSubmit ? 0.45 : 1)
            }
        }
        .animation(Motion.gentle, value: errorText)
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bu sunucu gerçekten o mu?").font(.engraved(20))
            Text("Aşağıdaki parmak izi, sağlayıcının panelinde ya da sunucuda gördüğünle aynı olmalı. Şifren ancak sen onaylayınca gönderilir.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(scanned) { key in
                    HStack(alignment: .firstTextBaseline) {
                        Text(key.algorithm.replacingOccurrences(of: "ssh-", with: "").uppercased())
                            .font(.caption.bold()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(key.fingerprint).font(.terminalSmall).textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline))

            HStack(spacing: 6) {
                Text("Sunucuda:").font(.caption).foregroundStyle(.secondary)
                Text("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub").font(.terminalSmall).textSelection(.enabled)
                Button { Links.copy("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Kopyala")
            }

            Spacer(minLength: 0)
            HStack {
                Button("Geri") { phase = .form }
                Spacer()
                Button("Aynı, devam et") { Task { await create() } }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(phase == .done ? "Mühür basıldı" : "Kuruluyor").font(.engraved(20))
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 10) {
                        if index == steps.count - 1 && phase != .done {
                            ProgressView().controlSize(.small).frame(width: 18)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.verdigris).frame(width: 18)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(step).foregroundStyle(index == steps.count - 1 && phase != .done ? .primary : .secondary)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.stamp, value: steps.count)
            .animation(Motion.stamp, value: phase)
            Spacer(minLength: 0)
        }
    }

    private func label(_ text: String, help: HelpTopic? = nil) -> some View {
        HStack(spacing: 4) {
            if let help { HelpButton(topic: help) }
            Text(text).foregroundStyle(.secondary)
        }
        .gridColumnAlignment(.trailing)
    }

    // MARK: Actions

    private func scan() async {
        errorText = nil
        phase = .scanning
        do {
            let result = try await model.scanHostKeys(for: ServerDraft(
                alias: alias, host: host, port: port, user: user, rotationIntervalDays: interval, keyStore: keyStore, jumpServerID: jumpID
            ))
            validDraft = result.draft
            scanned = result.keys
            phase = .confirming
        } catch {
            errorText = error.localizedDescription
            phase = .form
        }
    }

    private func create() async {
        guard let draft = validDraft else { return }
        errorText = nil
        steps = []
        phase = .working
        do {
            let server = try await model.addServer(draft: draft, password: password, hostKeys: scanned) { step in
                steps.append(step)
            }
            password = ""
            added = server
            phase = .done
            Haptics.success()
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            onAdded(server)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            phase = .form
        }
    }
}

/// Re-stamps the seal when the flow completes.
private struct StampOnDone: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.stampIn() } else { content }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
