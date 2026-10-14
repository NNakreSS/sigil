import SigilCore
import SwiftUI

/// Name, group and environment. The key and the server itself are not touched.
struct EditServerSheet: View {
    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server

    @State private var alias = ""
    @State private var group = ""
    @State private var environment: ServerEnvironment?
    @State private var jumpID: UUID?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                SigilMark(geometry: server.sigil, size: 46, reachable: server.lastReachable)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Düzenle").font(.engraved(22, weight: .bold))
                    Text("\(server.user)@\(server.host)").font(.terminalSmall).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Kısayol").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $alias).textFieldStyle(.roundedBorder)
                        Text("Terminalde: ssh \(alias.trimmingCharacters(in: .whitespaces))").font(.terminalSmall).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Grup").foregroundStyle(.secondary)
                    HStack {
                        TextField("", text: $group, prompt: Text("Grupsuz")).textFieldStyle(.roundedBorder)
                        if !model.groups.isEmpty {
                            Menu {
                                ForEach(model.groups, id: \.self) { g in Button(g) { group = g } }
                                Divider()
                                Button("Grupsuz") { group = "" }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Var olan bir grup seç")
                        }
                    }
                }
                GridRow {
                    Text("Üzerinden").foregroundStyle(.secondary)
                    Picker("", selection: $jumpID) {
                        Text("Doğrudan").tag(UUID?.none)
                        ForEach(model.servers.filter { $0.id != server.id && $0.jumpServerID == nil }) { Text($0.alias).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(!model.dependents(of: server.id).isEmpty)
                }
                GridRow {
                    Text("Ortam").foregroundStyle(.secondary)
                    Picker("", selection: $environment) {
                        Text("Belirtilmemiş").tag(ServerEnvironment?.none)
                        ForEach(ServerEnvironment.allCases) { Text($0.title).tag(ServerEnvironment?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if environment == .production {
                Label("Production sunucularına bağlanmadan önce onay istenir; sekmeleri kırmızı çizgiyle işaretlenir.",
                      systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(Color.cinnabar)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Color.cinnabar)
            }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { save() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.parchment)
        .animation(Motion.gentle, value: environment)
        .onAppear {
            alias = server.alias
            group = server.group ?? ""
            environment = server.environment
            jumpID = server.jumpServerID
        }
    }

    private func save() {
        do {
            try model.rename(server.id, to: alias)
            model.setGroup(server.id, group)
            model.setEnvironment(server.id, environment)
            if jumpID != server.jumpServerID { try model.setJump(server.id, jumpID) }
            Haptics.tap()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
