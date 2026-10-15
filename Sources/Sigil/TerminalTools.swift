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
        .background(TerminalTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, TerminalTheme.colorScheme)
        .tint(TerminalTheme.accent)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TerminalTheme.panelStroke))
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
        .background(TerminalTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, TerminalTheme.colorScheme)
        .tint(TerminalTheme.accent)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TerminalTheme.panelStroke))
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
                Image(systemName: "command").foregroundStyle(TerminalTheme.accent)
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
                Text("değiştirir").font(.caption2.weight(.semibold)).foregroundStyle(TerminalTheme.warn)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(TerminalTheme.warn.opacity(0.12), in: Capsule())
                    .help("Sunucuda bir şeyi değiştirir (yeniden başlatma, kurma, silme…)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(highlighted ? TerminalTheme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func askRow(_ q: String, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(TerminalTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Öner: “\(q)”").font(.callout.weight(.medium))
                Text(AssistantSettings.shared.askSubtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(highlighted ? TerminalTheme.accent.opacity(0.18) : TerminalTheme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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
            Text(c.filled(values)).font(.terminalSmall).foregroundStyle(TerminalTheme.accent)
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
                Image(systemName: "sparkles").foregroundStyle(TerminalTheme.accent)
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
                        Chip(text: isProduction ? "Değiştirir · production" : "Sunucuda değişiklik yapar", systemImage: "exclamationmark.triangle", tint: TerminalTheme.warn)
                    }
                    ForEach(answer.warnings, id: \.self) { Chip(text: $0, systemImage: "questionmark.diamond", tint: TerminalTheme.bad) }
                    if answer.warnings.isEmpty && !answer.command.isEmpty {
                        Chip(text: "Bilinen komutlar, sözdizimi geçerli", systemImage: "checkmark.seal", tint: TerminalTheme.good)
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
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(TerminalTheme.bad).font(.callout)
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
    @State private var hoveringClose = false

    private var context: AssistantContext {
        AssistantContext(health: terminals.active.flatMap { model.server($0.serverID)?.health })
    }
    private var selection: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if selection.isEmpty {
                emptyState
            } else {
                quote
                if let answer {
                    Text(answer.explanation).font(.callout).foregroundStyle(TerminalTheme.text)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    if !answer.command.isEmpty { suggestion(answer) }
                    Text(AssistantSettings.shared.sourceLabel).font(.caption2).foregroundStyle(TerminalTheme.muted)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(TerminalTheme.bad).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Okuyor…").foregroundStyle(TerminalTheme.muted)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(TerminalTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TerminalTheme.panelStroke))
        .overlay(alignment: .top) {
            // A thin line of the accent along the top edge.
            Capsule().fill(TerminalTheme.accent).frame(height: 2).padding(.horizontal, 22).offset(y: -1)
        }
        .shadow(color: .black.opacity(TerminalTheme.isLight ? 0.15 : 0.45), radius: 22, y: 10)
        .environment(\.colorScheme, TerminalTheme.colorScheme)
        .tint(TerminalTheme.accent)
        .onExitCommand { terminals.explaining = nil }
        .task(id: text) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(TerminalTheme.accent.opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(TerminalTheme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Açıkla").font(.headline).foregroundStyle(TerminalTheme.text)
                Text("Seçili terminal metni ne anlama geliyor?").font(.caption).foregroundStyle(TerminalTheme.muted)
            }
            Spacer()
            Button { terminals.explaining = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hoveringClose ? TerminalTheme.text : TerminalTheme.muted)
                    .frame(width: 24, height: 24)
                    .background(TerminalTheme.text.opacity(hoveringClose ? 0.12 : 0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("Kapat (esc)")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Önce açıklanacak metni seç").font(.callout.weight(.semibold)).foregroundStyle(TerminalTheme.text)
            HStack(spacing: 8) {
                step("1", "Bir hata satırını fareyle seç")
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(TerminalTheme.muted)
                step("2", "⇧⌘E")
            }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(n).font(.caption2.weight(.bold)).foregroundStyle(TerminalTheme.panel)
                .frame(width: 16, height: 16).background(TerminalTheme.accent, in: Circle())
            Text(text).font(.caption.weight(.medium)).foregroundStyle(TerminalTheme.text)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(TerminalTheme.text.opacity(0.07), in: Capsule())
    }

    private var quote: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(TerminalTheme.accent).frame(width: 3)
            Text(selection).font(.system(size: 12, design: .monospaced)).foregroundStyle(TerminalTheme.muted)
                .lineLimit(4).truncationMode(.tail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func suggestion(_ answer: AssistantAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(answer.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(TerminalTheme.text)
                    .textSelection(.enabled).lineLimit(3)
                Spacer(minLength: 8)
                Button("Terminale yaz") { terminals.explaining = nil; terminals.type(answer.command, run: false) }
                    .buttonStyle(.borderedProminent).tint(TerminalTheme.accent).controlSize(.small)
            }
            .padding(10)
            .background(TerminalTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TerminalTheme.accent.opacity(0.35)))
            ForEach(answer.warnings, id: \.self) {
                Label($0, systemImage: "questionmark.diamond").font(.caption).foregroundStyle(TerminalTheme.warn)
            }
        }
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
