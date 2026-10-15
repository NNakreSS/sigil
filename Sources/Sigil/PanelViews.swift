import AppKit
import SigilCore
import SwiftUI
import UniformTypeIdentifiers

struct PanelRequest: Identifiable {
    enum Kind { case files, docker }
    let serverID: UUID
    let kind: Kind
    var id: String { "\(serverID)-\(kind)" }
}

/// Files or Docker for one server, over one shared connection (one Touch ID), closed with the panel.
struct ServerPanelSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server
    let kind: PanelRequest.Kind

    @State private var ready = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SigilMark(geometry: server.sigil, size: 28, reachable: server.lastReachable)
                Text(server.alias).font(.engraved(17))
                Label(kind == .files ? "Dosyalar" : "Docker", systemImage: kind == .files ? "folder" : "cube.box")
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.accentInk)
                if server.isProduction { Chip(text: "Production", systemImage: "flame.fill", tint: .cinnabar) }
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            Group {
                if ready {
                    switch kind {
                    case .files: FileBrowser(server: server)
                    case .docker: DockerPanel(server: server)
                    }
                } else if let error {
                    VStack(spacing: 12) {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar)
                        Button("Tekrar dene") { Task { await connect() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(server.store.asksForApproval ? "Bağlanıyor… (onay bir kez istenecek)" : "Bağlanıyor…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 560, idealHeight: 660)
        .background(Color.parchment)
        .task { await connect() }
        .onDisappear { model.closeSession(server.id) }
    }

    private func connect() async {
        error = nil
        do {
            _ = try await model.sessionTarget(server.id)
            ready = true
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Files

private struct FileBrowser: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let server: Server

    @State private var path = "~"
    @State private var pathField = ""
    @State private var files: [RemoteFile] = []
    @State private var history: [String] = []
    @State private var selection: Set<String> = []
    @State private var showHidden = false
    @State private var loading = false
    @State private var status: String?
    @State private var error: String?
    @State private var preview: (name: String, text: String)?
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var deleting: RemoteFile?
    @State private var creatingFolder = false
    @State private var dropTargeted = false

    private var shown: [RemoteFile] { showHidden ? files : files.filter { !$0.isHidden } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            Divider()
            statusBar
        }
        .task { await load("~") }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview { PreviewSheet(name: preview.name, text: preview.text) }
        }
        .alert("Yeniden adlandır", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Yeni ad", text: $newName)
            Button("Vazgeç", role: .cancel) { renaming = nil }
            Button("Adlandır") { if let f = renaming { Task { await rename(f) } } }
        }
        .alert("Yeni klasör", isPresented: $creatingFolder) {
            TextField("Klasör adı", text: $newName)
            Button("Vazgeç", role: .cancel) {}
            Button("Oluştur") { Task { await makeFolder() } }
        }
        .confirmationDialog("“\(deleting?.name ?? "")” silinsin mi?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { f in
            Button(f.kind == .directory ? "Klasörü ve içindekileri sil" : "Sil", role: .destructive) { Task { await delete(f) } }
        } message: { f in
            Text("\(f.path)\nSunucudan kalıcı olarak silinir; geri alınamaz.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(history.isEmpty).help("Geri")
            Button { Task { await load(parent(of: path)) } } label: { Image(systemName: "arrow.up") }.disabled(path == "/").help("Üst klasör")
            Button { Task { await load("~") } } label: { Image(systemName: "house") }.help("Ev klasörü")
            TextField("Yol", text: $pathField)
                .textFieldStyle(.roundedBorder).font(.terminalSmall)
                .onSubmit { if ReturnKey.pressed { Task { await load(pathField) } } }
            Button { Task { await load(path, remember: false) } } label: { Image(systemName: "arrow.clockwise") }.help("Yenile")
            Toggle(isOn: $showHidden) { Image(systemName: "eye") }.toggleStyle(.button).help("Gizli dosyaları göster")
            Button { newName = ""; creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("Yeni klasör")
            Button { upload() } label: { Label("Yükle", systemImage: "arrow.up.doc") }.help("Bu klasöre dosya yükle")
            Button { openTerminalHere() } label: { Label("Terminal", systemImage: "terminal") }.help("Bu klasörde terminal aç")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var table: some View {
        Table(shown, selection: $selection) {
            TableColumn("Ad") { f in
                HStack(spacing: 8) {
                    Image(systemName: icon(f)).foregroundStyle(f.kind == .directory ? Color.accentInk : .secondary).frame(width: 16)
                    Text(f.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            }
            TableColumn("Boyut") { f in
                Text(f.kind == .directory ? "—" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Değiştirilme") { f in
                Text(f.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150, max: 200)
            TableColumn("İzinler") { f in
                Text("\(f.mode) \(f.owner)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150, max: 200)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let f = files.first(where: { ids.first == $0.id }) {
                if f.kind == .directory { Button("Aç") { Task { await load(f.path) } } }
                if f.kind == .file { Button("Önizle") { Task { await open(f) } } }
                Button("İndir…") { download(f) }
                Divider()
                Button("Yeniden adlandır…") { newName = f.name; renaming = f }
                Button("Yolu kopyala") { Links.copy(f.path) }
                Divider()
                Button("Sil…", role: .destructive) { deleting = f }
            }
        } primaryAction: { ids in
            if let f = files.first(where: { ids.first == $0.id }) { Task { await open(f) } }
        }
        .overlay {
            if loading && files.isEmpty { ProgressView() }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentInk, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await uploadFile(url) } }
                }
            }
            return true
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).lineLimit(2)
            } else if let status {
                Text(status).foregroundStyle(.secondary)
            } else {
                Text("\(shown.count) öğe · dosyaları buraya sürükleyerek yükleyebilirsin").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: Actions

    private func load(_ target: String, remember: Bool = true) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let (resolved, list) = try await model.listDirectory(server.id, target.isEmpty ? "~" : target)
            if remember, resolved != path, path != "~" { history.append(path) }
            path = resolved
            pathField = resolved
            files = list
            selection = []
            status = nil
        } catch { self.error = error.localizedDescription }
    }

    private func goBack() {
        guard let last = history.popLast() else { return }
        Task { await load(last, remember: false) }
    }

    private func parent(of p: String) -> String {
        let url = URL(fileURLWithPath: p)
        return url.deletingLastPathComponent().path
    }

    private func icon(_ f: RemoteFile) -> String {
        switch f.kind {
        case .directory: return "folder.fill"
        case .link: return "arrowshape.turn.up.right"
        case .other: return "questionmark.square"
        case .file:
            let ext = (f.name as NSString).pathExtension.lowercased()
            if ["log", "txt", "md", "conf", "cfg", "ini", "yml", "yaml", "json", "env", "sh", "py", "js", "ts", "php", "html", "css", "xml", "toml"].contains(ext) { return "doc.text" }
            if ["gz", "tgz", "zip", "tar", "xz", "bz2"].contains(ext) { return "doc.zipper" }
            if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(ext) { return "photo" }
            return "doc"
        }
    }

    private func open(_ f: RemoteFile) async {
        switch f.kind {
        case .directory, .link: await load(f.path)
        case .file:
            if f.size > 262_144 {
                status = "Dosya büyük (\(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))); ilk 256 KB gösteriliyor."
            }
            do { preview = (f.name, try await model.readFile(server.id, f.path)) }
            catch { self.error = error.localizedDescription }
        case .other: break
        }
    }

    private func rename(_ f: RemoteFile) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, !name.contains("/"), name != f.name else { return }
        do {
            try await model.renameFile(server.id, from: f.path, to: parent(of: f.path) + (parent(of: f.path) == "/" ? "" : "/") + name)
            await load(path, remember: false)
        } catch { self.error = error.localizedDescription }
    }

    private func makeFolder() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        do {
            try await model.makeDirectory(server.id, (path == "/" ? "" : path) + "/" + name)
            await load(path, remember: false)
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ f: RemoteFile) async {
        deleting = nil
        do {
            try await model.deleteFile(server.id, f.path)
            await load(path, remember: false)
        } catch { self.error = error.localizedDescription }
    }

    private func download(_ f: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = f.name
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            status = "İndiriliyor: \(f.name)…"
            error = nil
            do {
                try await model.copy(server.id, local: url, remote: f.path, toServer: false)
                status = "İndirildi: \(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription; status = nil }
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await uploadFile(url) } }
    }

    private func uploadFile(_ url: URL) async {
        status = "Yükleniyor: \(url.lastPathComponent)…"
        error = nil
        do {
            try await model.copy(server.id, local: url, remote: path, toServer: true)
            status = "Yüklendi: \(url.lastPathComponent)"
            await load(path, remember: false)
        } catch { self.error = error.localizedDescription; status = nil }
    }

    private func openTerminalHere() {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        dismiss()
        router.runInTerminal(server, command: "cd \(quoted) && exec \"${SHELL:-/bin/sh}\" -l", title: (path as NSString).lastPathComponent)
    }
}

private struct PreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(name, systemImage: "doc.text").font(.engraved(15))
                Spacer()
                Button { Links.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Kopyala")
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "(boş dosya)" : text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - Docker

private struct DockerPanel: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let server: Server

    @State private var containers: [DockerContainer] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var working: String?
    @State private var autoRefresh = true
    @State private var confirm: (container: DockerContainer, verb: String)?
    @State private var logs: (name: String, text: String)?

    private var groups: [(String, [DockerContainer])] {
        Dictionary(grouping: containers) { $0.project ?? "" }
            .sorted { ($0.key.isEmpty ? "~" : $0.key) < ($1.key.isEmpty ? "~" : $1.key) }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(containers.filter(\.isRunning).count) çalışıyor · \(containers.count) toplam").foregroundStyle(.secondary)
                Spacer()
                Toggle("5 sn’de bir yenile", isOn: $autoRefresh).toggleStyle(.checkbox)
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if containers.isEmpty {
                Text("Bu sunucuda container yok.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { project, items in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(project.isEmpty ? "Tek başına container’lar" : project,
                                      systemImage: project.isEmpty ? "cube" : "square.stack.3d.up")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(items) { row($0) }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task(id: autoRefresh) {
            await refresh()
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if working == nil { await refresh() }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { c in
            Button(verbTitle(c.verb), role: .destructive) { Task { await act(c.container, c.verb) } }
        } message: { c in
            Text(c.verb == "rm" ? "Container silinir; içindeki ve volume’a yazılmamış veriler gider." : "Bu container’daki servis kısa süre kesilir.")
        }
        .sheet(isPresented: Binding(get: { logs != nil }, set: { if !$0 { logs = nil } })) {
            if let logs { PreviewSheet(name: "\(logs.name) · son 300 satır", text: logs.text) }
        }
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        return "“\(c.container.name)” · \(verbTitle(c.verb).lowercased())?"
    }

    private func verbTitle(_ v: String) -> String {
        switch v {
        case "stop": return "Durdur"
        case "start": return "Başlat"
        case "restart": return "Yeniden başlat"
        case "rm": return "Sil"
        default: return v
        }
    }

    private func row(_ c: DockerContainer) -> some View {
        HStack(spacing: 12) {
            Circle().fill(c.isRunning ? Color.verdigris : (c.state == "restarting" ? Color.amberInk : Color.secondary.opacity(0.5)))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(c.name).font(.system(.body, design: .monospaced).weight(.medium))
                    Text(c.image).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(c.status).font(.caption).foregroundStyle(.secondary)
                    if !c.ports.isEmpty { Text(c.ports).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            if let cpu = c.cpu, c.isRunning {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("CPU \(cpu)").font(.caption.monospacedDigit())
                    Text(c.memory ?? "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if working == c.name { ProgressView().controlSize(.small) }
            HStack(spacing: 2) {
                icon("doc.text.magnifyingglass", "Son loglar") { Task { await showLogs(c) } }
                icon("dot.radiowaves.left.and.right", "Canlı log (terminalde)") {
                    dismiss(); router.runInTerminal(server, command: "docker logs -f --tail 100 \(c.name) || sudo docker logs -f --tail 100 \(c.name)", title: c.name)
                }
                if c.isRunning {
                    icon("chevron.left.forwardslash.chevron.right", "Container içinde kabuk (terminalde)") {
                        dismiss(); router.runInTerminal(server, command: "docker exec -it \(c.name) sh -c \"command -v bash >/dev/null && exec bash || exec sh\"", title: c.name)
                    }
                    icon("arrow.clockwise", "Yeniden başlat") { ask(c, "restart") }
                    icon("stop.fill", "Durdur") { ask(c, "stop") }
                } else {
                    icon("play.fill", "Başlat") { Task { await act(c, "start") } }
                    icon("trash", "Sil") { ask(c, "rm") }
                }
            }
            .disabled(working != nil)
        }
        .padding(10)
        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }.buttonStyle(.borderless).help(help)
    }

    private func ask(_ c: DockerContainer, _ verb: String) { confirm = (c, verb) }

    private func refresh() async {
        do {
            containers = try await model.dockerContainers(server.id)
            error = nil
        } catch { self.error = error.localizedDescription; autoRefresh = false }
        loaded = true
    }

    private func act(_ c: DockerContainer, _ verb: String) async {
        confirm = nil
        working = c.name
        defer { working = nil }
        do {
            try await model.dockerAction(server.id, verb, container: c.name)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func showLogs(_ c: DockerContainer) async {
        working = c.name
        defer { working = nil }
        do { logs = (c.name, try await model.dockerLogs(server.id, container: c.name)) }
        catch { self.error = error.localizedDescription }
    }
}
