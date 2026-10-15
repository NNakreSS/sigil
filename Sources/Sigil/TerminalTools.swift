import SigilCore
import SwiftUI

/// ⌘F: find in the active terminal's scrollback. Return = next, ⇧Return = previous, Esc closes.
struct TerminalFindBar: View {
    @Environment(TerminalSessions.self) private var terminals
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var terminals = terminals
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Terminalde ara", text: $terminals.findTerm)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { terminals.find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: terminals.findTerm) { _, _ in terminals.find() }
            Text(terminals.findTerm.isEmpty ? "" : "\(terminals.findSummary.index)/\(terminals.findSummary.total)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Button { terminals.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Önceki (⇧⌘G)")
            Button { terminals.find() } label: { Image(systemName: "chevron.down") }
                .help("Sonraki (⌘G)")
            Button { terminals.endFind() } label: { Image(systemName: "xmark") }
                .help("Kapat (esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .onAppear { focused = true }
        .onExitCommand { terminals.endFind() }
    }
}

/// ⌘P: saved commands, searchable. Return types the command at the prompt (nothing runs until you press Return
/// in the terminal); ⌘Return types and runs it. An unknown query can be saved as a new command.
struct CommandPalette: View {
    @Environment(TerminalSessions.self) private var terminals
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selected = 0

    private var matches: [QuickAction] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.actions }
        return model.actions.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.command.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(Color.accentInk)
                TextField("Komut ara ya da yaz", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { choose(run: NSEvent.modifierFlags.contains(.command)) }
                    .onChange(of: query) { _, _ in selected = 0 }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { i, a in
                            row(a, highlighted: i == selected)
                                .id(i)
                                .onTapGesture { selected = i; choose(run: false) }
                        }
                        if matches.isEmpty { saveRow }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: selected) { _, i in withAnimation(Motion.quick) { proxy.scrollTo(i) } }
            }
            Divider()
            HStack(spacing: 14) {
                hint("⏎", "yaz")
                hint("⌘⏎", "yaz ve çalıştır")
                hint("esc", "kapat")
                Spacer()
                Button("Komutları düzenle…") { terminals.showingPalette = false; router.showingActions = true }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
        .onExitCommand { terminals.showingPalette = false }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(matches.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
    }

    private func row(_ a: QuickAction, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a.name).font(.callout.weight(.medium))
            Text(a.command).font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(highlighted ? Color.accentInk.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var saveRow: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            Text("Kayıtlı komut yok.").font(.callout).foregroundStyle(.secondary).padding(10)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Eşleşen komut yok. ⏎ ile “\(q)” terminale yazılır.").font(.callout).foregroundStyle(.secondary)
                Button {
                    try? model.saveAction(QuickAction(name: q, command: q))
                } label: {
                    Label("“\(q)” komutunu kaydet", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose(run: Bool) {
        let command: String
        if matches.indices.contains(selected) {
            command = matches[selected].command
        } else {
            command = query.trimmingCharacters(in: .whitespaces)
        }
        guard !command.isEmpty else { return }
        terminals.showingPalette = false
        terminals.type(command, run: run)
    }
}
