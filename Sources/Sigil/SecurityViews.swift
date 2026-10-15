import SigilCore
import SwiftUI

/// Every key that can open this server: Sigil's own seal, plus any "foreign" keys found in authorized_keys.
struct KeysAuditCard: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    @State private var error: String?
    @State private var confirmRemove: ForeignKey?

    var body: some View {
        Card(title: "Sunucudaki anahtarlar", systemImage: "key.viewfinder", help: .foreignKeys) {
            HStack(spacing: 10) {
                SigilMark(geometry: server.sigil, size: 26, reachable: server.lastReachable)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sigil anahtarı").font(.callout.weight(.medium))
                    Text(server.keyFingerprint).font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Chip(text: "Bu mühür", systemImage: "checkmark.seal.fill", tint: .verdigris)
            }

            if let foreign = server.foreignKeys {
                if foreign.isEmpty {
                    Label("Başka anahtar yok. Bu sunucuya yalnızca Sigil’in mührüyle girilebiliyor.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(Color.verdigris)
                } else {
                    Text("\(foreign.count) yabancı anahtar daha bu sunucuya girebiliyor:")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(foreign) { key in foreignRow(key) }
                }
            } else {
                Text("Henüz denetlenmedi. Denetim, sunucunun authorized_keys dosyasını okur; hiçbir şeyi değiştirmez.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.cinnabar)
            }

            HStack {
                Button {
                    Task {
                        error = nil
                        do { try await model.audit(server.id, interactive: true) } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label("Şimdi denetle", systemImage: "magnifyingglass")
                }
                .disabled(model.busy[server.id] != nil)
                if let at = server.lastAuditAt {
                    Text("Son denetim \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Bu anahtar sunucudan kaldırılsın mı?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { key in
            Button("Kaldır", role: .destructive) {
                Task {
                    do { try await model.removeForeignKey(server.id, blob: key.blob); Haptics.success() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { key in
            Text("\(key.comment.isEmpty ? key.fingerprint : key.comment) artık bu sunucuya giremeyecek. Bu anahtarı başka biri ya da başka bir makine kullanıyorsa erişimi kesilir.")
        }
    }

    private func foreignRow(_ key: ForeignKey) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: key.acknowledged ? "person.badge.shield.checkmark" : "exclamationmark.shield")
                .foregroundStyle(key.acknowledged ? Color.secondary : Color.amberInk)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.comment.isEmpty ? "Yorumsuz anahtar" : key.comment).font(.callout.weight(.medium))
                    if let local = key.localMatch {
                        Chip(text: "Bu Mac: \(local)", systemImage: "laptopcomputer", tint: .accentInk)
                    }
                }
                Text("\(key.type) · \(key.fingerprint)").font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(key.acknowledged ? "Uyarıyı aç" : "Tanıdık") {
                model.acknowledgeForeignKey(server.id, blob: key.blob, !key.acknowledged)
            }
            .controlSize(.small)
            .help("Tanıdık işaretlenen anahtarlar için uyarı verilmez.")
            Button("Kaldır", role: .destructive) { confirmRemove = key }
                .controlSize(.small)
                .disabled(model.busy[server.id] != nil)
        }
        .padding(10)
        .background((key.acknowledged ? Color.clear : Color.amberInk.opacity(0.07)), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline))
        .animation(Motion.gentle, value: key.acknowledged)
    }
}

/// Shown when the server's host key no longer matches known_hosts.
struct HostKeyChangedSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server
    @State private var keys: [HostKey] = []
    @State private var error: String?
    @State private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill").font(.largeTitle).foregroundStyle(Color.cinnabar)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(server.alias): sunucunun mührü değişti").font(.engraved(20, weight: .bold))
                    Text("Sigil bu sunucuya bağlanmayı durdurdu.").foregroundStyle(.secondary)
                }
            }
            Text("Bu iki sebepten olur: sunucu yeniden kuruldu ya da biri araya girdi. Sunucuyu sen veya sağlayıcın yeniden kurmadıysa yeni mührü kabul etme.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            if keys.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Sunucunun şu anki mührü alınıyor…").font(.callout) }
            } else {
                HStack(spacing: 14) {
                    SigilMark(geometry: SigilGeometry(seed: keys[0].blob), size: 54, reachable: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Yeni parmak izi").font(.caption).foregroundStyle(.secondary)
                        ForEach(keys) { k in Text("\(k.algorithm)  \(k.fingerprint)").font(.terminalSmall).textSelection(.enabled) }
                    }
                }
                .padding(12)
                .background(Color.vellum, in: RoundedRectangle(cornerRadius: 10))
            }
            Toggle("Sunucunun yeniden kurulduğunu biliyorum ve parmak izini sağlayıcıdan doğruladım", isOn: $understood)
            if let error { Text(error).font(.callout).foregroundStyle(Color.cinnabar) }
            HStack {
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Yeni mührü kabul et", role: .destructive) {
                    Task {
                        do { try await model.acceptNewHostKey(server.id, keys: keys); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(!understood || keys.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.parchment)
        .task {
            do { keys = try await model.scanHostKeys(of: server.id) } catch { self.error = error.localizedDescription }
        }
    }
}

/// "My Mac was stolen / a key leaked": rotate every server now, with live progress.
struct EmergencyRotateSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var results: [UUID: Bool] = [:]
    @State private var running = false
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "light.beacon.max.fill").font(.largeTitle).foregroundStyle(Color.cinnabar)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tüm anahtarları şimdi yenile").font(.engraved(20, weight: .bold))
                    Text("Bir anahtarın ele geçtiğinden şüpheleniyorsan: her sunucuya yeni mühür basılır, eskileri sunuculardan silinir.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.servers.contains(where: { $0.store == .onePassword }) {
                Label("1Password sunucuları için her yeni anahtarda onay istenecek.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(Color.accentInk)
            }
            if model.servers.contains(where: { $0.store == .secureEnclave }) {
                Label("Secure Enclave sunucularının her biri için Touch ID üç kez sorulacak.", systemImage: "touchid")
                    .font(.caption).foregroundStyle(Color.verdigris)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.servers) { s in
                        HStack(spacing: 10) {
                            SigilMark(geometry: s.sigil, size: 24, busy: model.busy[s.id] != nil, reachable: s.lastReachable)
                            Text(s.alias).font(.engraved(14))
                            Spacer()
                            switch results[s.id] {
                            case .some(true): Label("Yenilendi", systemImage: "checkmark.seal.fill").foregroundStyle(Color.verdigris).font(.caption)
                            case .some(false): Label("Başarısız", systemImage: "xmark.octagon").foregroundStyle(Color.cinnabar).font(.caption)
                            case .none: Text(model.busy[s.id] ?? (running ? "Sırada" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 9))
                        .animation(Motion.stamp, value: results[s.id])
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button(finished ? "Kapat" : "Vazgeç") { dismiss() }.disabled(running).keyboardShortcut(.cancelAction)
                if !finished {
                    Button("Hepsini yenile", role: .destructive) {
                        Task {
                            running = true
                            results = await model.rotateAll { s, ok in results[s.id] = ok }
                            running = false
                            finished = true
                            Haptics.success()
                        }
                    }
                    .disabled(running || model.servers.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.parchment)
        .interactiveDismissDisabled(running)
    }
}
