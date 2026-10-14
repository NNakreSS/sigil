import SigilCore
import SwiftUI

// MARK: - Tunnels

struct TunnelsCard: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    @State private var editing: TunnelProfile?
    @State private var error: String?

    var body: some View {
        Card(title: "Tüneller", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
            let tunnels = server.tunnels ?? []
            if tunnels.isEmpty {
                Text("Sunucudaki bir portu (ör. veritabanı) bu Mac’e getir: localhost:5433 → sunucu:5432.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(tunnels) { t in
                let running = model.activeTunnels[t.id] != nil
                HStack(spacing: 10) {
                    Circle().fill(running ? Color.verdigris : Color.hairline).frame(width: 9, height: 9)
                        .overlay { if running { PulseRing(color: .verdigris) } }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(.callout.weight(.medium))
                        Text(t.summary).font(.terminalSmall).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if running {
                        Button { Links.copy("localhost:\(t.localPort)"); Haptics.tap() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("localhost:\(t.localPort) kopyala")
                    }
                    Toggle("", isOn: Binding(get: { running }, set: { on in
                        Task {
                            error = nil
                            if on {
                                do { try await model.startTunnel(server.id, t.id); Haptics.tap() } catch { self.error = error.localizedDescription }
                            } else {
                                model.stopTunnel(t.id)
                            }
                        }
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    Menu {
                        Button("Düzenle…") { editing = t }
                        Button("Sil", role: .destructive) { model.deleteTunnel(server.id, t.id) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(8)
                .background(running ? Color.verdigris.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .animation(Motion.gentle, value: running)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.cinnabar) }
            Button {
                editing = TunnelProfile(name: "", localPort: suggestedPort, remotePort: 5432)
            } label: {
                Label("Tünel ekle", systemImage: "plus")
            }
        }
        .sheet(item: $editing) { t in TunnelEditor(server: server, tunnel: t) }
    }

    private var suggestedPort: Int {
        let used = Set(model.servers.flatMap { ($0.tunnels ?? []).map(\.localPort) })
        return (15432...15532).first { !used.contains($0) } ?? 15432
    }
}

private struct TunnelEditor: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server
    @State var tunnel: TunnelProfile
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tunnel.name.isEmpty ? "Yeni tünel" : tunnel.name).font(.engraved(20, weight: .bold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Ad").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("", text: $tunnel.name, prompt: Text("Veritabanı"))
                }
                GridRow {
                    Text("Bu Mac’te").foregroundStyle(.secondary)
                    HStack { Text("localhost :").font(.terminalSmall); TextField("", value: $tunnel.localPort, format: .number.grouping(.never)).frame(width: 80) }
                }
                GridRow {
                    Text("Sunucudan").foregroundStyle(.secondary)
                    HStack {
                        TextField("", text: $tunnel.remoteHost).frame(width: 160)
                        Text(":").font(.terminalSmall)
                        TextField("", value: $tunnel.remotePort, format: .number.grouping(.never)).frame(width: 80)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("“Sunucudan” adresi \(server.alias) üzerinden görülen adrestir; sunucunun kendisi için localhost.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(Color.cinnabar) }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    do { try model.saveTunnel(server.id, tunnel); dismiss() } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460).background(Color.parchment)
    }
}

// MARK: - Quick actions

struct ActionsSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAction: UUID?
    @State private var targets: Set<UUID> = []
    @State private var results: [UUID: ActionResult] = [:]
    @State private var running = false
    @State private var editing: QuickAction?
    @State private var confirmProduction = false

    private var action: QuickAction? { model.actions.first { $0.id == selectedAction } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedAction) {
                    ForEach(model.actions) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).font(.callout.weight(.medium))
                            Text(a.command).font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(a.id)
                        .contextMenu {
                            Button("Düzenle…") { editing = a }
                            Button("Sil", role: .destructive) { try? model.deleteAction(a.id) }
                        }
                    }
                }
                Divider()
                HStack {
                    Button { editing = QuickAction(name: "", command: "") } label: { Image(systemName: "plus") }
                    Button { if let a = action { editing = a } } label: { Image(systemName: "pencil") }.disabled(action == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(width: 230)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(action?.name ?? "Bir eylem seç").font(.engraved(20, weight: .bold))
                if let a = action {
                    Text(a.command).font(.terminalSmall).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Sunucular").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowWrap(model.servers.sorted { $0.alias < $1.alias }) { s in
                    let on = targets.contains(s.id)
                    Button {
                        if on { targets.remove(s.id) } else { targets.insert(s.id) }
                    } label: {
                        HStack(spacing: 6) {
                            SigilMark(geometry: s.sigil, size: 16, reachable: s.lastReachable)
                            Text(s.alias).font(.callout)
                            if s.isProduction { Text("PROD").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.cinnabar) }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(on ? Color.accentInk.opacity(0.15) : Color.vellum, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.accentInk : Color.hairline))
                    }
                    .buttonStyle(PressableStyle())
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.servers.filter { results[$0.id] != nil }) { s in
                            if let r = results[s.id] { resultView(s, r).transition(.move(edge: .bottom).combined(with: .opacity)) }
                        }
                    }
                    .animation(Motion.stamp, value: results.count)
                }
                .frame(maxHeight: .infinity)

                HStack {
                    Spacer()
                    Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button {
                        if model.servers.contains(where: { targets.contains($0.id) && $0.isProduction }) { confirmProduction = true }
                        else { Task { await run() } }
                    } label: {
                        if running { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Çalışıyor…") } }
                        else { Text(targets.count > 1 ? "\(targets.count) sunucuda çalıştır" : "Çalıştır") }
                    }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(action == nil || targets.isEmpty || running)
                }
            }
            .padding(20)
        }
        .frame(width: 820, height: 560)
        .background(Color.parchment)
        .onAppear {
            selectedAction = selectedAction ?? model.actions.first?.id
            if let sel = router.selection { targets = [sel] }
        }
        .sheet(item: $editing) { a in ActionEditor(action: a) { selectedAction = $0 } }
        .alert("Production sunucularında çalıştırılsın mı?", isPresented: $confirmProduction) {
            Button("Çalıştır", role: .destructive) { Task { await run() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(model.servers.filter { targets.contains($0.id) && $0.isProduction }.map(\.alias).joined(separator: ", "))
        }
    }

    private func resultView(_ s: Server, _ r: ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SigilMark(geometry: s.sigil, size: 18, reachable: r.succeeded)
                Text(s.alias).font(.engraved(14))
                Spacer()
                Text(String(format: "%.1f sn", r.duration)).font(.caption).foregroundStyle(.secondary)
                Chip(text: r.succeeded ? "0" : "\(r.exitCode)", systemImage: r.succeeded ? "checkmark" : "xmark",
                     tint: r.succeeded ? .verdigris : .cinnabar)
            }
            let text = (r.output + (r.errorOutput.isEmpty ? "" : "\n" + r.errorOutput)).trimmingCharacters(in: .whitespacesAndNewlines)
            ScrollView(.horizontal) {
                Text(text.isEmpty ? "(çıktı yok)" : text).font(.terminalSmall).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .padding(10)
        .background(Color(nsColor: TerminalTheme.background).opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline))
    }

    private func run() async {
        guard let a = action else { return }
        running = true
        results = [:]
        _ = await model.run(a, on: Array(targets)) { r in results[r.serverID] = r }
        running = false
        Haptics.success()
    }
}

private struct ActionEditor: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var action: QuickAction
    let saved: (UUID) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action.name.isEmpty ? "Yeni eylem" : action.name).font(.engraved(20, weight: .bold))
            TextField("Ad", text: $action.name, prompt: Text("nginx’i yeniden yükle")).textFieldStyle(.roundedBorder)
            Text("Komut").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $action.command)
                .font(.terminalSmall)
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.vellum, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
            Text("Sunucunun kabuğunda, Sigil’in bağlandığı kullanıcıyla çalışır. Yetki gerekiyorsa “sudo -n” kullan.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(Color.cinnabar).font(.callout) }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    do { try model.saveAction(action); saved(action.id); dismiss() } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(InkButtonStyle())
            }
        }
        .padding(22).frame(width: 520).background(Color.parchment)
    }
}

/// Simple wrapping row of chips.
struct FlowWrap<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
