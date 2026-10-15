import SigilCore
import SwiftUI

/// Takes over hosts from ~/.ssh/config. Each one gets a fresh Sigil key installed with the user's existing access;
/// hosts already in known_hosts are verified automatically, new ones ask for a fingerprint check.
struct ImportSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultKeyStore") private var defaultKeyStore = KeyStoreKind.preferredDefault.rawValue
    @AppStorage("defaultRotationDays") private var defaultRotationDays = 30

    private enum RowState: Equatable {
        case idle, scanning, needsConfirm, working(String), done, failed(String), needsPassword(String)
    }

    @State private var candidates: [ImportCandidate] = []
    @State private var selected: Set<String> = []
    @State private var states: [String: RowState] = [:]
    @State private var scanned: [String: [HostKey]] = [:]
    @State private var passwords: [String: String] = [:]
    @State private var keyStore: KeyStoreKind = .keychain
    @State private var interval = 30
    @State private var removeOldKey = false
    @State private var running = false
    @State private var confirming: ImportCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SigilMark(geometry: .brand, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mevcut sunucuları içe aktar").font(.engraved(22, weight: .bold))
                    Text("~/.ssh/config’teki sunucular aynı kısayolla Sigil’e geçer; her birine yeni, özel bir anahtar kurulur.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if candidates.isEmpty {
                ContentUnavailableView("İçe aktarılacak sunucu yok", systemImage: "tray",
                                       description: Text("~/.ssh/config’te basit bir “Host” bloğu bulunamadı."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(candidates) { c in row(c) }
                    }
                }
                .frame(maxHeight: .infinity)

                Divider()

                HStack(spacing: 16) {
                    Picker("Anahtar", selection: $keyStore) {
                        ForEach(KeyStoreKind.available) { Text($0.title).tag($0) }
                    }
                    .frame(width: 230)
                    .disabled(running)
                    Picker("Yenileme", selection: $interval) {
                        ForEach(RotationChoice.all, id: \.days) { Text($0.label).tag($0.days) }
                    }
                    .frame(width: 200)
                    .disabled(running)
                }
                Toggle("Eski anahtarı sunucudan kaldır", isOn: $removeOldKey)
                    .disabled(running)
                    .help("Kapalıyken eski anahtarın sunucuda kalır; başka yerlerde de kullanıyorsan böyle bırak.")
                Text("Eski ayar silinmez: ~/.ssh/config yedeklenir ve blok yorum satırına alınır.")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = keyStore.promptNote {
                    Label(note, systemImage: "touchid").font(.caption).foregroundStyle(Color.verdigris)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(allFinished ? "Kapat" : "Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                if !allFinished {
                    Button {
                        Task { await runAll() }
                    } label: {
                        if running { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Aktarılıyor…") } }
                        else { Text(selected.isEmpty ? "Seç" : "\(selected.count) sunucuyu aktar") }
                    }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || running || (keyStore == .onePassword && !model.onePasswordStatus.isReady))
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(Color.parchment)
        .interactiveDismissDisabled(running)
        .onAppear {
            candidates = model.importCandidates()
            selected = Set(candidates.map(\.alias))
            interval = defaultRotationDays
            let preferred = KeyStoreKind(rawValue: defaultKeyStore) ?? .preferredDefault
            keyStore = KeyStoreKind.usable(preferred, onePasswordReady: model.onePasswordStatus.isReady)
        }
        .sheet(item: $confirming) { c in
            FingerprintConfirmSheet(candidate: c, keys: scanned[c.alias] ?? []) { ok in
                states[c.alias] = ok ? .working("Onaylandı") : .failed("Parmak izi onaylanmadı")
                confirming = nil   // runAll continues sequentially from here
            }
        }
    }

    private var allFinished: Bool {
        !candidates.isEmpty && selected.allSatisfy { if case .done = states[$0] { return true } else { return false } }
    }

    // MARK: Row

    private func row(_ c: ImportCandidate) -> some View {
        let state = states[c.alias] ?? .idle
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { selected.contains(c.alias) },
                                         set: { if $0 { selected.insert(c.alias) } else { selected.remove(c.alias) } }))
                    .labelsHidden()
                    .disabled(running || state == .done)
                SigilMark(geometry: SigilGeometry(seed: "preview:" + c.alias.lowercased()), size: 30,
                          busy: { if case .working = state { return true }; return state == .scanning }())
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.alias).font(.engraved(14))
                    Text("\(c.user)@\(c.host)\(c.port == 22 ? "" : ":\(c.port)")").font(.terminalSmall).foregroundStyle(.secondary)
                }
                Spacer()
                stateLabel(state)
            }
            if case .needsPassword(let message) = state {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    SecureField("Şifre", text: Binding(get: { passwords[c.alias] ?? "" }, set: { passwords[c.alias] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                    Button("Şifreyle dene") { Task { running = true; await importOne(c); running = false } }
                        .disabled((passwords[c.alias] ?? "").isEmpty)
                }
                .padding(.leading, 44)
            }
        }
        .padding(10)
        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline))
        .animation(Motion.gentle, value: state)
    }

    @ViewBuilder
    private func stateLabel(_ state: RowState) -> some View {
        switch state {
        case .idle: EmptyView()
        case .scanning: Text("Bakılıyor…").font(.caption).foregroundStyle(.secondary)
        case .needsConfirm: Text("Onay bekliyor").font(.caption).foregroundStyle(Color.amberInk)
        case .working(let s): Text(s).font(.caption).foregroundStyle(.secondary)
        case .done: Label("Aktarıldı", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.verdigris)
        case .failed(let m): Text(m).font(.caption).foregroundStyle(Color.cinnabar).lineLimit(2).frame(maxWidth: 240, alignment: .trailing)
        case .needsPassword: Label("Şifre gerekli", systemImage: "key").font(.caption).foregroundStyle(Color.amberInk)
        }
    }

    // MARK: Flow

    private func runAll() async {
        running = true
        for c in candidates where selected.contains(c.alias) {
            if case .done = states[c.alias] { continue }
            states[c.alias] = .scanning
            do {
                let (keys, status) = try await model.scanForImport(c)
                scanned[c.alias] = keys
                switch status {
                case .matches:
                    await importOne(c)
                case .mismatch:
                    states[c.alias] = .failed("Parmak izi kayıtlı olandan farklı; atlandı.")
                case .unknown:
                    states[c.alias] = .needsConfirm
                    confirming = c
                    // Wait for the confirmation sheet to finish this one before moving on.
                    while confirming != nil { try? await Task.sleep(nanoseconds: 150_000_000) }
                    if case .working = states[c.alias] { await importOne(c) }
                }
            } catch {
                states[c.alias] = .failed(error.localizedDescription)
            }
        }
        running = false
        if allFinished { Haptics.success() }
    }

    private func importOne(_ c: ImportCandidate) async {
        let password = passwords[c.alias].flatMap { $0.isEmpty ? nil : $0 }
        do {
            _ = try await model.importServer(c, keyStore: keyStore, rotationIntervalDays: interval,
                                             hostKeys: scanned[c.alias] ?? [], password: password,
                                             removeOldKey: removeOldKey) { step in
                states[c.alias] = .working(step)
            }
            passwords[c.alias] = nil
            states[c.alias] = .done
        } catch {
            let message = error.localizedDescription
            if password == nil, message.contains("Permission denied") || message.contains("kabul edilmedi") || message.contains("şifre") {
                states[c.alias] = .needsPassword("Mevcut bağlantı çalışmadı.")
            } else {
                states[c.alias] = .failed(message)
            }
        }
    }
}

private struct FingerprintConfirmSheet: View {
    let candidate: ImportCandidate
    let keys: [HostKey]
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SigilMark(geometry: SigilGeometry(seed: keys.first?.blob ?? candidate.host), size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.alias) gerçekten o mu?").font(.engraved(18, weight: .bold))
                    Text("Bu sunucu daha önce kaydedilmemiş. Parmak izini sağlayıcının panelindekiyle karşılaştır.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keys) { k in
                    HStack {
                        Text(k.algorithm.replacingOccurrences(of: "ssh-", with: "").uppercased())
                            .font(.caption.bold()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(k.fingerprint).font(.terminalSmall).textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Atla") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Aynı, devam et") { done(true) }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Color.parchment)
    }
}
