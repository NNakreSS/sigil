import SigilCore
import SwiftUI

/// ⌘K palette: type a few letters, ↑/↓ to pick, Return opens Terminal connected, ⌘Return shows the server.
struct QuickConnectView: View {
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var matches: [Server] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.servers.sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        guard !q.isEmpty else { return all }
        // Prefix matches first, then substring matches on alias / host.
        let prefix = all.filter { $0.alias.lowercased().hasPrefix(q) }
        let rest = all.filter { !$0.alias.lowercased().hasPrefix(q) && ($0.alias.lowercased().contains(q) || $0.host.contains(q)) }
        return prefix + rest
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal").foregroundStyle(Color.accentInk)
                    TextField("Bağlanılacak sunucu…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { connect(openDetail: false) }
                    Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(16)

                Divider()

                if matches.isEmpty {
                    Text("Eşleşen sunucu yok").foregroundStyle(.secondary).padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { i, s in
                                    row(s, selected: i == index)
                                        .id(s.id)
                                        .onTapGesture { index = i; connect(openDetail: false) }
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: min(CGFloat(matches.count) * 54 + 16, 330))
                        .onChange(of: index) { _, new in
                            if matches.indices.contains(new) { withAnimation(Motion.quick) { proxy.scrollTo(matches[new].id) } }
                        }
                    }
                }

                Divider()
                HStack(spacing: 14) {
                    hint("↩", "Terminalde bağlan")
                    hint("⌘↩", "Ayrıntıları göster")
                    hint("↑↓", "Seç")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
            .frame(width: 520)
            .background(Color.vellum, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
            .padding(.top, 90)
        }
        .onAppear { focused = true; index = 0 }
        .onChange(of: query) { index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(matches.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            connect(openDetail: press.modifiers.contains(.command))
            return .handled
        }
    }

    private func row(_ s: Server, selected: Bool) -> some View {
        HStack(spacing: 12) {
            SigilMark(geometry: s.sigil, size: 28, reachable: s.lastReachable)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.alias).font(.engraved(14))
                Text("ssh \(s.alias)").font(.terminalSmall).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ServerStatusStyle.text(s.lastReachable))
                .font(.caption)
                .foregroundStyle(ServerStatusStyle.color(s.lastReachable))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentInk.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .animation(Motion.quick, value: selected)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func connect(openDetail: Bool) {
        guard matches.indices.contains(index) else { return }
        let s = matches[index]
        if openDetail {
            router.selection = s.id
        } else {
            router.connect(s)
        }
        close()
    }

    private func close() {
        router.showingQuickConnect = false
        query = ""
    }
}
