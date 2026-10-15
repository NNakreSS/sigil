import SigilCore
import SwiftUI

struct ContentView: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(TerminalSessions.self) private var terminals
    @State private var search = ""
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var router = router
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
            } detail: {
                ZStack {
                    Color.parchment.ignoresSafeArea()
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

    private func needsAttention(_ s: Server) -> Bool {
        s.lastReachable == false || s.isRotationDue(retryAfter: 0) || !s.pendingKeyRemovals.isEmpty
            || s.hostKeyMismatch == true || !s.unacknowledgedForeignKeys.isEmpty
            || !(s.health?.problems().isEmpty ?? true)
    }

    private var sidebar: some View {
        @Bindable var router = router
        let attention = filtered.filter(needsAttention)
        let rest = filtered.filter { !needsAttention($0) }
        let grouped = Dictionary(grouping: rest) { $0.group ?? "" }
        let groupNames = grouped.keys.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return List(selection: $router.selection) {
            if !attention.isEmpty {
                Section {
                    ForEach(attention) { row($0) }
                } header: {
                    Label("Dikkat", systemImage: "exclamationmark.circle").foregroundStyle(Color.cinnabar)
                }
            }
            ForEach(groupNames, id: \.self) { name in
                Section(isExpanded: Binding(get: { !collapsed.contains(name) },
                                            set: { open in if open { collapsed.remove(name) } else { collapsed.insert(name) } })) {
                    ForEach(grouped[name] ?? []) { row($0) }
                } header: {
                    Label(name, systemImage: "folder")
                }
            }
            if let ungrouped = grouped[""], !ungrouped.isEmpty {
                Section(groupNames.isEmpty ? "Sunucular" : "Grupsuz") {
                    ForEach(ungrouped) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            // Double-click / Return on a server connects.
            if let id = ids.first, let s = model.server(id) { router.connect(s) }
        }
        .animation(Motion.gentle, value: attention.map(\.id))
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
                    Task { await model.checkAll() }
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
                Text("Sigil").font(.engraved(12))
                Text(sidebarStoreLabel)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                router.showingSetup = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Kurulum")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar)
    }

    private func row(_ s: Server) -> some View {
        ServerRow(server: s, busy: model.busy[s.id])
            .tag(s.id)
            .contextMenu {
                Button("Bağlan") { router.connect(s) }
                Button("Bağlantıyı Test Et") { Task { await model.checkStatus(s.id, interactive: true) } }
                Divider()
                Button("“ssh \(s.alias)” Kopyala") { Links.copy("ssh \(s.alias)") }
            }
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
            if server.isRotationDue(retryAfter: 0) {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(Color.amberInk)
                    .help("Anahtar yenileme zamanı geldi")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.alias), \(ServerStatusStyle.text(server.lastReachable))")
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
                 : "Soldan bir sunucu seç ya da ⌘K ile hızlıca bağlan.")
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
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                if !model.servers.isEmpty {
                    Button("Hızlı bağlan  ⌘K") { router.showingQuickConnect = true }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
