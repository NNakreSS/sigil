import SigilCore
import SwiftUI

/// Update (preview → confirm → runs in a terminal tab) and restart (confirm → wait until it is back).
struct MaintenanceSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let server: Server
    let kind: MaintenanceRequest.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SigilMark(geometry: server.sigil, size: 48, reachable: server.lastReachable)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .update ? "“\(server.alias)” güncellensin mi?" : "“\(server.alias)” yeniden başlatılsın mı?")
                        .font(.engraved(22, weight: .bold))
                    if server.isProduction {
                        Chip(text: "Production", systemImage: "flame.fill", tint: .cinnabar)
                    }
                }
            }
            switch kind {
            case .update: UpdatePane(server: server)
            case .reboot: RebootPane(server: server)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.parchment)
    }
}

// MARK: - Update

private struct UpdatePane: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let server: Server

    @State private var packages: [UpgradablePackage]?
    @State private var errorText: String?
    @State private var productionOK = false

    private var securityCount: Int { packages?.filter(\.security).count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let packages {
                if packages.isEmpty {
                    Label("Sunucu güncel; kurulacak paket yok.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.verdigris)
                } else {
                    HStack(spacing: 6) {
                        Chip(text: "\(packages.count) paket", systemImage: "shippingbox", tint: .accentInk)
                        if securityCount > 0 {
                            Chip(text: "\(securityCount) güvenlik", systemImage: "shield.lefthalf.filled", tint: .amberInk)
                        }
                    }
                    list(packages)
                    Text("Güncelleme bir terminal sekmesinde çalışır: çıktıyı izlersin, sudo parolası sorulursa yazarsın. Sunucudaki yapılandırma dosyaların korunur. Bitince aynı sekmede sunucunun kabuğunda kalırsın.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if server.isProduction {
                        Toggle("Bu bir production sunucusu; güncelleme sırasında servisler kısa süre yeniden başlayabilir.", isOn: $productionOK)
                            .font(.callout)
                    }
                }
            } else if errorText == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(server.store.asksForApproval
                         ? "Güncellenecek paketler denetleniyor… (\(server.store == .secureEnclave ? "Touch ID" : "1Password onayı") istenecek)"
                         : "Güncellenecek paketler denetleniyor…")
                        .foregroundStyle(.secondary)
                }
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.cinnabar).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(packages?.isEmpty == true ? "Kapat" : "Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                if let packages, !packages.isEmpty {
                    Button("Güncellemeyi başlat") {
                        router.runInTerminal(server, command: MaintenanceScript.updateCommand, title: "güncelleme")
                        dismiss()
                    }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(server.isProduction && !productionOK)
                }
            }
        }
        .task { await load() }
    }

    private func list(_ packages: [UpgradablePackage]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(packages) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.security ? "shield.lefthalf.filled" : "shippingbox")
                            .foregroundStyle(p.security ? Color.amberInk : .secondary)
                            .frame(width: 16)
                        Text(p.name).font(.terminalSmall)
                        Spacer(minLength: 8)
                        Text(p.version).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 240)
        .background(Color.vellum, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
    }

    private func load() async {
        do { packages = try await model.upgradablePackages(server.id) }
        catch { errorText = error.localizedDescription }
    }
}

// MARK: - Restart

private struct RebootPane: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server

    private enum Phase: Equatable { case confirm, running(RebootPhase), done(TimeInterval), failed(String) }
    @State private var phase: Phase = .confirm
    @State private var typedAlias = ""
    @State private var startedAt = Date()

    private var running: Bool { if case .running = phase { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .confirm: confirm
            case .running(let p): progress(p)
            case .done(let downtime):
                Label("Sunucu geri geldi · \(Int(downtime)) saniye kapalı kaldı.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.verdigris).font(.callout.weight(.semibold))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.cinnabar).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                switch phase {
                case .confirm:
                    Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Yeniden başlat", role: .destructive) { Task { await restart() } }
                        .buttonStyle(.borderedProminent).tint(Color.cinnabar)
                        .keyboardShortcut(.defaultAction)
                        .disabled(server.isProduction && typedAlias != server.alias)
                case .running:
                    EmptyView()
                case .done:
                    Button("Sağlığı ölç") { Task { try? await model.collectHealth(server.id) }; dismiss() }
                    Button("Kapat") { dismiss() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Kapat") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .interactiveDismissDisabled(running)
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if server.health?.rebootRequired == true {
                let pkgs = server.health?.rebootPackages ?? []
                Label(pkgs.isEmpty ? "Sunucu yeniden başlatılmayı bekliyor."
                                   : "Yeniden başlatmayı isteyenler: \(pkgs.joined(separator: ", "))",
                      systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(Color.amberInk).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Sunucudaki açık oturumlar kapanır ve servisler birkaç dakika durur. Sigil sunucunun kapanıp yeniden açılmasını bekler, geri gelince haber verir. Beklerken anahtar kullanılmaz, Touch ID sorulmaz.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if server.isProduction {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Production sunucusu. Onaylamak için adını yaz: \(server.alias)").font(.callout)
                    TextField(server.alias, text: $typedAlias).textFieldStyle(.roundedBorder).font(.terminal)
                }
            }
        }
    }

    private func progress(_ p: RebootPhase) -> some View {
        let steps: [(RebootPhase, String)] = [
            (.requesting, "Yeniden başlatma isteniyor"), (.goingDown, "Sunucu kapanıyor"),
            (.comingUp, "Açılması bekleniyor"), (.verifying, "Geri geldi, doğrulanıyor"),
        ]
        let current = steps.firstIndex { $0.0 == p } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: 10) {
                    Group {
                        if i < current { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.verdigris) }
                        else if i == current { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }
                    .frame(width: 18)
                    Text(step.1).foregroundStyle(i <= current ? .primary : .secondary)
                    if i == current {
                        TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                            Text("\(Int(ctx.date.timeIntervalSince(startedAt))) sn").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func restart() async {
        startedAt = Date()
        phase = .running(.requesting)
        do {
            let downtime = try await model.reboot(server.id) { p in withAnimation(Motion.gentle) { phase = .running(p) } }
            withAnimation(Motion.stamp) { phase = .done(downtime) }
            Haptics.success()
            if !NSApplication.shared.isActive {
                Notifier.post("\(server.alias) geri geldi", "\(Int(downtime)) saniye kapalı kaldı.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if !NSApplication.shared.isActive { Notifier.post("\(server.alias) yeniden başlatılamadı", error.localizedDescription) }
        }
    }
}
