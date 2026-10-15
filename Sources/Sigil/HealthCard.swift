import Charts
import SigilCore
import SwiftUI

struct HealthCard: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    let server: Server
    @State private var error: String?

    var body: some View {
        Card(title: "Sağlık", systemImage: "waveform.path.ecg", help: .health) {
            if let h = server.health {
                HStack(spacing: 22) {
                    Gauge(title: "Disk", value: h.diskUsage, detail: h.diskTotalKB.map { "\(gb($0 - (h.diskUsedKB ?? 0))) boş" })
                    Gauge(title: "Bellek", value: h.memoryUsage, detail: h.memTotalKB.map { "\(gb($0)) toplam" })
                    Gauge(title: "Yük", value: h.loadRatio.map { min($0, 1) },
                          detail: h.load.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " ") }, label: h.loadRatio.map { String(format: "%.0f%%", $0 * 100) })
                    VStack(alignment: .leading, spacing: 6) {
                        if let os = h.os { Label(os, systemImage: "cpu").font(.callout) }
                        if let up = h.uptimeSeconds { Label("\(uptimeText(up)) açık", systemImage: "clock").font(.callout) }
                        FlowLayout(spacing: 6) {
                            if let s = h.securityUpdates, let u = h.updates {
                                let chip = Chip(text: u == 0 ? "Güncel" : (s > 0 ? "\(u) güncelleme · \(s) güvenlik" : "\(u) güncelleme"),
                                                systemImage: "arrow.down.circle", tint: s > 0 ? .amberInk : .verdigris)
                                if u > 0 {
                                    Button { maintain(.update) } label: { chip }.buttonStyle(.plain).help("Güncellemeleri gör ve kur")
                                } else {
                                    chip
                                }
                            }
                            if h.rebootRequired == true {
                                Button { maintain(.reboot) } label: {
                                    Chip(text: "Yeniden başlatma gerekli", systemImage: "arrow.clockwise.circle", tint: .amberInk)
                                }
                                .buttonStyle(.plain).help("Yeniden başlat")
                            }
                            if let f = h.failedUnits, f > 0 { Chip(text: "\(f) servis çalışmıyor", systemImage: "xmark.octagon", tint: .cinnabar) }
                        }
                    }
                    Spacer(minLength: 0)
                }

                HealthDetails(health: h)

                if let history = server.healthHistory, history.count > 1 {
                    Chart {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, s in
                            if let d = s.disk { LineMark(x: .value("Zaman", s.at), y: .value("%", d * 100), series: .value("", "Disk")).foregroundStyle(Color.accentInk) }
                            if let m = s.memory { LineMark(x: .value("Zaman", s.at), y: .value("%", m * 100), series: .value("", "Bellek")).foregroundStyle(Color.verdigris) }
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                    .chartXAxis(.hidden)
                    .chartForegroundStyleScale(["Disk": Color.accentInk, "Bellek": Color.verdigris])
                    .frame(height: 70)
                }

                if !h.certificates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(h.certificates, id: \.name) { c in
                            let days = h.daysLeft(c)
                            HStack {
                                Image(systemName: "lock.doc").foregroundStyle(days < 14 ? Color.cinnabar : .secondary)
                                Text(c.name).font(.terminalSmall)
                                Spacer()
                                Text(days < 0 ? "süresi doldu" : "\(days) gün").font(.caption)
                                    .foregroundStyle(days < 14 ? Color.cinnabar : .secondary)
                            }
                        }
                    }
                }
                Text("Ölçüldü \(h.collectedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Disk, bellek, yük, güncellemeler ve sertifikalar. Ölçüm sunucuda hiçbir şeyi değiştirmez.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.cinnabar) }
            HStack(spacing: 10) {
                Button {
                    Task {
                        error = nil
                        do { try await model.collectHealth(server.id) } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label(server.health == nil ? "Ölç" : "Yenile", systemImage: "stethoscope")
                }
                if (server.health?.updates ?? 0) > 0 {
                    Button { maintain(.update) } label: { Label("Güncelle…", systemImage: "arrow.down.circle") }
                }
                if server.health?.rebootRequired == true {
                    Button { maintain(.reboot) } label: { Label("Yeniden başlat…", systemImage: "arrow.clockwise.circle") }
                }
            }
            .disabled(model.busy[server.id] != nil)
        }
    }

    private func maintain(_ kind: MaintenanceRequest.Kind) {
        router.maintenance = .init(serverID: server.id, kind: kind)
    }

    private func gb(_ kb: Double) -> String {
        let g = kb / 1_048_576
        return g >= 10 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g)
    }

    private func uptimeText(_ s: Double) -> String {
        let d = Int(s / 86400), h = Int(s.truncatingRemainder(dividingBy: 86400) / 3600)
        return d > 0 ? "\(d) gün \(h) saat" : "\(h) saat"
    }
}

/// What is behind each chip: which services failed, which packages want the reboot, which have security fixes.
private struct HealthDetails: View {
    let health: ServerHealth

    var body: some View {
        let failed = health.failedUnitList ?? []
        let reboot = health.rebootRequired == true ? (health.rebootPackages ?? []) : []
        let security = health.securityPackages ?? []
        if !failed.isEmpty || !reboot.isEmpty || !security.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !failed.isEmpty {
                    section("Çalışmayan servisler", systemImage: "xmark.octagon", tint: .cinnabar,
                            hint: "Nedenini görmek için: systemctl status <servis>") {
                        ForEach(failed, id: \.name) { u in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(u.name).font(.terminalSmall).textSelection(.enabled)
                                if !u.description.isEmpty {
                                    Text(u.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if !reboot.isEmpty {
                    section("Yeniden başlatmayı isteyen güncellemeler", systemImage: "arrow.clockwise.circle", tint: .amberInk,
                            hint: "Bu paketler yeniden başlatılana kadar eski sürümleriyle çalışır.") {
                        packages(reboot, total: reboot.count)
                    }
                }
                if !security.isEmpty {
                    section("Güvenlik güncellemesi bekleyenler", systemImage: "shield.lefthalf.filled", tint: .amberInk,
                            hint: "Kurmak için: sudo apt upgrade") {
                        packages(security, total: max(health.securityUpdates ?? 0, security.count))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func section<Content: View>(_ title: String, systemImage: String, tint: Color, hint: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage).font(.callout.weight(.semibold)).foregroundStyle(tint)
            content().padding(.leading, 24)
            Text(hint).font(.caption2).foregroundStyle(.secondary).padding(.leading, 24)
        }
    }

    private func packages(_ names: [String], total: Int) -> some View {
        let more = total - names.count
        return Text(names.joined(separator: ", ") + (more > 0 ? " ve \(more) paket daha" : ""))
            .font(.terminalSmall)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ring gauge that fills with a spring; colour follows the level.
private struct Gauge: View {
    let title: String
    let value: Double?
    let detail: String?
    var label: String?
    @State private var shown = 0.0

    private var tint: Color {
        guard let v = value else { return .secondary }
        return v >= 0.9 ? .cinnabar : (v >= 0.75 ? .amberInk : .verdigris)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.hairline, lineWidth: 7)
                Circle().trim(from: 0, to: shown)
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label ?? value.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
            }
            .frame(width: 62, height: 62)
            Text(title).font(.caption.weight(.semibold))
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .onAppear { withAnimation(Motion.morph) { shown = value ?? 0 } }
        .onChange(of: value) { _, v in withAnimation(Motion.morph) { shown = v ?? 0 } }
    }
}
