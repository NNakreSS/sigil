import SigilCore
import SwiftUI

struct DeleteServerSheet: View {
    static func explanation(_ store: KeyStoreKind) -> String {
        switch store {
        case .onePassword:
            return "ssh kısayolu ve kayıt silinir; 1Password’deki anahtar Arşiv’e taşınır (geri alınabilir). Sunucunun kendisine dokunulmaz."
        case .secureEnclave:
            return "Secure Enclave’deki anahtar kalıcı olarak silinir; ssh kısayolu ve kayıt da gider. Sunucunun kendisine dokunulmaz."
        case .keychain:
            return "Bu Mac’teki anahtar, ssh kısayolu ve kayıt silinir. Sunucunun kendisine dokunulmaz."
        }
    }

    @Environment(DeckModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server
    let onDeleted: () -> Void

    @State private var removeRemote = true
    @State private var working = false
    @State private var errorText: String?
    @State private var offerLocalOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SigilMark(geometry: server.sigil, size: 48, reachable: server.lastReachable)
                Text("“\(server.alias)” silinsin mi?").font(.engraved(22, weight: .bold))
            }

            Text(Self.explanation(server.store))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $removeRemote) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sunucudaki genel anahtarı da kaldır (önerilir)")
                    Text("Kaldırılmazsa, bu anahtarın bir kopyası olan biri sunucuya girmeye devam edebilir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(working)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                if offerLocalOnly {
                    Button("Yalnızca bu Mac’ten sil", role: .destructive) { Task { await delete(remote: false) } }
                        .disabled(working)
                }
                Button("Sil", role: .destructive) { Task { await delete(remote: removeRemote) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cinnabar)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Color.parchment)
        .interactiveDismissDisabled(working)
    }

    private func delete(remote: Bool) async {
        working = true
        errorText = nil
        defer { working = false }
        do {
            try await model.removeServer(server.id, removeRemoteKey: remote)
            dismiss()
            onDeleted()
        } catch let e as DeckError {
            errorText = e.localizedDescription
            if case .remoteRemovalFailed = e {
                offerLocalOnly = true
                errorText = (errorText ?? "") + " Hiçbir şey silinmedi. Tekrar dene ya da yalnızca bu Mac’ten sil."
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
