import AppKit
import SigilCore
import SwiftUI

/// A file on a server, opened in the editor window.
struct RemoteFileRef: Codable, Hashable {
    let serverID: UUID
    let path: String
}

/// Edits a text file on the server: ⌘S saves it back (owner and mode kept), refusing when the file changed meanwhile.
struct FileEditorWindow: View {
    @Environment(DeckModel.self) private var model
    let server: Server
    let path: String

    @AppStorage("previewWrap") private var wrap = true
    @AppStorage("previewFontSize") private var size = 12.0
    @State private var text = ""
    @State private var saved = ""
    @State private var version = ""
    @State private var readOnly: String?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var status: String?
    @State private var confirmReload = false

    private var dirty: Bool { text != saved }
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let readOnly {
                Label(readOnly, systemImage: "lock.fill").font(.caption).foregroundStyle(Color.amberInk)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.amberInk.opacity(0.08))
            }
            ZStack {
                CodeTextView(text: $text, editable: readOnly == nil && !loading, wrap: wrap, fontSize: size)
                if loading { ProgressView() }
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(WindowBackdrop())
        .navigationTitle("\(server.alias) · \(name)")
        .background(DocumentEditedMarker(edited: dirty))
        .task { await load() }
        .onAppear { model.holdSession(server.id) }
        .onDisappear { model.releaseSession(server.id) }
        .alert("Kaydedilmemiş değişiklikler atılsın mı?", isPresented: $confirmReload) {
            Button("Yeniden yükle", role: .destructive) { Task { await load() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Dosya sunucudan yeniden okunur; buradaki değişikliklerin kaybolur.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(Color.accentInk)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.semibold))
                    if dirty { Circle().fill(Color.amberInk).frame(width: 7, height: 7).help("Kaydedilmemiş değişiklik var") }
                }
                Text("\(server.alias):\(path)").font(.terminalSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if server.isProduction { Chip(text: "Production", systemImage: "flame.fill", tint: .cinnabar) }
            Spacer()
            Toggle("Satırları kaydır", isOn: $wrap).toggleStyle(.checkbox)
            Stepper(value: $size, in: 9...22) { Text("\(Int(size)) pt").monospacedDigit() }
            Button { if dirty { confirmReload = true } else { Task { await load() } } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Sunucudan yeniden yükle")
            Button { Task { await save() } } label: {
                if saving { ProgressView().controlSize(.small) } else { Label("Kaydet", systemImage: "square.and.arrow.down") }
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!dirty || saving || readOnly != nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cinnabar).lineLimit(2)
            } else if let status {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(Color.verdigris)
            } else {
                Text(dirty ? "Değiştirildi · ⌘S ile kaydet" : "Sunucudaki dosyayla aynı").foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(text.split(separator: "\n", omittingEmptySubsequences: false).count) satır · \(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))")
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func load() async {
        loading = true
        error = nil
        status = nil
        defer { loading = false }
        do {
            let f = try await model.openForEditing(server.id, path)
            text = f.text
            saved = f.text
            version = f.version
            readOnly = f.readOnlyReason
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard dirty, readOnly == nil else { return }
        saving = true
        error = nil
        defer { saving = false }
        let content = text
        do {
            version = try await model.saveFile(server.id, path, text: content, version: version)
            saved = content
            status = "Kaydedildi · \(Date().formatted(date: .omitted, time: .shortened))"
            Haptics.success()
        } catch { self.error = error.localizedDescription }
    }
}

/// Plain-text NSTextView: monospaced, undo, find bar, and none of macOS's "smart" substitutions, which would quietly
/// turn quotes and dashes in config files into different characters.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var wrap: Bool
    var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(Color.vellum)
        tv.textColor = .textColor
        tv.insertionPointColor = NSColor(Color.accentInk)
        scroll.drawsBackground = false
        apply(tv, scroll)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            tv.undoManager?.removeAllActions()
        }
        apply(tv, scroll)
    }

    private func apply(_ tv: NSTextView, _ scroll: NSScrollView) {
        tv.isEditable = editable
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        scroll.hasHorizontalScroller = !wrap
        tv.isHorizontallyResizable = !wrap
        tv.textContainer?.widthTracksTextView = wrap
        if wrap {
            tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            tv.frame.size.width = scroll.contentSize.width
        } else {
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

/// Shows the unsaved-changes dot in the window's close button.
private struct DocumentEditedMarker: NSViewRepresentable {
    let edited: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.isDocumentEdited = edited }
    }
}
