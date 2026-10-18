import AppKit
import SigilCore
import SwiftUI

/// A file on a server, opened in the editor window.
struct RemoteFileRef: Codable, Hashable {
    let serverID: UUID
    let path: String
}

/// Edits a text file on the server, IDE-style: colours by file type, line numbers, find/replace, lint while typing, and
/// the server's own validator after saving (nginx -t, sshd -t…). ⌘S saves it back with owner and mode kept, refusing
/// when the file changed meanwhile.
struct FileEditorWindow: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    let path: String

    @AppStorage("editorWrap") private var wrap = false
    @AppStorage("previewFontSize") private var size = 12.0
    @State private var controller = EditorController()
    @State private var text = ""
    @State private var saved = ""
    /// The content before the last save, for "geri al" when the server's validator rejects it.
    @State private var previous: String?
    @State private var version = ""
    @State private var readOnly: String?
    @State private var language: CodeLanguage = .plain
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var status: String?
    @State private var confirmReload = false
    @State private var localDiagnostics: [Diagnostic] = []
    @State private var check: ConfigCheckResult?
    @State private var checking = false
    @State private var showProblems = true
    @State private var goToLine = false
    @State private var lineField = ""
    @State private var lintTask: Task<Void, Never>?

    private var dirty: Bool { text != saved }
    private var name: String { (path as NSString).lastPathComponent }
    private var configCheck: ConfigCheck? { ConfigCheck.forFile(path, language: language) }
    private var diagnostics: [Diagnostic] {
        (localDiagnostics + (check?.diagnostics ?? [])).sorted { ($0.line, $0.message) < ($1.line, $1.message) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let readOnly { banner(readOnly, "lock.fill", .amberInk) }
            if let check { checkBanner(check) }
            ZStack {
                CodeTextView(text: $text, editable: readOnly == nil && !loading, wrap: wrap, fontSize: size,
                             language: language, controller: controller)
                if loading { ProgressView() }
            }
            if showProblems && !diagnostics.isEmpty { problems }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(WindowBackdrop())
        .navigationTitle("\(server.alias) · \(name)")
        .background(WindowCloseGuard(isDirty: { text != saved }, save: { await save() }))
        .task { await load() }
        .onAppear {
            model.holdSession(server.id)
            controller.onSave = { Task { await save() } }
            controller.onGoToLine = { lineField = ""; goToLine = true }
        }
        .onDisappear { model.releaseSession(server.id) }
        .onChange(of: text) { _, _ in scheduleLint() }
        .onChange(of: language) { _, _ in controller.language = language; scheduleLint() }
        .onChange(of: diagnostics) { _, d in controller.diagnostics = d }
        .alert("Kaydedilmemiş değişiklikler atılsın mı?", isPresented: $confirmReload) {
            Button("Yeniden yükle", role: .destructive) { Task { await load() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Dosya sunucudan yeniden okunur; buradaki değişikliklerin kaybolur.")
        }
        .alert("Satıra git", isPresented: $goToLine) {
            TextField("Satır numarası", text: $lineField)
            Button("Git") { if let n = Int(lineField.trimmingCharacters(in: .whitespaces)) { controller.goTo(line: n) } }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Color.accentInk)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.semibold))
                    if dirty { Circle().fill(Color.amberInk).frame(width: 7, height: 7).help("Kaydedilmemiş değişiklik var") }
                }
                Text("\(server.alias):\(path)").font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if server.isProduction { Chip(text: "Production", systemImage: "flame.fill", tint: .cinnabar) }
            Spacer()
            Group {
                Button { controller.find(.showFindInterface) } label: { Image(systemName: "magnifyingglass") }
                    .help("Bul (⌘F) · Değiştir (⌥⌘F) · Sonraki (⌘G)")
                Button { controller.toggleComment() } label: { Image(systemName: "number") }
                    .help("Yorum satırı yap / kaldır (⌘/)").disabled(language.lineComment == nil || readOnly != nil)
                Button { lineField = ""; goToLine = true } label: { Image(systemName: "arrow.down.to.line") }
                    .help("Satıra git (⌘L)")
                Toggle(isOn: $wrap) { Image(systemName: "text.word.spacing") }.toggleStyle(.button)
                    .help("Satırları kaydır")
                Button { if dirty { confirmReload = true } else { Task { await load() } } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Sunucudan yeniden yükle")
            }
            .buttonStyle(.borderless)
            Button { Task { await save() } } label: {
                if saving { ProgressView().controlSize(.small) } else { Label("Kaydet", systemImage: "square.and.arrow.down") }
            }
            .buttonStyle(InkButtonStyle())
            .disabled(!dirty || saving || readOnly != nil)
            .help("Kaydet (⌘S)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func banner(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
            .background(tint.opacity(0.08))
    }

    @ViewBuilder private func checkBanner(_ c: ConfigCheckResult) -> some View {
        let tint: Color = c.passed == true ? .verdigris : c.passed == false ? .cinnabar : .secondary
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.passed == true ? "checkmark.seal.fill" : c.passed == false ? "xmark.octagon.fill" : "questionmark.circle")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.passed == true ? "\(c.check.title): yapılandırma geçerli."
                     : c.passed == false ? "\(c.check.title) yeni yapılandırmayı kabul etmedi. Servisi yeniden başlatma; önce düzelt ya da geri al."
                     : "\(c.check.title) bu sunucuda çalıştırılamadı (kurulu değil ya da sudo şifre istiyor).")
                    .font(.callout.weight(.medium))
                if c.passed != true, !c.output.isEmpty {
                    Text(c.output).font(.terminalSmall).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
                }
            }
            Spacer()
            if c.passed == false, previous != nil {
                Button("Önceki hâline geri al") { Task { await revert() } }.buttonStyle(GlassButtonStyle())
            }
            if c.passed == true, let reload = c.check.reloadTitle {
                Button(reload) { Task { await reloadService(c.check) } }.buttonStyle(GlassButtonStyle())
            }
            Button { check = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }

    private var problems: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(diagnostics) { d in
                        Button { controller.goTo(line: d.line) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: d.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(d.severity == .error ? Color.cinnabar : Color.amberInk)
                                Text("Satır \(d.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                Text(d.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 120)
        }
        .background(Color.vellum.opacity(0.6))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).lineLimit(2)
            } else if let status {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(Color.verdigris)
            } else if checking {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Sunucuda denetleniyor…") }.foregroundStyle(.secondary)
            } else {
                Text(dirty ? "Değiştirildi · ⌘S ile kaydet" : "Sunucudaki dosyayla aynı").foregroundStyle(.secondary)
            }
            Spacer()
            let errors = diagnostics.filter { $0.severity == .error }.count, warnings = diagnostics.count - errors
            Button { showProblems.toggle() } label: {
                HStack(spacing: 6) {
                    Label("\(errors)", systemImage: "xmark.circle").foregroundStyle(errors > 0 ? Color.cinnabar : .secondary)
                    Label("\(warnings)", systemImage: "exclamationmark.triangle").foregroundStyle(warnings > 0 ? Color.amberInk : .secondary)
                }
            }
            .buttonStyle(.borderless).help(showProblems ? "Sorunları gizle" : "Sorunları göster")
            Text(controller.selectionLength > 0 ? "\(controller.selectionLength) seçili" : "Satır \(controller.line), Sütun \(controller.column)")
                .monospacedDigit().foregroundStyle(.secondary)
            Menu {
                Picker("Dil", selection: $language) {
                    ForEach(CodeLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text(language.title) }
            .menuStyle(.borderlessButton).fixedSize()
            Text(language.indentWidth == 0 ? "Tab" : "\(language.indentWidth) boşluk").foregroundStyle(.secondary)
            Text(text.contains("\r\n") ? "CRLF" : "LF").foregroundStyle(.secondary)
            Stepper(value: $size, in: 9...24) { Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary) }
                .controlSize(.mini)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Actions

    private func scheduleLint() {
        lintTask?.cancel()
        let snapshot = text, lang = language
        lintTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            var d = CodeLint.check(snapshot, language: lang)
            if lang == .shell { d += await CodeLint.shell(snapshot) }
            if !Task.isCancelled, snapshot == text { localDiagnostics = d }
        }
    }

    private func load() async {
        loading = true
        error = nil
        status = nil
        check = nil
        defer { loading = false }
        do {
            let f = try await model.openForEditing(server.id, path)
            language = CodeLanguage.detect(path: path, firstLine: String(f.text.prefix { $0 != "\n" }))
            controller.language = language
            text = f.text
            saved = f.text
            version = f.version
            readOnly = f.readOnlyReason
            previous = nil
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func save() async -> Bool {
        guard dirty, readOnly == nil, !saving else { return !dirty }
        saving = true
        error = nil
        status = nil
        defer { saving = false }
        let content = text
        let before = saved
        do {
            version = try await model.saveFile(server.id, path, text: content, version: version)
            previous = before
            saved = content
            status = "Kaydedildi · \(Date().formatted(date: .omitted, time: .shortened))"
            Haptics.success()
            await runCheck()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func runCheck() async {
        guard let c = configCheck else { check = nil; return }
        checking = true
        defer { checking = false }
        check = try? await model.runConfigCheck(server.id, c, path: path)
    }

    private func revert() async {
        guard let previous else { return }
        text = previous
        if await save() {
            self.previous = nil
            status = "Önceki hâline geri alındı"
        }
    }

    private func reloadService(_ c: ConfigCheck) async {
        error = nil
        do {
            _ = try await model.reloadService(server.id, c)
            status = c == .nginx ? "nginx yeniden yüklendi" : "Caddy yeniden yüklendi"
            check = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// Asks before closing a window with unsaved changes (close button and ⌘W).
private struct WindowCloseGuard: NSViewRepresentable {
    let isDirty: () -> Bool
    let save: () async -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.save = save
        DispatchQueue.main.async {
            context.coordinator.attach(to: v.window)
            v.window?.isDocumentEdited = isDirty()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var isDirty: () -> Bool = { false }
        var save: () async -> Bool = { true }
        private weak var window: NSWindow?
        private var monitor: Any?

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            if let close = window.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeClicked)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let w = self.window, event.window === w,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "w" else { return event }
                self.closeClicked()
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        @objc func closeClicked() {
            guard let window else { return }
            guard isDirty() else { window.close(); return }
            let alert = NSAlert()
            alert.messageText = "Değişiklikler kaydedilsin mi?"
            alert.informativeText = "Kaydetmezsen yaptığın değişiklikler kaybolur."
            alert.addButton(withTitle: "Kaydet")
            alert.addButton(withTitle: "Vazgeç")
            alert.addButton(withTitle: "Kaydetmeden kapat").hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    Task { @MainActor in if await self.save() { self.window?.close() } }
                case .alertThirdButtonReturn:
                    window.close()
                default: break
                }
            }
        }
    }
}
