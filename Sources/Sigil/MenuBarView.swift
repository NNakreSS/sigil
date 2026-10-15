import SigilCore
import SwiftUI

struct MenuBarView: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var updater: UpdaterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SigilMark(geometry: .brand, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sigil").font(.engraved(15))
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.checkAll(interactive: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Hepsini denetle")
            }
            .padding(12)

            Divider()

            if !model.awaitingManualRotation.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Onay bekleyen yenilemeler", systemImage: "key.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.amberInk)
                    ForEach(model.awaitingManualRotation) { s in
                        HStack(spacing: 8) {
                            SigilMark(geometry: s.sigil, size: 20, busy: model.busy[s.id] != nil)
                            Text(s.alias).font(.engraved(13))
                            Spacer()
                            Button("Yenile") { Task { if await model.rotate(s.id) { Haptics.success() } } }
                                .controlSize(.small)
                                .disabled(model.busy[s.id] != nil)
                        }
                    }
                }
                .padding(12)
                Divider()
            }

            if !model.activeTunnels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Açık tüneller", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.verdigris)
                    ForEach(Array(model.activeTunnels.keys), id: \.self) { tid in
                        if let sid = model.activeTunnels[tid], let s = model.server(sid), let t = s.tunnels?.first(where: { $0.id == tid }) {
                            HStack {
                                Text("\(t.name)").font(.callout)
                                Text("localhost:\(t.localPort)").font(.terminalSmall).foregroundStyle(.secondary)
                                Spacer()
                                Button { model.stopTunnel(tid) } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(12)
                Divider()
            }

            if model.servers.isEmpty {
                Text("Henüz sunucu yok").foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.servers.sorted { $0.alias.lowercased() < $1.alias.lowercased() }) { s in
                            MenuRow(server: s, busy: model.busy[s.id] != nil) {
                                router.connect(s)
                                if TerminalApp.preferred == .embedded { show(s.id) }
                            } showDetails: {
                                show(s.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
            }

            Divider()
            HStack {
                Button("Pencereyi aç") { show(nil) }
                Button {
                    router.showingEmergency = true
                    show(nil)
                } label: { Image(systemName: "light.beacon.max") }
                    .help("Acil durum: tüm anahtarları yenile")
                    .disabled(model.servers.isEmpty)
                Spacer()
                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Image(systemName: "gearshape") }
                    .help("Ayarlar")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("Çık (arka plan denetimi durur)")
            }
            .buttonStyle(.borderless)
            .padding(12)

            Divider()
            HStack {
                Text("Sigil \(Platform.shortVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if updater.isAvailable {
                    Button("Güncellemeleri Denetle…") {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        updater.checkForUpdates()
                    }
                    .font(.caption)
                    .disabled(!updater.canCheckForUpdates)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 310)
    }

    private var summary: String {
        let down = model.servers.filter { $0.lastReachable == false }.count
        if model.servers.isEmpty { return "Sunucu yok" }
        return down == 0 ? "\(model.servers.count) sunucu, hepsi yerinde" : "\(down) sunucu ulaşılamıyor"
    }

    private func show(_ id: UUID?) {
        if let id { router.selection = id }
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct MenuRow: View {
    let server: Server
    let busy: Bool
    let connect: () -> Void
    let showDetails: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            SigilMark(geometry: server.sigil, size: 22, busy: busy, reachable: server.lastReachable)
            Text(server.alias).font(.engraved(13))
            Spacer()
            if hovering {
                Button(action: showDetails) { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).help("Ayrıntılar")
                    .transition(.opacity)
            }
            Circle().fill(ServerStatusStyle.color(server.lastReachable)).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovering ? Color.accentInk.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .onTapGesture(perform: connect)
        .help("Terminalde bağlan")
    }
}
