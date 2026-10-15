import SigilCore
import SwiftUI
import UniformTypeIdentifiers

/// Server screen card: who else may log in, until when, and a one-click way to take it back.
struct GrantsCard: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    @Binding var showingGrant: Bool
    @State private var confirming: AccessGrant?
    @State private var error: String?

    var body: some View {
        Card(title: "Erişim verilenler", systemImage: "person.badge.key") {
            let grants = server.grants ?? []
            if grants.isEmpty {
                Text("Bir arkadaşına ya da ekip üyesine kendi anahtarıyla giriş izni ver. Şifre paylaşmadan, istersen süreli ve istediğin an geri alınabilir.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(grants) { g in row(g) }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.cinnabar) }
            Button { showingGrant = true } label: { Label("Erişim ver…", systemImage: "person.badge.plus") }
                .disabled(model.busy[server.id] != nil)
        }
        .confirmationDialog("“\(confirming?.name ?? "")” için erişim kaldırılsın mı?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { g in
            Button("Erişimi kaldır", role: .destructive) { revoke(g, removeAccount: false) }
            if g.createdAccount {
                Button("Erişimi ve “\(g.account)” hesabını sil", role: .destructive) { revoke(g, removeAccount: true) }
            }
        } message: { g in
            Text(g.createdAccount
                 ? "Anahtar sunucudan silinir. Hesabı da silersen ev klasöründeki dosyaları da gider."
                 : "Anahtar sunucudan silinir; bu anahtarla bir daha girilemez.")
        }
    }

    private func row(_ g: AccessGrant) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.accentInk)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(g.name).font(.engraved(15))
                    Text("\(g.account)@").font(.terminalSmall).foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 5) {
                    if let e = g.expiresAt {
                        if g.isExpired() {
                            Chip(text: "Süresi doldu", systemImage: "clock.badge.xmark", tint: .cinnabar)
                        } else {
                            Chip(text: "\(e.formatted(.relative(presentation: .named))) bitiyor", systemImage: "clock", tint: .amberInk)
                        }
                    } else {
                        Chip(text: "Süresiz", systemImage: "infinity", tint: .secondary)
                    }
                    if g.sudo { Chip(text: "sudo", systemImage: "bolt.shield", tint: .cinnabar) }
                    if let from = g.fromAddresses, !from.isEmpty {
                        Chip(text: "Yalnızca \(from.joined(separator: ", "))", systemImage: "location", tint: .verdigris)
                    }
                    if g.restrictForwarding { Chip(text: "Yönlendirme kapalı", systemImage: "arrow.left.arrow.right", tint: .secondary) }
                }
                Text(g.fingerprint.replacingOccurrences(of: "SHA256:", with: "")).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Kaldır") { confirming = g }
                .disabled(model.busy[server.id] != nil)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func revoke(_ g: AccessGrant, removeAccount: Bool) {
        Task {
            error = nil
            do {
                try await model.revokeAccess(server.id, grantID: g.id, removeAccount: removeAccount)
                Haptics.success()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// "Erişim ver": paste (or drop) a friend's public key, choose the account and limits, then hand them the command.
struct GrantAccessSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server

    private enum Account: Hashable { case sigils, separate }
    private enum Duration: Int, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30, quarter = 90, forever = 0
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .day: return "1 gün"
            case .week: return "1 hafta"
            case .month: return "1 ay"
            case .quarter: return "3 ay"
            case .forever: return "Süresiz"
            }
        }
    }

    @State private var keyText = ""
    @State private var name = ""
    @State private var account: Account = .separate
    @State private var username = ""
    @State private var sudo = false
    @State private var duration: Duration = .week
    @State private var addresses = ""
    @State private var restrictForwarding = true
    @State private var productionOK = false
    @State private var working = false
    @State private var errorText: String?
    @State private var granted: AccessGrant?
    @State private var dropTargeted = false

    private var parsed: Result<GuestKey, Error>? {
        let t = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Result { try GuestKey.parse(t) }
    }
    private var key: GuestKey? { if case .success(let k) = parsed { return k } else { return nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SigilMark(geometry: server.sigil, size: 44, reachable: server.lastReachable)
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted == nil ? "Erişim ver" : "Erişim verildi").font(.engraved(22, weight: .bold))
                    Text(server.alias).font(.terminalSmall).foregroundStyle(.secondary)
                }
            }
            if let granted { done(granted) } else { form }
        }
        .padding(24)
        .frame(width: 580)
        .background(Color.parchment)
        .interactiveDismissDisabled(working)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("1", "Arkadaşının açık anahtarı") { keyField }
                    section("2", "Kim için?") {
                        TextField("Ad (ör. Ali)", text: $name).textFieldStyle(.roundedBorder)
                            .onChange(of: name) { old, new in
                                if username.isEmpty || username == suggestedUsername(old) { username = suggestedUsername(new) }
                            }
                    }
                    section("3", "Hangi hesapla girsin?") { accountPicker }
                    section("4", "Ne kadar süre?") {
                        Picker("", selection: $duration) {
                            ForEach(Duration.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text(duration == .forever ? "Sen kaldırana kadar geçerli."
                             : "Süre dolunca sunucu bu anahtarı kendisi reddeder; Sigil açık olmasa bile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    section("5", "Sınırlar (isteğe bağlı)") {
                        TextField("Yalnızca bu adreslerden (ör. 203.0.113.7, 198.51.100.0/24)", text: $addresses)
                            .textFieldStyle(.roundedBorder).font(.terminalSmall)
                        Toggle("Port yönlendirmeyi ve ajan iletimini kapat", isOn: $restrictForwarding)
                        Text("Kapalıyken bu anahtarla tünel açılamaz; yalnızca kabuk kullanılabilir.").font(.caption).foregroundStyle(.secondary)
                    }
                    if server.isProduction {
                        Toggle("Bu bir production sunucusu; bu kişiye erişim vermek istediğimden eminim.", isOn: $productionOK)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 470)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.cinnabar).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text(model.busy[server.id] ?? "").foregroundStyle(.secondary) }
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Erişim ver") { Task { await grant() } }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGrant)
            }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $keyText)
                    .font(.terminalSmall)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 72)
                if keyText.isEmpty {
                    Text("ssh-ed25519 AAAA… ali@laptop  — yapıştır ya da .pub dosyasını buraya sürükle")
                        .font(.terminalSmall).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                }
            }
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentInk : Color.hairline, lineWidth: dropTargeted ? 2 : 1))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let text = Self.readPublicKeyFile(url) else { return }
                    DispatchQueue.main.async { keyText = text }
                }
                return true
            }
            HStack(spacing: 10) {
                switch parsed {
                case .none: EmptyView()
                case .success(let k):
                    Label("\(k.type) · \(k.fingerprint.replacingOccurrences(of: "SHA256:", with: "").prefix(16))…", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(Color.verdigris)
                case .failure(let e):
                    Label(e.localizedDescription, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(Color.cinnabar).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Dosya seç…") { pickFile() }.controlSize(.small)
            }
            DisclosureGroup("Arkadaşının anahtarı yok mu?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.instructions).font(.caption.monospaced()).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Button { Links.copy(Self.instructions) } label: { Label("Talimatı kopyala", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
        .onChange(of: keyText) { _, _ in
            if name.isEmpty, let c = key?.comment, !c.isEmpty {
                name = String(c.split(separator: "@").first ?? "").capitalized
            }
        }
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $account) {
                Text("Kendi hesabı").tag(Account.separate)
                Text("Sigil’in hesabı (\(server.user))").tag(Account.sigils)
            }
            .pickerStyle(.segmented).labelsHidden()
            if account == .separate {
                HStack {
                    Text("Kullanıcı adı").foregroundStyle(.secondary)
                    TextField("ali", text: $username).textFieldStyle(.roundedBorder).font(.terminal).frame(width: 180)
                }
                Toggle("sudo yetkisi ver (parolasız)", isOn: $sudo)
                Text(sudo ? "Bu kişi sunucuda her şeyi yapabilir. Yalnızca tamamen güvendiğin biri için aç."
                          : "Hesap yoksa Sigil açar. Kim ne yaptı ayrı görünür; senin hesabına dokunulmaz.")
                    .font(.caption).foregroundStyle(sudo ? Color.cinnabar : .secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(server.user == "root"
                     ? "Bu kişi root olarak girer: sunucuda her şeyi yapabilir. Mümkünse “Kendi hesabı”nı seç."
                     : "Bu kişi senin kullandığın “\(server.user)” hesabıyla girer.")
                    .font(.caption).foregroundStyle(server.user == "root" ? Color.cinnabar : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ n: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(n).font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Color.ink))
                Text(title).font(.engraved(15))
            }
            content().padding(.leading, 28)
        }
    }

    private var canGrant: Bool {
        guard !working, key != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if account == .separate && username.isEmpty { return false }
        return !server.isProduction || productionOK
    }

    // MARK: Done

    private func done(_ g: AccessGrant) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(g.name) artık kendi anahtarıyla girebilir.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.verdigris).font(.callout.weight(.semibold))
            Text("Ona bu komutu gönder:").font(.callout)
            HStack {
                Text(connectCommand(g)).font(.terminal).textSelection(.enabled)
                Spacer()
                Button { Links.copy(connectCommand(g)) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            }
            .padding(12)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
            if let e = g.expiresAt {
                Text("Erişim \(e.formatted(date: .long, time: .shortened)) tarihinde kendiliğinden biter.").font(.caption).foregroundStyle(.secondary)
            }
            Text("İstediğin an sunucu ekranındaki “Erişim verilenler” kartından kaldırabilirsin.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Bitti") { dismiss() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction) }
        }
    }

    private func connectCommand(_ g: AccessGrant) -> String {
        "ssh " + (server.port == 22 ? "" : "-p \(server.port) ") + "\(g.account)@\(server.host)"
    }

    // MARK: Actions

    private func grant() async {
        guard let key else { return }
        working = true
        errorText = nil
        defer { working = false }
        let days = duration.rawValue
        let request = GrantRequest(
            name: name, key: key,
            account: account == .sigils ? nil : username.trimmingCharacters(in: .whitespaces),
            sudo: account == .separate && sudo,
            expiresAt: days == 0 ? nil : Date().addingTimeInterval(TimeInterval(days) * 86400),
            fromAddresses: addresses.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty },
            restrictForwarding: restrictForwarding
        )
        do {
            let g = try await model.grantAccess(server.id, request)
            Haptics.success()
            withAnimation(Motion.stamp) { granted = g }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pub") ?? .data]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url, let text = Self.readPublicKeyFile(url) { keyText = text }
    }

    /// Small text files only; the content is validated as a public key before use.
    static func readPublicKeyFile(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func suggestedUsername(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i").lowercased()
        let first = folded.split(separator: " ").first.map(String.init) ?? ""
        return String(first.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
    }

    static let instructions = """
    Mac ya da Linux'ta Terminal'i aç ve şunu çalıştır:
      ssh-keygen -t ed25519
    (Sorulara Enter ile geçebilirsin; istersen bir parola belirle.)
    Sonra açık anahtarını göster ve çıkan TEK satırı bana gönder:
      cat ~/.ssh/id_ed25519.pub
    Bu satır gizli değil. id_ed25519 dosyasını (gizli olan) kimseyle paylaşma.
    """
}
