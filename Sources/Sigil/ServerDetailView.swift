import SigilCore
import SwiftUI

struct ServerDetailView: View {
    static func rotateHelp(_ store: KeyStoreKind) -> String {
        switch store {
        case .keychain: return "Önce yeni anahtar doğrulanır, sonra eskisi silinir."
        case .onePassword: return "1Password onay ister."
        case .secureEnclave: return "Touch ID üç kez sorulur: eski anahtarla kurulum, yeni anahtarla doğrulama ve eskisinin silinmesi."
        }
    }

    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let serverID: UUID
    let onDeleted: () -> Void

    @State private var history: [String]?
    @State private var historyError: String?
    @State private var loadingHistory = false
    @State private var showingDelete = false
    @State private var showingEdit = false
    @State private var showingHostKey = false
    @State private var showingHardening = false
    @State private var scrollTarget: String?
    @State private var actionError: String?
    @State private var toast: String?
    @State private var copied = false

    var body: some View {
        if let server = model.server(serverID) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(server)
                    if let banner = attentionBanner(server) { banner.transition(.move(edge: .top).combined(with: .opacity)) }
                    HStack(alignment: .top, spacing: 16) {
                        connectionCard(server)
                        keyCard(server)
                    }
                    .fixedSize(horizontal: false, vertical: true)   // both cards as tall as the taller one
                    HealthCard(server: server)
                    TunnelsCard(server: server)
                    KeysAuditCard(server: server).id("keys")
                    historyCard(server)
                    eventsCard(server)
                }
                .padding(32)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(Motion.gentle, value: server.lastReachable)
                .animation(Motion.gentle, value: server.isRotationDue(retryAfter: 0))
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(Motion.gentle) { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Label(toast, systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(Color.inkLine)
                        .background(Color.ink, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.stamp, value: toast)
            .navigationTitle(server.alias)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.checkStatus(server.id, interactive: true) }
                    } label: {
                        Label("Bağlantıyı test et", systemImage: "bolt.horizontal.circle")
                    }
                    .help("Anahtarla giriş yapıp test et (⌘R)")
                    .keyboardShortcut("r")
                    .disabled(model.busy[server.id] != nil)
                }
            }
            .sheet(isPresented: $showingDelete) {
                DeleteServerSheet(server: server, onDeleted: onDeleted)
            }
            .sheet(isPresented: $showingEdit) {
                EditServerSheet(server: server)
            }
            .sheet(isPresented: $showingHostKey) {
                HostKeyChangedSheet(server: server)
            }
            .sheet(isPresented: $showingHardening) {
                HardeningSheet(server: server)
            }
            .alert("İşlem yapılamadı", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("Tamam") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    // MARK: Header

    private func header(_ s: Server) -> some View {
        let busy = model.busy[s.id]
        return HStack(alignment: .center, spacing: 22) {
            ZStack {
                if busy != nil { PulseRing(color: .accentInk) }
                SigilMark(geometry: s.sigil, size: 92, busy: busy != nil, reachable: s.lastReachable)
            }
            .frame(width: 92, height: 92)
            .stampIn()
            .help("Bu sunucunun mührü: anahtarından üretilir, anahtar yenilenince değişir.")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(s.alias).font(.engraved(34, weight: .bold))
                    if let busy {
                        Text(busy).font(.callout).foregroundStyle(.secondary).transition(.opacity)
                    }
                }
                HStack(spacing: 6) {
                    Chip(text: ServerStatusStyle.text(s.lastReachable), systemImage: ServerStatusStyle.symbol(s.lastReachable),
                         tint: ServerStatusStyle.color(s.lastReachable))
                    Chip(text: s.store.title, systemImage: s.store.symbol, tint: s.store.tint)
                    if let env = s.environment {
                        Chip(text: env.title, systemImage: env == .production ? "flame.fill" : "leaf",
                             tint: env == .production ? .cinnabar : .verdigris)
                    }
                    if let g = s.group { Chip(text: g, systemImage: "folder", tint: .secondary) }
                    if let j = s.jumpServerID, let jump = model.server(j) {
                        Chip(text: "\(jump.alias) üzerinden", systemImage: "arrow.triangle.turn.up.right.diamond", tint: .accentInk)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        router.connect(s)
                    } label: {
                        Label("Bağlan", systemImage: "terminal")
                    }
                    .buttonStyle(InkButtonStyle())
                    .help("Bağlan (⌘T) · \(TerminalApp.preferred.title)")

                    Button {
                        Links.copy("ssh \(s.alias)")
                        Haptics.tap()
                        withAnimation(Motion.quick) { copied = true }
                        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); withAnimation(Motion.quick) { copied = false } }
                    } label: {
                        HStack(spacing: 8) {
                            Text("ssh \(s.alias)").font(.terminal)
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                                .foregroundStyle(copied ? Color.verdigris : .secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.vellum, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.hairline))
                    }
                    .buttonStyle(PressableStyle())
                    .help("Komutu kopyala")

                    Menu {
                        Button("Düzenle…") { showingEdit = true }
                        Button("Sertleştir…") { showingHardening = true }
                        Button("Bağlantıyı Test Et") { Task { await model.checkStatus(s.id, interactive: true) } }
                        Button("Anahtarı Şimdi Yenile") { rotate(s) }
                        Divider()
                        Button("Sunucuyu Güncelle…") { router.maintenance = .init(serverID: s.id, kind: .update) }
                        Button("Yeniden Başlat…") { router.maintenance = .init(serverID: s.id, kind: .reboot) }
                        Divider()
                        Button("Sil…", role: .destructive) { showingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(busy != nil)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func attentionBanner(_ s: Server) -> AnyView? {
        if s.hostKeyMismatch == true {
            return AnyView(banner(
                icon: "exclamationmark.octagon.fill", tint: .cinnabar,
                title: "Sunucunun mührü değişti",
                text: "Host key kayıtlı olandan farklı. Sigil bağlanmayı durdurdu. Sunucu yeniden kurulmadıysa araya biri girmiş olabilir.",
                button: ("İncele", { showingHostKey = true })
            ))
        }
        if !s.unacknowledgedForeignKeys.isEmpty {
            return AnyView(banner(
                icon: "exclamationmark.shield.fill", tint: .amberInk,
                title: "\(s.unacknowledgedForeignKeys.count) yabancı anahtar",
                text: "Bu sunucuya Sigil dışında anahtarlarla da girilebiliyor. Tanıyorsan işaretle, tanımıyorsan kaldır.",
                button: ("Göster", { scrollTarget = "keys" })
            ))
        }
        if s.store.asksForApproval, s.isRotationDue(retryAfter: 0) {
            return AnyView(banner(
                icon: "key.fill", tint: .amberInk,
                title: "Yeni mühür zamanı",
                text: s.store == .secureEnclave
                    ? "Secure Enclave anahtarları onayın olmadan yenilenmez. Yenile’ye bas; Touch ID birkaç kez sorulur."
                    : "1Password anahtarları onayın olmadan yenilenmez. Yenile’ye bas ve 1Password’ün sorduğu onayları ver.",
                button: ("Yenile", { rotate(s) })
            ))
        }
        if s.lastReachable == false {
            return AnyView(banner(
                icon: "wifi.exclamationmark", tint: .cinnabar,
                title: "Sunucuya ulaşılamıyor",
                text: s.events.last(where: { $0.level != .info })?.message ?? "Son denetimde yanıt alınamadı.",
                button: ("Tekrar dene", { Task { await model.checkStatus(s.id, interactive: true) } })
            ))
        }
        if !s.pendingKeyRemovals.isEmpty {
            return AnyView(banner(
                icon: "exclamationmark.triangle.fill", tint: .amberInk,
                title: "Eski anahtar sunucuda duruyor",
                text: "Yenilemeden sonra eski anahtar silinemedi; sunucuya her ulaşıldığında yeniden denenir.",
                button: ("Şimdi dene", { Task { await model.checkStatus(s.id, interactive: true) } })
            ))
        }
        return nil
    }

    private func banner(icon: String, tint: Color, title: String, text: String, button: (String, () -> Void)) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.engraved(15))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button.0, action: button.1)
                .buttonStyle(.bordered)
                .disabled(model.busy[serverID] != nil)
        }
        .padding(14)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.28)))
    }

    // MARK: Cards

    private func connectionCard(_ s: Server) -> some View {
        Card(title: "Bağlantı", systemImage: "point.3.connected.trianglepath.dotted") {
            InfoRow(label: "Adres") { Text("\(s.host):\(s.port)").font(.terminal).textSelection(.enabled) }
            InfoRow(label: "Kullanıcı") { Text(s.user).font(.terminal) }
            InfoRow(label: "Son denetim") {
                if let d = s.lastCheckedAt {
                    Text(d, format: .relative(presentation: .named)).contentTransition(.numericText())
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            InfoRow(label: "Eklendi") { Text(s.createdAt, format: .dateTime.day().month().year()) }
            if model.backgroundOff(s) {
                Text("Bu sunucuya arka planda hiç bağlanılmaz. Durum, sağlık ve denetim yalnızca sen istediğinde, Touch ID ile yapılır.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keyCard(_ s: Server) -> some View {
        Card(title: "Mühür ve anahtar", systemImage: "seal") {
            InfoRow(label: "Parmak izi") {
                Text(s.keyFingerprint.replacingOccurrences(of: "SHA256:", with: ""))
                    .font(.terminalSmall)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            InfoRow(label: "Yaşı") { Text(s.lastRotatedAt, format: .relative(presentation: .numeric)) }
            InfoRow(label: "Sonraki yenileme") {
                if let next = s.nextRotation {
                    Text(next, format: .dateTime.day().month().year())
                        .foregroundStyle(s.isRotationDue(retryAfter: 0) ? Color.amberInk : .primary)
                } else {
                    Text("Kapalı").foregroundStyle(.secondary)
                }
            }
            InfoRow(label: "Otomatik yenile") {
                Picker("", selection: Binding(get: { s.rotationIntervalDays }, set: { model.setRotationInterval(s.id, days: $0) })) {
                    ForEach(RotationChoice.all, id: \.days) { Text($0.label).tag($0.days) }
                    if !RotationChoice.all.contains(where: { $0.days == s.rotationIntervalDays }) {
                        Text(RotationChoice.label(s.rotationIntervalDays)).tag(s.rotationIntervalDays)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            Button {
                rotate(s)
            } label: {
                Label("Yeni mühür bas", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.busy[s.id] != nil)
            .help(Self.rotateHelp(s.store))
            .padding(.top, 2)
        }
    }

    private func historyCard(_ s: Server) -> some View {
        Card(title: "Sunucudaki son girişler", systemImage: "person.badge.clock") {
            Text("Sunucunun kendi kaydı. Başka bilgisayarlardan yapılan girişler de görünür; tanımadığın bir IP görürsen yeni mühür bas.")
                .font(.caption).foregroundStyle(.secondary)

            if let history {
                if history.isEmpty {
                    Text("Sunucu giriş kaydı döndürmedi.").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(history.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.terminalSmall).textSelection(.enabled)
                                    .transition(.opacity.combined(with: .offset(x: -6)))
                                    .animation(Motion.gentle.delay(Double(i) * 0.03), value: history.count)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if let historyError {
                Label(historyError, systemImage: "exclamationmark.triangle").foregroundStyle(Color.cinnabar).font(.callout)
            }
            Button {
                Task { await loadHistory(s.id) }
            } label: {
                if loadingHistory {
                    HStack { ProgressView().controlSize(.small); Text("Getiriliyor…") }
                } else {
                    Label(history == nil ? "Son girişleri getir" : "Yenile", systemImage: "clock.arrow.circlepath")
                }
            }
            .disabled(loadingHistory || model.busy[s.id] != nil)
        }
    }

    private func eventsCard(_ s: Server) -> some View {
        Card(title: "Geçmiş", systemImage: "list.bullet.below.rectangle") {
            if s.events.isEmpty {
                Text("Henüz kayıt yok.").foregroundStyle(.secondary)
            }
            let items = Array(s.events.reversed().prefix(30))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(color(e.level)).frame(width: 9, height: 9).padding(.top, 5)
                            if i < items.count - 1 {
                                Rectangle().fill(Color.hairline).frame(width: 1.5).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text(e.date, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func rotate(_ s: Server) {
        Task {
            let ok = await model.rotate(s.id)
            if ok {
                Haptics.success()
                toast = "Yeni mühür basıldı"
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                toast = nil
            } else {
                actionError = model.server(s.id)?.events.last?.message ?? "Anahtar yenilenemedi."
            }
        }
    }

    private func loadHistory(_ id: UUID) async {
        loadingHistory = true
        historyError = nil
        defer { loadingHistory = false }
        do {
            let lines = try await model.loginHistory(id)
            withAnimation(Motion.gentle) { history = lines }
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func color(_ l: ServerEvent.Level) -> Color {
        switch l {
        case .info: return .verdigris
        case .warning: return .amberInk
        case .error: return .cinnabar
        }
    }
}
