import SigilCore
import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(TerminalSessions.self) private var terminals
    @EnvironmentObject private var updater: UpdaterModel
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    /// The group a dragged server is over ("" = no group), for the highlight.
    @State private var dropTarget: String?

    var body: some View {
        @Bindable var router = router
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
            } detail: {
                ZStack {
                    WindowBackdrop()
                    if router.mode == .terminal {
                        TerminalWorkspaceView()
                            .transition(.opacity)
                    } else if let id = router.selection, model.server(id) != nil {
                        ServerDetailView(serverID: id, onDeleted: { router.selection = nil })
                            .id(id)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    } else {
                        EmptyStateView()
                            .transition(.opacity)
                    }
                }
                .animation(Motion.gentle, value: router.selection)
                .animation(Motion.gentle, value: router.mode)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Görünüm", selection: $router.mode) {
                            Label("Genel", systemImage: "seal").tag(AppRouter.Mode.overview)
                            Label(terminals.sessions.isEmpty ? "Terminal" : "Terminal · \(terminals.sessions.count)",
                                  systemImage: "terminal").tag(AppRouter.Mode.terminal)
                        }
                        .pickerStyle(.segmented)
                        .help("Genel bakış (⌘0) · Terminaller (⌘J)")
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Sunucu ara")

            if router.showingQuickConnect {
                QuickConnectView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(1)
            }
        }
        .animation(Motion.quick, value: router.showingQuickConnect)
        .sheet(isPresented: $router.showingAdd) {
            AddServerSheet { added in router.selection = added.id }
        }
        .sheet(isPresented: $router.showingSetup) {
            SetupView()
        }
        .sheet(isPresented: $router.showingImport) {
            ImportSheet()
        }
        .sheet(isPresented: $router.showingEmergency) {
            EmergencyRotateSheet()
        }
        .sheet(item: Binding(get: { router.tourPage.map { TourPageID(page: $0) } }, set: { router.tourPage = $0?.page })) { t in
            TourSheet(page: t.page)
        }
        // Files and Docker open in their own windows, so they can sit next to the terminal.
        .onAppear { AppLaunch.openMain = { [openWindow] in openWindow(id: "main") } }
        .onChange(of: router.panel) { _, request in
            guard let request else { return }
            openWindow(id: "panel", value: request)
            router.panel = nil
        }
        .sheet(item: $router.maintenance) { request in
            if let server = model.server(request.serverID) {
                MaintenanceSheet(server: server, kind: request.kind)
            }
        }
        .sheet(isPresented: $router.showingActions) {
            ActionsSheet()
        }
        .onOpenURL { url in handle(url) }
        .alert(
            "Production sunucusu",
            isPresented: Binding(get: { router.pendingProductionConnect != nil }, set: { if !$0 { router.pendingProductionConnect = nil } }),
            presenting: router.pendingProductionConnect
        ) { s in
            Button("Bağlan", role: .destructive) { router.pendingProductionConnect = nil; router.connect(s, confirmed: true) }
            Button("Vazgeç", role: .cancel) { router.pendingProductionConnect = nil }
        } message: { s in
            Text("“\(s.alias)” production olarak işaretli. Bağlanmak istediğine emin misin? Bu oturum boyunca bir daha sorulmayacak.")
        }
        .onChange(of: router.selection) { _, id in
            // One click switches terminals: selecting a server that has an open tab shows that tab.
            guard router.mode == .terminal, let id, let s = model.server(id) else { return }
            if let tab = terminals.sessions.last(where: { $0.serverID == s.id }) { terminals.activeID = tab.id }
        }
        .alert("Uyarı", isPresented: Binding(get: { model.banner != nil }, set: { if !$0 { model.banner = nil } })) {
            Button("Tamam") { model.banner = nil }
        } message: {
            Text(model.banner ?? "")
        }
    }

    /// sigil://connect/<alias> · sigil://open/<alias> · sigil://quick — for Shortcuts, Raycast, Alfred.
    private func handle(_ url: URL) {
        guard url.scheme == "sigil" else { return }
        let alias = url.pathComponents.dropFirst().first ?? ""
        let s = model.servers.first { $0.alias.lowercased() == alias.lowercased() }
        switch url.host {
        case "connect": if let s { router.connect(s) }      // production servers still ask first
        case "open": if let s { router.selection = s.id; router.mode = .overview }
        case "quick": router.showingQuickConnect = true
        default: break
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: Sidebar

    private var filtered: [Server] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.servers
            .filter { q.isEmpty || $0.alias.lowercased().contains(q) || $0.host.lowercased().contains(q) || $0.user.lowercased().contains(q) }
            .sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    }

    private var sidebar: some View {
        @Bindable var router = router
        // Servers that need attention stay in their own group; the row carries the warning.
        let grouped = Dictionary(grouping: filtered) { $0.group ?? "" }
        let groupNames = grouped.keys.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return List(selection: $router.selection) {
            ForEach(groupNames, id: \.self) { name in
                Section(isExpanded: Binding(get: { !collapsed.contains(name) },
                                            set: { open in if open { collapsed.remove(name) } else { collapsed.insert(name) } })) {
                    ForEach(grouped[name] ?? []) { row($0) }
                } header: {
                    HStack(spacing: 6) {
                        Label(name, systemImage: dropTarget == name ? "folder.fill" : "folder")
                        let count = (grouped[name] ?? []).filter { !ServerAttention.reasons($0).isEmpty }.count
                        if count > 0 && collapsed.contains(name) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.cinnabar)
                                .help("Bu grupta dikkat isteyen \(count) sunucu var")
                        }
                        Spacer(minLength: 0)
                    }
                    .dropTarget(for: name, highlight: $dropTarget, move: move)
                }
            }
            if let ungrouped = grouped[""], !ungrouped.isEmpty {
                Section {
                    ForEach(ungrouped) { row($0) }
                } header: {
                    HStack {
                        Text(groupNames.isEmpty ? "Sunucular" : "Grupsuz")
                        Spacer(minLength: 0)
                    }
                    .dropTarget(for: "", highlight: $dropTarget, move: move)
                }
            } else if !groupNames.isEmpty {
                // Every server is in a group: somewhere to drop one to take it out.
                Section("Grupsuz") {
                    Label("Gruptan çıkarmak için buraya bırak", systemImage: "tray.and.arrow.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dropTarget(for: "", highlight: $dropTarget, move: move)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.vellum.opacity(0.6))
        .contextMenu(forSelectionType: UUID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            // Double-click / Return on a server connects.
            if let id = ids.first, let s = model.server(id) { router.connect(s) }
        }
        .overlay {
            if !model.servers.isEmpty && filtered.isEmpty {
                Text("“\(search)” ile eşleşen yok").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    router.showingQuickConnect = true
                } label: {
                    Label("Hızlı bağlan", systemImage: "command")
                }
                .help("Hızlı bağlan (⌘K)")
                .disabled(model.servers.isEmpty)

                Button {
                    router.showingActions = true
                } label: {
                    Label("Eylemler", systemImage: "bolt")
                }
                .help("Sunucularda kayıtlı komut çalıştır (⌘E)")
                .disabled(model.servers.isEmpty)

                Button {
                    Task { await model.checkAll(interactive: true) }
                } label: {
                    Label("Hepsini denetle", systemImage: "arrow.clockwise")
                }
                .help("Tüm sunucuları denetle")
                .disabled(model.servers.isEmpty)

                Button {
                    router.showingAdd = true
                } label: {
                    Label("Sunucu ekle", systemImage: "plus")
                }
                .help("Sunucu ekle (⌘N)")
            }
        }
    }

    /// The store new servers will use; read from settings, so it never makes 1Password show a prompt.
    private var sidebarStoreLabel: String {
        let preferred = KeyStoreKind(rawValue: UserDefaults.standard.string(forKey: "defaultKeyStore") ?? "") ?? .preferredDefault
        return "Varsayılan: " + KeyStoreKind.usable(preferred, onePasswordReady: model.onePasswordStatus.isReady).title
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            SigilMark(geometry: .brand, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text("Sigil").font(.engraved(12))
                    Text(Platform.shortVersion).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(sidebarStoreLabel)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Ayarlar…") { openSettings() }
                Button("Sigil’i tanı…") { router.tourPage = 0 }
                Button("Kurulum…") { router.showingSetup = true }
                Divider()
                if updater.isAvailable {
                    CheckForUpdatesButton(updater: updater)
                } else {
                    Text("Geliştirme sürümü: güncelleme kapalı")
                }
                Text("Sürüm \(Platform.version)")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ayarlar, kurulum ve güncellemeler")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar)
    }

    private func row(_ s: Server) -> some View {
        ServerRow(server: s, busy: model.busy[s.id])
            .tag(s.id)
            .draggable(ServerDrag.payload(s.id)) {
                Label(s.alias, systemImage: "server.rack").padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            // Dropped on a server: into that server's group.
            .dropTarget(for: s.group ?? "", highlight: $dropTarget, move: move)
            .contextMenu {
                Button("Bağlan") { router.connect(s) }
                Button("Bağlantıyı Test Et") { Task { await model.checkStatus(s.id, interactive: true) } }
                Button("Sunucuyu Güncelle…") { router.maintenance = .init(serverID: s.id, kind: .update) }
                Button("Yeniden Başlat…") { router.maintenance = .init(serverID: s.id, kind: .reboot) }
                Divider()
                if !model.groups.isEmpty {
                    Menu("Gruba taşı") {
                        ForEach(model.groups.filter { $0 != s.group }, id: \.self) { g in Button(g) { model.setGroup(s.id, g) } }
                        if s.group != nil {
                            Divider()
                            Button("Grupsuz") { model.setGroup(s.id, nil) }
                        }
                    }
                }
                Button("“ssh \(s.alias)” Kopyala") { Links.copy("ssh \(s.alias)") }
            }
    }

    /// Moves the dragged servers into `group` ("" = no group).
    private func move(_ payloads: [String], to group: String) -> Bool {
        let ids = payloads.compactMap(ServerDrag.id).filter { model.server($0) != nil }
        guard !ids.isEmpty else { return false }
        for id in ids where (model.server(id)?.group ?? "") != group { model.setGroup(id, group.isEmpty ? nil : group) }
        if !group.isEmpty { collapsed.remove(group) }
        Haptics.tap()
        return true
    }
}

/// A server dragged in the sidebar travels as text with a prefix, so text dragged in from elsewhere is ignored.
enum ServerDrag {
    static let prefix = "sigil-server:"
    static func payload(_ id: UUID) -> String { prefix + id.uuidString }
    static func id(_ payload: String) -> UUID? {
        payload.hasPrefix(prefix) ? UUID(uuidString: String(payload.dropFirst(prefix.count))) : nil
    }
}

private extension View {
    /// Accepts dragged servers for `group`, highlighting while one is over it.
    func dropTarget(for group: String, highlight: Binding<String?>, move: @escaping ([String], String) -> Bool) -> some View {
        dropDestination(for: String.self) { items, _ in
            highlight.wrappedValue = nil
            return move(items, group)
        } isTargeted: { over in
            if over { highlight.wrappedValue = group } else if highlight.wrappedValue == group { highlight.wrappedValue = nil }
        }
        .listRowBackground(highlight.wrappedValue == group ? Color.accentInk.opacity(0.12) : nil)
    }
}

struct ServerRow: View {
    @Environment(TerminalSessions.self) private var terminals
    let server: Server
    let busy: String?

    var body: some View {
        HStack(spacing: 11) {
            SigilMark(geometry: server.sigil, size: 30, busy: busy != nil, reachable: server.lastReachable)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(ServerStatusStyle.color(server.lastReachable))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(server.alias).font(.engraved(14))
                Text("\(server.user)@\(server.host)")
                    .font(.terminalSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if terminals.sessions.contains(where: { $0.serverID == server.id && !$0.exited }) {
                Image(systemName: "terminal.fill").font(.caption2).foregroundStyle(Color.verdigris)
                    .help("Açık terminal oturumu var")
            }
            if server.isProduction {
                Text("PROD").font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .foregroundStyle(Color.cinnabar)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.cinnabar.opacity(0.6)))
            }
            let reasons = ServerAttention.reasons(server)
            if !reasons.isEmpty {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(server.lastReachable == false || server.hostKeyMismatch == true ? Color.cinnabar : Color.amberInk)
                    .help(reasons.joined(separator: "\n"))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.alias), \(ServerStatusStyle.text(server.lastReachable))")
    }
}

/// Why a server needs a look, in a few words each (sidebar tooltip).
enum ServerAttention {
    static func reasons(_ s: Server) -> [String] {
        var r: [String] = []
        if s.lastReachable == false { r.append("Ulaşılamıyor") }
        if s.hostKeyMismatch == true { r.append("Sunucunun kimliği (host key) değişmiş") }
        if s.isRotationDue(retryAfter: 0) { r.append("Anahtar yenileme zamanı geldi") }
        if !s.pendingKeyRemovals.isEmpty { r.append("Eski anahtar sunucudan silinemedi") }
        if !s.unacknowledgedForeignKeys.isEmpty { r.append("Tanınmayan anahtar var") }
        r += s.health?.problems() ?? []
        return r
    }
}

struct EmptyStateView: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 18) {
            LivingSigil(size: 120)
            Text(model.servers.isEmpty ? "İlk mührünü bas" : "Bir sunucu seç")
                .font(.engraved(28))
            Text(model.servers.isEmpty
                 ? "Sunucunun adresini ve şifresini bir kez gir. Sigil ona özel bir anahtar üretir, sunucuya kurar ve düzenli yeniler. Her anahtarın kendi mührü olur."
                 : "Soldan bir sunucu seç, ⌘K ile hızlıca bağlan ya da aşağıdan Sigil’in neler yaptığına bak.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button {
                    router.showingAdd = true
                } label: {
                    Label("Sunucu ekle", systemImage: "plus")
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut("n")

                if !model.importCandidates().isEmpty {
                    Button("~/.ssh/config’ten içe aktar") { router.showingImport = true }
                        .buttonStyle(GlassButtonStyle())
                }
                if !model.servers.isEmpty {
                    Button("Hızlı bağlan  ⌘K") { router.showingQuickConnect = true }
                        .buttonStyle(GlassButtonStyle())
                }
                Button { router.tourPage = 0 } label: { Label("Nasıl çalışır?", systemImage: "play.circle") }
                    .buttonStyle(GlassButtonStyle())
            }
            FeatureTiles().padding(.top, 12)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TourPageID: Identifiable {
    let page: Int
    var id: Int { page }
}
