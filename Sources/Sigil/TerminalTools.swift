import SigilCore
import SwiftUI

/// macOS also ends text editing (and fires onSubmit) when a field loses focus, e.g. on a click elsewhere in the
/// palette; only a real Return should act.
enum ReturnKey {
    static var pressed: Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown else { return false }
        return e.keyCode == 36 || e.keyCode == 76   // Return, keypad Enter
    }
}

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
                .onSubmit { if ReturnKey.pressed { terminals.find(backwards: NSEvent.modifierFlags.contains(.shift)) } }
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

/// One row of the palette: a command the user saved, or one from the library.
private struct PaletteItem: Identifiable {
    enum Source { case saved(QuickAction), library(CommandTemplate) }
    let source: Source

    var id: String {
        switch source {
        case .saved(let a): return "saved|" + a.id.uuidString
        case .library(let c): return "lib|" + c.id
        }
    }
    var title: String {
        switch source {
        case .saved(let a): return a.name
        case .library(let c): return c.title
        }
    }
    var display: String {
        switch source {
        case .saved(let a): return a.command
        case .library(let c): return c.template.replacingOccurrences(of: "{{", with: "‹").replacingOccurrences(of: "}}", with: "›")
        }
    }
    var group: String {
        switch source {
        case .saved: return "Kayıtlı komutlarım"
        case .library(let c): return c.category.rawValue
        }
    }
    var symbol: String {
        switch source {
        case .saved: return "star"
        case .library(let c): return c.category.symbol
        }
    }
    var changesSystem: Bool { if case .library(let c) = source { return c.changesSystem } else { return false } }
    var template: CommandTemplate? { if case .library(let c) = source { return c } else { return nil } }
}

/// ⌘P: every command that fits this server, grouped and searchable. Return types the command at the prompt (nothing
/// runs until you press Return in the terminal); ⌘Return types and runs it. Commands with blanks ask for them first.
struct CommandPalette: View {
    @Environment(TerminalSessions.self) private var terminals
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selected = 0
    @State private var filling: CommandTemplate?
    @State private var values: [String: String] = [:]
    @FocusState private var field: Int?
    /// The plain-language request sent to the assistant, while its answer is shown.
    @State private var asked: String?

    private var assistantOn: Bool { AssistantSettings.shared.isEnabled }
    private var askable: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        return assistantOn && q.count >= 4 && q.contains(" ") ? q : nil
    }

    private var server: Server? { terminals.active.flatMap { model.server($0.serverID) } }
    private var profile: ServerProfile? { ServerProfile(server?.health) }

    private var items: [PaletteItem] {
        let saved = model.actions.filter { a in
            query.isEmpty || a.name.localizedCaseInsensitiveContains(query) || a.command.localizedCaseInsensitiveContains(query)
        }
        let library = CommandLibrary.search(query, in: CommandLibrary.relevant(for: profile))
        return saved.map { PaletteItem(source: .saved($0)) } + library.map { PaletteItem(source: .library($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let asked {
                AssistantAnswerView(request: asked, context: AssistantContext(health: server?.health),
                                    isProduction: server?.isProduction == true) { command in
                    terminals.showingPalette = false
                    self.asked = nil
                    terminals.type(command, run: false)
                } save: { command in
                    try? model.saveAction(QuickAction(name: asked, command: command))
                }
            } else if let filling { form(filling) } else { list }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
        .onExitCommand {
            if asked != nil { asked = nil; focused = true }
            else if filling != nil { filling = nil; focused = true }
            else { terminals.showingPalette = false }
        }
    }

    // MARK: List

    private var list: some View {
        let items = self.items
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(Color.accentInk)
                TextField("Ne yapmak istiyorsun? (ör. disk, nginx log, port)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { if ReturnKey.pressed { choose(items, run: NSEvent.modifierFlags.contains(.command)) } }
                    .onChange(of: query) { _, _ in selected = 0 }
            }
            .padding(14)
            if profile == nil, let server {
                Label("“\(server.alias)” için hangi araçların kurulu olduğu bilinmiyor; tüm komutlar gösteriliyor. Sağlık kartında “Yenile”ye basınca liste sunucuya göre daralır.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            if query.isEmpty, i == 0 || items[i - 1].group != item.group {
                                Label(item.group, systemImage: item.symbol)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, i == 0 ? 4 : 12).padding(.bottom, 2)
                            }
                            row(item, highlighted: i == selected)
                                .id(item.id)
                                .onTapGesture { selected = i; choose(items, run: false) }
                        }
                        if let q = askable {
                            askRow(q, highlighted: selected == items.count).id("ask")
                                .onTapGesture { asked = q }
                        }
                        if items.isEmpty { saveRow }
                    }
                    .padding(6)
                }
                .frame(height: 380)
                .onChange(of: selected) { _, i in
                    if items.indices.contains(i) { withAnimation(Motion.quick) { proxy.scrollTo(items[i].id) } }
                    else if i == items.count { withAnimation(Motion.quick) { proxy.scrollTo("ask") } }
                }
            }
            Divider()
            footer
        }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - (askable == nil ? 1 : 0), 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
    }

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium))
                Text(item.display).font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if item.changesSystem {
                Text("değiştirir").font(.caption2.weight(.semibold)).foregroundStyle(Color.amberInk)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.amberInk.opacity(0.12), in: Capsule())
                    .help("Sunucuda bir şeyi değiştirir (yeniden başlatma, kurma, silme…)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(highlighted ? Color.accentInk.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func askRow(_ q: String, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentInk)
            VStack(alignment: .leading, spacing: 2) {
                Text("Öner: “\(q)”").font(.callout.weight(.medium))
                Text(AssistantSettings.shared.askSubtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(highlighted ? Color.accentInk.opacity(0.18) : Color.accentInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var saveRow: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Eşleşen komut yok. ⏎ ile “\(q)” terminale yazılır.").font(.callout).foregroundStyle(.secondary)
                Button { try? model.saveAction(QuickAction(name: q, command: q)) } label: {
                    Label("“\(q)” komutunu kaydet", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "seç")
            hint("⏎", "yaz")
            hint("⌘⏎", "yaz ve çalıştır")
            hint("esc", "kapat")
            Spacer()
            Button("Komutlarımı düzenle…") { terminals.showingPalette = false; router.showingActions = true }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Filling in blanks

    private func form(_ c: CommandTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { filling = nil; focused = true } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(c.title).font(.engraved(16))
                Spacer()
            }
            ForEach(Array(c.parameters.enumerated()), id: \.element.name) { i, p in
                LabeledContent(p.name.prefix(1).uppercased() + p.name.dropFirst()) {
                    TextField(p.defaultValue ?? p.name, text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.terminal)
                        .focused($field, equals: i)
                        .onSubmit { if ReturnKey.pressed { finish(c, run: NSEvent.modifierFlags.contains(.command)) } }
                }
            }
            Text(c.filled(values)).font(.terminalSmall).foregroundStyle(Color.accentInk)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 14) {
                hint("⏎", "yaz")
                hint("⌘⏎", "yaz ve çalıştır")
                hint("esc", "geri")
                Spacer()
            }
        }
        .padding(16)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func choose(_ items: [PaletteItem], run: Bool) {
        if selected == items.count, let q = askable { asked = q; return }
        guard items.indices.contains(selected) else {
            let q = query.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { send(q, run: run, changes: false) }
            return
        }
        let item = items[selected]
        switch item.source {
        case .saved(let a):
            send(a.command, run: run, changes: false)
        case .library(let c):
            if c.parameters.isEmpty {
                send(c.template, run: run, changes: c.changesSystem)
            } else {
                values = [:]
                filling = c
                DispatchQueue.main.async { field = 0 }
            }
        }
    }

    private func finish(_ c: CommandTemplate, run: Bool) {
        send(c.filled(values), run: run, changes: c.changesSystem)
    }

    /// On production servers a command that changes something is only typed, never run from here.
    private func send(_ command: String, run: Bool, changes: Bool) {
        guard terminals.showingPalette else { return }   // already chosen: never type twice
        let mayRun = run && !(changes && server?.isProduction == true)
        terminals.showingPalette = false
        filling = nil
        terminals.type(command, run: mayRun)
    }
}

/// Under the prompt: the command Tab would complete, and what it does.
struct SuggestionHint: View {
    let suggestion: TerminalSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Text("⇥").font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            (Text(suggestion.input).foregroundColor(Color(nsColor: TerminalTheme.foreground).opacity(0.55))
             + Text(String(suggestion.candidate.display.dropFirst(suggestion.input.count))).foregroundColor(Color(nsColor: TerminalTheme.foreground)))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
            Text(suggestion.candidate.title).font(.caption).foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.55))
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: TerminalTheme.chrome).opacity(0.95), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}


/// An assistant's suggestion for a plain-language request: editable, checked, and only ever typed (never run).
struct AssistantAnswerView: View {
    let request: String
    let context: AssistantContext
    let isProduction: Bool
    let type: (String) -> Void
    let save: (String) -> Void

    @State private var answer: AssistantAnswer?
    @State private var command = ""
    @State private var error: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentInk)
                Text(request).font(.engraved(16)).lineLimit(2)
                Spacer()
            }
            if let answer {
                TextField("", text: $command, axis: .vertical)
                    .font(.terminal).textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .focused($focused)
                    .onSubmit { if ReturnKey.pressed && !command.isEmpty { type(command) } }
                Text(answer.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    if answer.changesSystem {
                        Chip(text: isProduction ? "Değiştirir · production" : "Sunucuda değişiklik yapar", systemImage: "exclamationmark.triangle", tint: .amberInk)
                    }
                    ForEach(answer.warnings, id: \.self) { Chip(text: $0, systemImage: "questionmark.diamond", tint: .cinnabar) }
                    if answer.warnings.isEmpty && !answer.command.isEmpty {
                        Chip(text: "Bilinen komutlar, sözdizimi geçerli", systemImage: "checkmark.seal", tint: .verdigris)
                    }
                }
                Text("Deneysel öneri: çalıştırmadan önce oku. ⏎ komutu terminale yazar, çalıştırmaz.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(AssistantSettings.shared.sourceLabel).font(.caption2).foregroundStyle(.tertiary)
                HStack {
                    Button(saved ? "Kaydedildi" : "Komutlarıma kaydet") { save(command); saved = true }
                        .disabled(command.isEmpty || saved).buttonStyle(.borderless).font(.caption)
                    Spacer()
                    Button("Terminale yaz") { type(command) }.buttonStyle(InkButtonStyle()).disabled(command.isEmpty)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Düşünüyor…").foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .task(id: request) { await load() }
    }

    private func load() async {
        guard let assistant = AssistantSettings.shared.makeAssistant() else {
            error = "Kod yardımı kapalı: Ayarlar → Terminal → Kod yardımı."
            return
        }
        do {
            let a = try await assistant.suggest(request, context: context)
            answer = a
            command = a.command
            focused = true
        } catch { self.error = error.localizedDescription }
    }
}

/// ⇧⌘E: what the selected terminal text means, and a command that may help.
struct ExplainPanel: View {
    @Environment(TerminalSessions.self) private var terminals
    @Environment(DeckModel.self) private var model
    let text: String

    @State private var answer: AssistantAnswer?
    @State private var error: String?

    private var context: AssistantContext {
        AssistantContext(health: terminals.active.flatMap { model.server($0.serverID)?.health })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Açıkla", systemImage: "sparkles").font(.engraved(15)).foregroundStyle(Color.accentInk)
                Spacer()
                Button { terminals.explaining = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.terminalSmall).foregroundStyle(.secondary)
                .lineLimit(4).truncationMode(.tail)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Önce terminalde açıklanacak metni (ör. bir hata satırını) fareyle seç, sonra ⇧⌘E’ye bas.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if let answer {
                Text(answer.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !answer.command.isEmpty {
                    HStack {
                        Text(answer.command).font(.terminalSmall).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Terminale yaz") { terminals.explaining = nil; terminals.type(answer.command, run: false) }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.accentInk.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    ForEach(answer.warnings, id: \.self) { Label($0, systemImage: "questionmark.diamond").font(.caption).foregroundStyle(Color.cinnabar) }
                }
                Text(AssistantSettings.shared.sourceLabel).font(.caption2).foregroundStyle(.tertiary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Okuyor…").foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .onExitCommand { terminals.explaining = nil }
        .task(id: text) { await load() }
    }

    private func load() async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let assistant = AssistantSettings.shared.makeAssistant() else {
            error = "Kod yardımı kapalı: Ayarlar → Terminal → Kod yardımı."
            return
        }
        do { answer = try await assistant.explain(text, context: context) }
        catch { self.error = error.localizedDescription }
    }
}
