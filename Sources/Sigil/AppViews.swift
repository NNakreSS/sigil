import SigilCore
import SwiftUI

// MARK: - Server screen card

/// Apps Sigil installed on this server, with one-click open and a way into the catalogue.
struct AppsCard: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    @Binding var showingCatalog: Bool
    @State private var detail: InstalledApp?
    @State private var error: String?
    @State private var refreshing = false
    @State private var opening: String?

    var body: some View {
        Card(title: "Uygulamalar", systemImage: "square.grid.2x2", help: .apps) {
            let apps = server.apps ?? []
            if apps.isEmpty {
                Text("Docker, Grafana, Dozzle, PostgreSQL, n8n… tek tıkla kur; bağlantı bilgileri hazır gelir. Paneller istersen internete hiç açılmadan kurulur, Sigil tünelle Mac’ine getirir.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(apps) { app in row(app) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.cinnabar) }
            HStack(spacing: 10) {
                Button { showingCatalog = true } label: { Label("Uygulama kur…", systemImage: "plus.square.on.square") }
                    .buttonStyle(GlassButtonStyle())
                if !apps.isEmpty {
                    Button { Task { await refresh() } } label: {
                        if refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless).help("Sunucudan durumu yenile").disabled(refreshing)
                }
            }
        }
        .sheet(item: $detail) { app in AppDetailSheet(server: server, appID: app.id) }
    }

    private func row(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            AppIcon(symbol: app.manifest.symbol, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.manifest.name).font(.callout.weight(.medium))
                Text(AppText.reach(app.manifest)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            AppStatusChip(app: app)
            if app.manifest.http, app.manifest.port != nil {
                Button {
                    Task { await open(app) }
                } label: {
                    if opening == app.id { ProgressView().controlSize(.small) } else { Label("Aç", systemImage: "arrow.up.right.square") }
                }
                .buttonStyle(GlassButtonStyle()).disabled(opening != nil)
            }
            Button { detail = app } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help("Bağlantı bilgileri ve yönetim")
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func open(_ app: InstalledApp) async {
        opening = app.id
        error = nil
        defer { opening = nil }
        do { if let url = try await model.prepareApp(server.id, app) { Links.openURL(url) } } catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        refreshing = true
        error = nil
        defer { refreshing = false }
        do { _ = try await model.appHost(server.id) } catch { self.error = error.localizedDescription }
    }
}

enum AppText {
    static func reach(_ m: AppManifest) -> String {
        switch m.access {
        case .tunnel: return m.port.map { "Yalnızca tünelle · sunucuda 127.0.0.1:\($0)" } ?? "Sunucuda çalışıyor"
        case .domain: return m.domain.map { "https://\($0)" } ?? "Alan adıyla"
        case .publicPort: return m.port.map { "Herkese açık · port \($0)" } ?? "Herkese açık"
        case .allowList:
            let from = (m.allowFrom ?? []).joined(separator: ", ")
            return m.port.map { "Port \($0) · yalnızca \(from)" } ?? "Belirli adreslere açık"
        }
    }

    static func access(_ a: AppAccess, recipe: AppRecipe) -> String {
        switch a {
        case .tunnel:
            return recipe.port == nil
                ? "Dışarıya port açmaz."
                : "Yalnızca sunucunun içinden erişilir (127.0.0.1). Sigil şifreli SSH tüneliyle Mac’ine getirir; internetten görünmez. Önerilen."
        case .domain:
            return "Caddy önüne geçer ve Let’s Encrypt ile otomatik HTTPS sertifikası alır. Alan adının DNS kaydı (A/AAAA) bu sunucuyu göstermeli; 80 ve 443 portları açılır."
                + (recipe.ownLogin ? "" : " Bu uygulamanın kendi girişi olmadığı için Sigil önüne rastgele bir şifre koyar.")
        case .publicPort:
            return recipe.http
                ? "Port sunucunun adresinde herkese açılır, trafik şifrelenmez (http). Docker portu güvenlik duvarını (ufw) atlayarak açar."
                : "Port sunucunun adresinde herkese açılır; uygulamanın şifresi tek korumadır. Mümkünse tüneli seç."
        case .allowList:
            return "Port sunucunun adresinde dinler; güvenlik duvarı (ufw) yalnızca yazdığın adreslere izin verir. Kural, uygulama başlamadan önce eklenir; ufw kapalıysa kurulum yapılmaz."
        }
    }
}

struct AppIcon: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(Color.accentInk)
            .frame(width: size, height: size)
            .background(Color.accentInk.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct AppStatusChip: View {
    let app: InstalledApp
    var body: some View {
        if app.isRunning { Chip(text: "Çalışıyor", systemImage: "circle.fill", tint: .verdigris) }
        else if app.isStopped { Chip(text: app.total == 0 ? "Yok" : "Durdu", systemImage: "stop.circle", tint: .amberInk) }
        else { Chip(text: "\(app.running)/\(app.total) çalışıyor", systemImage: "exclamationmark.circle", tint: .amberInk) }
    }
}

// MARK: - Connection details

/// URL, address and credentials, with copy buttons; passwords stay masked until asked.
struct AppConnectionView: View {
    let connection: AppConnection
    var openURL: (() async -> Void)? = nil
    @State private var revealed: Set<String> = []
    @State private var copied: String?
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = connection.url {
                line(label: "Adres", value: url, secret: false, link: true)
            } else if let address = connection.address {
                line(label: "Adres", value: address, secret: false, link: false)
            }
            ForEach(connection.lines) { l in line(label: l.label, value: l.value, secret: l.isSecret, link: false) }
            if connection.lines.contains(where: \.isSecret) {
                Text("Şifreler bu Mac’in Keychain’inde ve sunucuda uygulamanın .env dosyasında (yalnızca root okur) durur.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 12)
    }

    private func line(label: String, value: String, secret: Bool, link: Bool) -> some View {
        let shown = !secret || revealed.contains(value)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.isEmpty ? " " : label).font(.callout).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(shown ? value : String(repeating: "•", count: 14))
                .font(.terminalSmall).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
            if secret {
                Button { if shown { revealed.remove(value) } else { revealed.insert(value) } } label: {
                    Image(systemName: shown ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless).help(shown ? "Gizle" : "Göster")
            }
            if link, let openURL {
                Button {
                    Task { opening = true; await openURL(); opening = false }
                } label: {
                    if opening { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.up.right.square") }
                }
                .buttonStyle(.borderless).help("Tarayıcıda aç")
            }
            Button {
                Links.copy(value)
                copied = value
                Haptics.tap()
            } label: { Image(systemName: copied == value ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless).help("Kopyala")
        }
    }
}

// MARK: - Installed app

struct AppDetailSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let server: Server
    let appID: String
    @State private var working: String?
    @State private var error: String?
    @State private var note: String?
    @State private var confirmRemove = false

    private var app: InstalledApp? { model.server(server.id)?.apps?.first { $0.id == appID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let app {
                HStack(spacing: 14) {
                    AppIcon(symbol: app.manifest.symbol, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.manifest.name).font(.engraved(22, weight: .bold))
                        HStack(spacing: 6) {
                            AppStatusChip(app: app)
                            Chip(text: app.manifest.access.title, systemImage: app.manifest.access == .tunnel ? "lock.fill"
                                 : app.manifest.access == .allowList ? "network.badge.shield.half.filled" : "globe", tint: .accentInk)
                            Text(server.alias).font(.terminalSmall).foregroundStyle(.secondary)
                        }
                    }
                }
                AppConnectionView(connection: model.appConnection(server.id, app), openURL: app.manifest.http ? { await open(app) } : nil)
                if let notes = model.recipe(app.id)?.notes {
                    Label(notes, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Sunucuda: \(app.manifest.dir)").font(.terminalSmall).foregroundStyle(.secondary).textSelection(.enabled)
                actions(app)
            } else {
                Text("Bu uygulama artık listede değil.").foregroundStyle(.secondary)
            }
            if let working { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working).foregroundStyle(.secondary) } }
            if let note { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(Color.verdigris).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Kapat") { dismiss() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction).disabled(working != nil)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(WindowBackdrop())
        .interactiveDismissDisabled(working != nil)
        .alert("\(app?.manifest.name ?? "Uygulama") kaldırılsın mı?", isPresented: $confirmRemove) {
            Button("Kaldır", role: .destructive) { if let app { Task { await remove(app) } } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Container’lar durdurulup silinir. Hiçbir veri silinmez: dosyalar sunucuda .removed klasörüne taşınır, Docker volume’ları yerinde kalır.")
        }
    }

    private func actions(_ app: InstalledApp) -> some View {
        FlowLayout(spacing: 8) {
            if app.manifest.http, app.manifest.port != nil {
                Button { Task { await open(app) } } label: { Label("Aç", systemImage: "arrow.up.right.square") }
            }
            Button { Task { await run(app, .restart) } } label: { Label("Yeniden başlat", systemImage: "arrow.clockwise") }
            if app.isStopped {
                Button { Task { await run(app, .start) } } label: { Label("Başlat", systemImage: "play.fill") }
            } else {
                Button { Task { await run(app, .stop) } } label: { Label("Durdur", systemImage: "stop.fill") }
            }
            Button { Task { await run(app, .update) } } label: { Label("Güncelle", systemImage: "arrow.down.circle") }
                .help("Yeni imajları indirip container’ları yeniden oluşturur; veriler kalır.")
            Button { Task { await logs(app) } } label: { Label("Günlükler", systemImage: "text.alignleft") }
            Button(role: .destructive) { confirmRemove = true } label: { Label("Kaldır…", systemImage: "trash") }
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(working != nil)
    }

    private func open(_ app: InstalledApp) async {
        error = nil
        do { if let url = try await model.prepareApp(server.id, app) { Links.openURL(url) } } catch { self.error = error.localizedDescription }
    }

    private func run(_ app: InstalledApp, _ action: AppAction) async {
        working = action == .update ? "Güncelleniyor (imajlar indiriliyor)…" : "Çalışıyor…"
        error = nil
        note = nil
        defer { working = nil }
        do {
            _ = try await model.appAction(server.id, app, action)
            note = "\(app.manifest.name) \(DeckModelText.action(action))."
        } catch { self.error = error.localizedDescription }
    }

    private func logs(_ app: InstalledApp) async {
        working = "Günlükler okunuyor…"
        error = nil
        defer { working = nil }
        do {
            let text = try await model.appAction(server.id, app, .logs)
            openWindow(id: "preview", value: TextPreview(title: "\(server.alias) · \(app.manifest.name) · günlükler", text: text))
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ app: InstalledApp) async {
        working = "Kaldırılıyor…"
        error = nil
        do {
            let kept = try await model.removeApp(server.id, app)
            working = nil
            Haptics.success()
            note = "Kaldırıldı. Dosyaları \(kept) içinde, verileri Docker volume’larında duruyor."
        } catch {
            working = nil
            self.error = error.localizedDescription
        }
    }
}

enum DeckModelText {
    static func action(_ a: AppAction) -> String {
        switch a {
        case .start: return "başlatıldı"
        case .stop: return "durduruldu"
        case .restart: return "yeniden başlatıldı"
        case .update: return "güncellendi"
        case .logs: return "günlükleri okundu"
        }
    }
}

// MARK: - Catalogue and install

struct AppCatalogSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server

    private enum Load: Equatable { case loading, ready, failed(String) }
    @State private var load: Load = .loading
    @State private var host = AppHostState()
    @State private var selection: String? = "grafana"
    @State private var search = ""
    @State private var editing: AppRecipe?
    @State private var installing = false

    private var recipes: [AppRecipe] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.allRecipes.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 260)
            Divider()
            Group {
                switch load {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Sunucu inceleniyor: Docker, boş bellek, kullanılan portlar…").foregroundStyle(.secondary)
                        if server.store.asksForApproval {
                            Text(server.store == .secureEnclave ? "Touch ID istenecek." : "1Password onayı istenecek.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let text):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).fixedSize(horizontal: false, vertical: true)
                        Button("Yeniden dene") { Task { await probe() } }.buttonStyle(GlassButtonStyle())
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .ready:
                    if let id = selection, let recipe = model.recipe(id) {
                        RecipePane(server: server, recipe: recipe, host: $host, installing: $installing, edit: { editing = recipe })
                            .id(recipe.id)
                    } else {
                        Text("Soldan bir uygulama seç.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 640)
        .background(WindowBackdrop())
        .interactiveDismissDisabled(installing)
        .task { await probe() }
        .sheet(item: $editing) { r in
            RecipeEditor(recipe: r.isCustom && model.recipe(r.id) != nil ? r : nil) { saved in selection = saved }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SigilMark(geometry: server.sigil, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) { Text("Uygulama kur").font(.engraved(16, weight: .bold)); HelpButton(topic: .apps) }
                    Text(server.alias).font(.terminalSmall).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            TextField("Ara", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 8)
            List(selection: $selection) {
                ForEach(AppCategory.allCases) { cat in
                    let items = recipes.filter { $0.category == cat }
                    if !items.isEmpty {
                        Section(cat.title) {
                            ForEach(items) { r in
                                HStack(spacing: 10) {
                                    AppIcon(symbol: r.symbol, size: 24)
                                    Text(r.name).lineLimit(1)
                                    Spacer()
                                    if installed(r) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.verdigris).help("Kurulu") }
                                }
                                .tag(r.id)
                                .contextMenu {
                                    if r.isCustom {
                                        Button("Düzenle…") { editing = r }
                                        Button("Tarifi sil", role: .destructive) { try? model.deleteRecipe(r.id) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button { editing = AppRecipe(id: "new", name: "", category: .custom, summary: "", symbol: "shippingbox", compose: "", port: nil, ownLogin: true, isCustom: true) } label: {
                    Label("Kendi tarifin…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction).disabled(installing)
            }
            .padding(10)
        }
    }

    private func installed(_ r: AppRecipe) -> Bool {
        r.isDockerEngine ? host.dockerReady : host.apps.contains { $0.id == r.id }
    }

    private func probe() async {
        load = .loading
        do {
            host = try await model.appHost(server.id)
            load = .ready
        } catch { load = .failed(error.localizedDescription) }
    }
}

/// One recipe: what it is, checks against this server, how to reach it, install and the result.
private struct RecipePane: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    let recipe: AppRecipe
    @Binding var host: AppHostState
    @Binding var installing: Bool
    let edit: () -> Void

    private enum Phase: Equatable { case choose, working, done, failed(String) }
    @State private var phase: Phase = .choose
    @State private var access: AppAccess = .tunnel
    @State private var port = 0
    @State private var domain = ""
    @State private var steps: [String] = []
    @State private var warnings: [String] = []
    @State private var output: String?
    @State private var dns: DNSMatch?
    @State private var publicOK = false
    @State private var inputValues: [String: String] = [:]
    @State private var allowFrom = ""

    private var installedApp: InstalledApp? { model.server(server.id)?.apps?.first { $0.id == recipe.id } }
    private var needsDocker: Bool { !recipe.isDockerEngine && !host.dockerReady }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch phase {
                case .choose:
                    if recipe.isDockerEngine { dockerPane } else if let app = installedApp { installedPane(app) } else { options }
                case .working:
                    stepList
                case .done:
                    donePane
                case .failed(let text):
                    stepList
                    Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).font(.callout)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button("Geri") { phase = .choose }.buttonStyle(GlassButtonStyle())
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            access = recipe.access.first ?? .tunnel
            port = recipe.port.map { host.freePort(near: $0) } ?? 0
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(symbol: recipe.symbol, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(recipe.name).font(.engraved(24, weight: .bold))
                    if recipe.isCustom {
                        Button("Düzenle…", action: edit).buttonStyle(.borderless).font(.caption)
                    }
                }
                Text(recipe.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let site = recipe.website {
                    Button { Links.openURL(site) } label: { Label("Belgeler", systemImage: "book") }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    // MARK: Choose

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !recipe.isDockerEngine {
                check(host.dockerReady, host.dockerReady ? "Docker ve docker compose hazır"
                      : host.docker == "nouser" ? "Docker kurulu ama bu kullanıcı kullanamıyor (docker grubu / sudo yok)"
                      : host.admin ? "Docker yok; kurulumdan önce Sigil kuracak" : "Docker yok ve kurmak için root/sudo gerekiyor",
                      warnOnly: host.admin && host.docker != "nouser")
            }
            if host.memoryTotalMB > 0 {
                let low = host.memoryAvailableMB < recipe.minMemoryMB
                check(!low, "Boş bellek \(host.memoryAvailableMB) MB / \(host.memoryTotalMB) MB" + (low ? " (bu uygulama ~\(recipe.minMemoryMB) MB ister)" : ""), warnOnly: true)
            }
            if host.diskFreeMB > 0 {
                check(host.diskFreeMB > 2048, "Boş disk \(host.diskFreeMB / 1024) GB", warnOnly: true)
            }
            if !host.admin || model.isSudoUnlocked(server.id) {
                SudoUnlockView(server: server) { if let fresh = try? await model.appHost(server.id) { host = fresh } }
            }
            if access == .allowList {
                check(host.ufwActive, host.ufwActive ? "Güvenlik duvarı (ufw) açık"
                      : host.admin ? "Güvenlik duvarı (ufw) kapalı; önce SSH izin listesi kartından aç"
                      : "Güvenlik duvarı kuralı için root/sudo gerekiyor")
            }
        }
    }

    private func check(_ ok: Bool, _ text: String, warnOnly: Bool = false) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : (warnOnly ? "exclamationmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok ? Color.verdigris : (warnOnly ? Color.amberInk : Color.cinnabar))
        }
        .font(.callout)
    }

    private var dockerBlocked: Bool { needsDocker && (!host.admin || host.docker == "nouser") }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            checks
            if recipe.port != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nasıl erişilsin?").font(.engraved(15))
                    Picker("", selection: $access) {
                        ForEach(recipe.access) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(AppText.access(access, recipe: recipe)).font(.caption)
                        .foregroundStyle(access == .publicPort ? Color.amberInk : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if recipe.firstVisitSetup && access != .tunnel {
                        Label("İlk açan kişi yönetici hesabını oluşturur: kurulumdan hemen sonra aç ve hesabını oluştur.", systemImage: "person.badge.key")
                            .font(.caption).foregroundStyle(Color.amberInk).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    if access == .domain {
                        GridRow {
                            Text("Alan adı").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("", text: $domain, prompt: Text("\(recipe.id).ornek.com")).textFieldStyle(.roundedBorder).frame(width: 280)
                                    .onChange(of: domain) { _, _ in dns = nil }
                                    .onSubmit { Task { await checkDNS() } }
                                dnsLine
                            }
                        }
                    }
                    GridRow {
                        Text("Sunucu portu").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("", value: $port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                            if host.listening.contains(port) || host.apps.contains(where: { $0.manifest.port == port }) {
                                Text("kullanımda").font(.caption).foregroundStyle(Color.cinnabar)
                            } else if access == .tunnel {
                                Text("yalnızca 127.0.0.1’de dinler").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if access == .allowList {
                        GridRow {
                            Text("Erişebilecek adresler").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("", text: $allowFrom, prompt: Text("203.0.113.7, 198.51.100.0/24")).textFieldStyle(.roundedBorder).frame(width: 280)
                                if !allowFrom.trimmingCharacters(in: .whitespaces).isEmpty, let e = problem({ _ = try AppScript.allowedAddresses([allowFrom]) }) {
                                    Text(e).font(.caption).foregroundStyle(Color.cinnabar).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Ör. Prometheus sunucusunun IP’si. Virgülle birden çok adres ya da ağ yazılabilir.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                if access == .publicPort {
                    Toggle(recipe.http ? "Şifrelenmemiş (http) olarak herkese açık olacağını biliyorum." : "Portun internete açık olacağını biliyorum.", isOn: $publicOK)
                        .font(.callout)
                }
            }
            if let inputs = recipe.inputs, !inputs.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(inputs) { input in
                        GridRow {
                            Text(input.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("", text: binding(input), prompt: Text(input.defaultValue)).textFieldStyle(.roundedBorder).frame(width: 280)
                                if let e = problem({ _ = try input.validate(inputValues[input.name] ?? "") }) {
                                    Text(e).font(.caption).foregroundStyle(Color.cinnabar).fixedSize(horizontal: false, vertical: true)
                                } else if let help = input.help {
                                    Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            if let notes = recipe.notes {
                Label(notes, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !recipe.secretNames(for: access).isEmpty {
                Label("Şifreler rastgele üretilir; kurulumdan sonra gösterilir ve bu Mac’in Keychain’inde saklanır.", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button { Task { await install() } } label: {
                    Label(needsDocker && !dockerBlocked ? "Docker’la birlikte kur" : "Kur", systemImage: "arrow.down.app")
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
            }
        }
    }

    private var canInstall: Bool {
        if dockerBlocked { return false }
        if recipe.port != nil {
            guard (1...65535).contains(port), !host.listening.contains(port), !host.apps.contains(where: { $0.manifest.port == port }) else { return false }
            if access == .domain && (try? AppScript.validateDomain(domain)) == nil { return false }
            if access == .publicPort && !publicOK { return false }
            if access == .allowList && (!host.ufwActive || (try? AppScript.allowedAddresses([allowFrom])) == nil) { return false }
        }
        for input in recipe.inputs ?? [] where (try? input.validate(inputValues[input.name] ?? "")) == nil { return false }
        return true
    }

    private func binding(_ input: AppInput) -> Binding<String> {
        Binding(get: { inputValues[input.name] ?? "" }, set: { inputValues[input.name] = $0 })
    }

    /// The message of the error `check` throws, or nil.
    private func problem(_ check: () throws -> Void) -> String? {
        do { try check(); return nil } catch { return error.localizedDescription }
    }

    @ViewBuilder private var dnsLine: some View {
        if let dns {
            switch dns {
            case .matches: Label("DNS bu sunucuyu gösteriyor", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.verdigris)
            case .elsewhere(let a): Label("DNS başka bir adresi gösteriyor (\(a)); sertifika alınamaz", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.amberInk)
            case .none: Label("Bu alan adının DNS kaydı yok; önce A kaydını sunucuya yönlendir", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.amberInk)
            }
        } else if (try? AppScript.validateDomain(domain)) != nil {
            Button("DNS’i denetle") { Task { await checkDNS() } }.buttonStyle(.borderless).font(.caption)
        }
    }

    private func checkDNS() async {
        guard let d = try? AppScript.validateDomain(domain) else { return }
        dns = await DNSMatch.check(domain: d, server: server.host)
    }

    private var dockerPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if host.dockerReady {
                Label("Docker ve docker compose bu sunucuda hazır.", systemImage: "checkmark.seal.fill").foregroundStyle(Color.verdigris)
            } else {
                checks
                Text(host.docker == "missing" ? "Docker, resmî get.docker.com betiğiyle kurulur." : "Eksik parçalar (compose eklentisi, servis, docker grubu) tamamlanır.")
                    .font(.callout).foregroundStyle(.secondary)
                if let notes = recipe.notes { Text(notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button { Task { await installDockerOnly() } } label: { Label("Docker’ı kur", systemImage: "arrow.down.app") }
                        .buttonStyle(InkButtonStyle()).disabled(!host.admin)
                }
                if !host.admin {
                    Text("Bu kullanıcı root değil ve şifresiz sudo yetkisi yok.").font(.caption).foregroundStyle(Color.cinnabar)
                }
            }
        }
    }

    private func installedPane(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Bu sunucuda kurulu", systemImage: "checkmark.seal.fill").foregroundStyle(Color.verdigris).font(.callout.weight(.semibold))
                AppStatusChip(app: app)
            }
            AppConnectionView(connection: model.appConnection(server.id, app), openURL: app.manifest.http ? { await open(app) } : nil)
            Text("Yönetmek (güncelle, durdur, günlükler, kaldır) için sunucu ekranındaki Uygulamalar kartını kullan.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Working / done

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    if i == steps.count - 1 && phase == .working { ProgressView().controlSize(.small).frame(width: 18) }
                    else if i == steps.count - 1, case .failed = phase { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.cinnabar).frame(width: 18) }
                    else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.verdigris).frame(width: 18) }
                    Text(s)
                }
            }
        }
    }

    private var donePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepList
            Label(recipe.isDockerEngine ? "Docker kuruldu." : "\(recipe.name) kuruldu.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.verdigris).font(.callout.weight(.semibold))
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.amberInk)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let output {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kurulum sonrası komutun çıktısı").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(output).font(.terminalSmall).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let app = installedApp {
                Text("Bağlantı bilgileri").font(.engraved(15))
                AppConnectionView(connection: model.appConnection(server.id, app), openURL: app.manifest.http ? { await open(app) } : nil)
                if let notes = recipe.notes {
                    Label(notes, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if app.manifest.access == .domain {
                    Text("Sertifika ilk ziyarette birkaç saniye içinde alınır. Alınamazsa DNS kaydını ve 80/443 portlarının sağlayıcının güvenlik duvarında açık olduğunu denetle.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ app: InstalledApp) async {
        do { if let url = try await model.prepareApp(server.id, app) { Links.openURL(url) } } catch { phase = .failed(error.localizedDescription) }
    }

    private func installDockerOnly() async {
        steps = []
        phase = .working
        installing = true
        defer { installing = false }
        do {
            try await model.installDocker(server.id) { s in withAnimation(Motion.gentle) { steps.append(s) } }
            host = try await model.appHost(server.id)
            Haptics.success()
            phase = .done
        } catch { phase = .failed(error.localizedDescription) }
    }

    private func install() async {
        steps = []
        warnings = []
        output = nil
        phase = .working
        installing = true
        defer { installing = false }
        do {
            if needsDocker {
                try await model.installDocker(server.id) { s in withAnimation(Motion.gentle) { steps.append(s) } }
                host = try await model.appHost(server.id)
                guard host.dockerReady else { throw DeckError.invalid("Docker kuruldu ama henüz kullanılamıyor; bir dakika sonra yeniden dene.") }
            }
            let report = try await model.installApp(server.id, recipe, access: access, port: recipe.port == nil ? nil : port,
                                                    domain: domain, inputs: inputValues, allowFrom: [allowFrom]) { s in
                withAnimation(Motion.gentle) { steps.append(s) }
            }
            warnings = report.warnings
            output = report.output
            if let fresh = try? await model.appHost(server.id) { host = fresh }
            Haptics.success()
            phase = .done
        } catch { phase = .failed(error.localizedDescription) }
    }
}

/// Does the domain resolve to the server? Checked from this Mac before asking Caddy for a certificate.
enum DNSMatch: Equatable {
    case matches, elsewhere(String), none

    static func check(domain: String, server: String) async -> DNSMatch {
        await Task.detached {
            let d = addresses(domain), s = addresses(server)
            if d.isEmpty { return .none }
            return d.isDisjoint(with: s) ? .elsewhere(d.sorted().joined(separator: ", ")) : .matches
        }.value
    }

    static func addresses(_ host: String) -> Set<String> {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var out = Set<String>()
        var p = result
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.insert(String(cString: buf))
            }
            p = a.pointee.ai_next
        }
        return out
    }
}

// MARK: - Own recipes

struct RecipeEditor: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: AppRecipe?
    let saved: (String) -> Void

    @State private var name: String
    @State private var compose: String
    @State private var postInstall: String
    @State private var hasPort: Bool
    @State private var port: Int
    @State private var http: Bool
    @State private var ownLogin: Bool
    @State private var secrets: String
    /// What the user set for each variable, kept by name even while it is missing from the text.
    @State private var edited: [String: AppInput]
    @State private var error: String?

    init(recipe: AppRecipe?, saved: @escaping (String) -> Void) {
        existing = recipe
        self.saved = saved
        _name = State(initialValue: recipe?.name ?? "")
        _compose = State(initialValue: recipe?.compose ?? Self.sample)
        _postInstall = State(initialValue: recipe?.postInstall ?? "")
        _hasPort = State(initialValue: recipe.map { $0.port != nil } ?? true)
        _port = State(initialValue: recipe?.port ?? 8080)
        _http = State(initialValue: recipe?.http ?? true)
        _ownLogin = State(initialValue: recipe?.ownLogin ?? true)
        _secrets = State(initialValue: recipe?.secrets.joined(separator: ", ") ?? "APP_PASSWORD")
        _edited = State(initialValue: Dictionary((recipe?.inputs ?? []).map { ($0.name, $0) }) { a, _ in a })
    }

    static let sample = """
    services:
      app:
        image: nginx:alpine
        container_name: sigil-benim-uygulamam
        restart: unless-stopped
        ports:
          - "{{BIND}}{{PORT}}:80"
        environment:
          PASSWORD: ${APP_PASSWORD}
    """

    private var secretNames: [String] {
        secrets.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map(String.init)
    }

    /// The `{{NAME}}` variables in the compose file and the command, asked in the install screen.
    private var variables: [AppInput] {
        AppInput.detect(in: [compose, postInstall], secrets: secretNames, keeping: Array(edited.values))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Yeni tarif" : existing!.name).font(.engraved(20, weight: .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Ad", text: $name, prompt: Text("Benim uygulamam")).textFieldStyle(.roundedBorder)
                    Text("docker-compose.yml").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    code($compose, height: 200)
                    Text("Sigil şunları doldurur: {{BIND}}{{PORT}} (tünel ve alan adı modunda 127.0.0.1:port), {{ADDR}} (network_mode: host’ta dinlenecek adres), {{URL}}, {{HTTPS}}, {{DOMAIN}}, {{SERVER}} (sunucunun adı), {{TZ}}. Başka bir {{AD}} yazarsan kurulumda sorulur. Aşağıdaki şifreler rastgele üretilip .env’ye yazılır; compose’da ${AD} diye kullan.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Kurulumdan sonra çalışacak komut (isteğe bağlı)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    code($postInstall, height: 90)
                    Text("Uygulama klasöründe sh ile çalışır (bash değil); şifreler $AD, Sigil’in değerleri ve değişkenler {{AD}} olarak kullanılır. Çıktısı kurulumdan sonra gösterilir.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Toggle("Bağlanılacak bir portu var", isOn: $hasPort).gridCellColumns(2)
                        }
                        if hasPort {
                            GridRow {
                                Text("Varsayılan port").foregroundStyle(.secondary)
                                TextField("", value: $port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                            }
                            GridRow {
                                Toggle("Tarayıcıda açılır (web arayüzü)", isOn: $http).gridCellColumns(2)
                            }
                            GridRow {
                                Toggle("Kendi giriş ekranı var", isOn: $ownLogin).gridCellColumns(2)
                            }
                        }
                        GridRow {
                            Text("Rastgele şifreler").foregroundStyle(.secondary)
                            TextField("", text: $secrets, prompt: Text("DB_PASSWORD, API_KEY")).textFieldStyle(.roundedBorder).font(.terminalSmall)
                        }
                    }
                    variableList
                    if hasPort && !compose.contains("{{PORT}}") {
                        Label("Compose dosyasında {{PORT}} yok; Sigil portu bağlayamaz.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.amberInk)
                    }
                    if hasPort && compose.contains("network_mode: host") {
                        Label("network_mode: host: “Belirli adreslere açık” da seçilebilir; {{ADDR}}:{{PORT}} üzerinde dinlemeli.", systemImage: "network.badge.shield.half.filled")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 8)
            }
            if let error { Text(error).foregroundStyle(Color.cinnabar).font(.callout) }
            HStack {
                if let existing {
                    Button("Tarifi sil", role: .destructive) { try? model.deleteRecipe(existing.id); dismiss() }
                }
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { save() }.buttonStyle(InkButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 640, height: 720)
        .background(Color.parchment)
    }

    private func code(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.terminalSmall)
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
    }

    @ViewBuilder private var variableList: some View {
        let vars = variables
        if !vars.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kurulumda sorulacak değişkenler").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Değişken"); Text("Etiket"); Text("Tür"); Text("Varsayılan")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(vars) { v in
                        GridRow {
                            Text(v.name).font(.terminalSmall).lineLimit(1)
                            TextField("", text: field(v, \.label)).textFieldStyle(.roundedBorder).frame(width: 140)
                            Picker("", selection: field(v, \.kind)) {
                                ForEach(AppInput.Kind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 130)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("", text: field(v, \.defaultValue), prompt: Text("boş: kurulumda yazılır")).textFieldStyle(.roundedBorder)
                                if !v.defaultValue.trimmingCharacters(in: .whitespaces).isEmpty, let e = problem(v) {
                                    Text(e).font(.caption).foregroundStyle(Color.cinnabar).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Edits one property of a detected variable; the change is kept under its name.
    private func field<T>(_ v: AppInput, _ key: WritableKeyPath<AppInput, T>) -> Binding<T> {
        Binding(get: { (edited[v.name] ?? v)[keyPath: key] }, set: {
            var i = edited[v.name] ?? v
            i[keyPath: key] = $0
            edited[v.name] = i
        })
    }

    private func problem(_ v: AppInput) -> String? {
        do { _ = try v.validate(""); return nil } catch { return error.localizedDescription }
    }

    private func save() {
        do {
            let r = try AppRecipe.custom(name: name, compose: compose, port: hasPort ? port : nil, http: http, ownLogin: ownLogin,
                                         secrets: secrets, postInstall: postInstall, inputs: variables, id: existing?.id)
            try model.saveRecipe(r)
            saved(r.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
