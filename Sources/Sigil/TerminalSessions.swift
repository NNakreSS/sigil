import AppKit
import SigilCore
import SwiftUI

/// One open shell inside Sigil.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let serverID: UUID
    let alias: String
    let ordinal: Int
    var title: String
    var exited = false
    var exitCode: Int32?
    /// Bumped on reconnect so SwiftUI builds a fresh terminal view.
    var generation = 0
    /// Run this on the server instead of a login shell (`ssh -t <alias> <command>`), e.g. an update.
    let remoteCommand: String?
    /// The live terminal view; kept alive while switching tabs so the session keeps its scrollback.
    @ObservationIgnored var host: NSView?

    private let purpose: String?

    init(serverID: UUID, alias: String, ordinal: Int, remoteCommand: String? = nil, purpose: String? = nil) {
        self.serverID = serverID
        self.alias = alias
        self.ordinal = ordinal
        self.title = alias
        self.remoteCommand = remoteCommand
        self.purpose = purpose
    }

    var label: String {
        if let purpose { return "\(alias) · \(purpose)" }
        return ordinal > 1 ? "\(alias) · \(ordinal)" : alias
    }
}

/// All in-app terminal tabs.
@MainActor
@Observable
final class TerminalSessions {
    var sessions: [TerminalSession] = []
    var activeID: UUID?
    /// `-F <file>` for sandboxed runs, so in-app ssh uses the same config the app manages.
    var configFile: String?

    nonisolated static var isSupported: Bool {
        #if canImport(SwiftTerm)
        return true
        #else
        return false
        #endif
    }

    var active: TerminalSession? { sessions.first { $0.id == activeID } }

    @discardableResult
    func open(_ server: Server, command: String? = nil, title: String? = nil) -> TerminalSession {
        let n = sessions.filter { $0.serverID == server.id }.count + 1
        let s = TerminalSession(serverID: server.id, alias: server.alias, ordinal: n, remoteCommand: command, purpose: title)
        sessions.append(s)
        activeID = s.id
        return s
    }

    /// Focus an existing session for this server, or open one.
    func focusOrOpen(_ server: Server) {
        if let existing = sessions.last(where: { $0.serverID == server.id && !$0.exited }) {
            activeID = existing.id
        } else {
            open(server)
        }
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        TerminalHost.terminate(sessions[i])
        sessions.remove(at: i)
        if activeID == id { activeID = sessions.indices.contains(i) ? sessions[i].id : sessions.last?.id }
    }

    func restart(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        TerminalHost.terminate(s)
        s.host = nil
        s.exited = false
        s.exitCode = nil
        s.generation += 1
    }

    func select(index: Int) {
        if sessions.indices.contains(index) { activeID = sessions[index].id }
    }

    func next(_ delta: Int) {
        guard let current = sessions.firstIndex(where: { $0.id == activeID }), !sessions.isEmpty else { return }
        activeID = sessions[(current + delta + sessions.count) % sessions.count].id
    }
}

// MARK: - Views

/// Tab strip + the active terminal.
struct TerminalWorkspaceView: View {
    @Environment(TerminalSessions.self) private var terminals
    @Environment(DeckModel.self) private var model
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            ZStack {
                Color(nsColor: TerminalTheme.background).ignoresSafeArea()
                if let s = terminals.active {
                    TerminalHost(session: s, configFile: terminals.configFile)
                        .id("\(s.id.uuidString)-\(s.generation)")
                        // Breathing room from the sidebar and tab strip; the ZStack fills it with the terminal colour.
                        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 8)
                        .overlay {
                            if s.exited { exitedOverlay(s) }
                        }
                } else {
                    VStack(spacing: 12) {
                        SigilMark(geometry: .brand, size: 64)
                        Text("Açık terminal yok").font(.engraved(18)).foregroundStyle(Color(nsColor: TerminalTheme.foreground))
                        Text("Bir sunucu seçip ⌘T’ye bas ya da ⌘K ile hızlı bağlan.")
                            .font(.callout).foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.6))
                    }
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(terminals.sessions.enumerated()), id: \.element.id) { i, s in
                    TerminalTab(session: s, index: i, isActive: s.id == terminals.activeID,
                                server: model.server(s.serverID)) {
                        terminals.activeID = s.id
                        router.selection = s.serverID
                    } close: {
                        withAnimation(Motion.quick) { terminals.close(s.id) }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .animation(Motion.stamp, value: terminals.sessions.map(\.id))
        }
        .background(Color(nsColor: TerminalTheme.chrome))
    }

    private func exitedOverlay(_ s: TerminalSession) -> some View {
        VStack(spacing: 10) {
            Text(s.exitCode == 0 ? "Oturum kapandı" : "Bağlantı koptu").font(.engraved(16))
            HStack {
                Button("Yeniden bağlan") { terminals.restart(s.id) }.buttonStyle(InkButtonStyle())
                Button("Sekmeyi kapat") { terminals.close(s.id) }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let index: Int
    let isActive: Bool
    let server: Server?
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let server {
                SigilMark(geometry: server.sigil, size: 16, reachable: session.exited ? false : server.lastReachable)
            }
            Text(session.label).font(.system(size: 12, weight: isActive ? .semibold : .regular, design: .monospaced))
                .lineLimit(1)
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10, design: .monospaced)).opacity(hovering || isActive ? 0.5 : 0)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isActive ? 0.8 : 0)
            .help("Sekmeyi kapat")
        }
        .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(isActive ? 1 : 0.65))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color(nsColor: TerminalTheme.background) : (hovering ? Color.white.opacity(0.06) : .clear))
        )
        .overlay(alignment: .top) {
            if server?.isProduction == true {
                Capsule().fill(Color.cinnabar).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .animation(Motion.quick, value: isActive)
    }
}

/// Terminal colours: the ink/parchment language carried into the shell.
enum TerminalTheme {
    static let background = NSColor(srgbRed: 0x17 / 255, green: 0x15 / 255, blue: 0x2E / 255, alpha: 1)
    static let chrome = NSColor(srgbRed: 0x11 / 255, green: 0x10 / 255, blue: 0x24 / 255, alpha: 1)
    static let foreground = NSColor(srgbRed: 0xEE / 255, green: 0xEB / 255, blue: 0xE2 / 255, alpha: 1)
    static let caret = NSColor(srgbRed: 0x5D / 255, green: 0xCA / 255, blue: 0xA5 / 255, alpha: 1)
    static let selection = NSColor(srgbRed: 0x53 / 255, green: 0x4A / 255, blue: 0xB7 / 255, alpha: 0.55)
    /// ANSI 0–15.
    static let ansi: [(UInt16, UInt16, UInt16)] = [
        (0x1B, 0x19, 0x36), (0xE0, 0x6C, 0x4A), (0x5D, 0xCA, 0xA5), (0xEF, 0xB7, 0x5A),
        (0x85, 0x9E, 0xF0), (0xC3, 0x8B, 0xE8), (0x6F, 0xC8, 0xD8), (0xD8, 0xD4, 0xC8),
        (0x5A, 0x55, 0x80), (0xF0, 0x99, 0x7B), (0x9F, 0xE1, 0xCB), (0xFA, 0xC7, 0x75),
        (0xAF, 0xBE, 0xF6), (0xDA, 0xB4, 0xF2), (0x9C, 0xDF, 0xEA), (0xFF, 0xFD, 0xF8),
    ]
}

#if canImport(SwiftTerm)
import SwiftTerm

/// Hosts a SwiftTerm view running `ssh <alias>` in a pseudo-terminal.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let configFile: String?

    func makeNSView(context: Context) -> NSView {
        if let existing = session.host { return existing }
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = TerminalTheme.background
        view.nativeForegroundColor = TerminalTheme.foreground
        view.caretColor = TerminalTheme.caret
        view.selectedTextBackgroundColor = TerminalTheme.selection
        view.installColors(TerminalTheme.ansi.map { SwiftTerm.Color(red8: $0.0, green8: $0.1, blue8: $0.2) })
        view.optionAsMetaKey = false

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        var args = [session.alias]
        if let command = session.remoteCommand { args = ["-t", session.alias, command] }
        if let configFile { args = ["-F", configFile] + args }
        view.startProcess(executable: "/usr/bin/ssh", args: args, environment: env.map { "\($0.key)=\($0.value)" })
        session.host = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    static func terminate(_ session: TerminalSession) {
        (session.host as? LocalProcessTerminalView)?.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        init(session: TerminalSession) { self.session = session }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in if !title.isEmpty { self.session.title = title } }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in
                withAnimation(Motion.gentle) {
                    self.session.exited = true
                    self.session.exitCode = exitCode
                }
            }
        }
    }
}
#else
struct TerminalHost: View {
    let session: TerminalSession
    let configFile: String?
    var body: some View { Text("Gömülü terminal bu derlemede yok.").foregroundStyle(.secondary) }
    static func terminate(_ session: TerminalSession) {}
}
#endif
