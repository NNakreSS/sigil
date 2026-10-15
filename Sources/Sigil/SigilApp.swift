import AppKit
import SigilCore
import SwiftUI

/// Window state shared between the main window, the menu bar and keyboard commands.
@MainActor
@Observable
final class AppRouter {
    enum Mode: String { case overview, terminal }

    var selection: UUID?
    var mode: Mode = .overview
    var showingAdd = false
    var showingSetup = false
    var showingQuickConnect = false
    var showingImport = false
    var showingEmergency = false
    var showingActions = false
    /// Update / restart sheet for a server.
    var maintenance: MaintenanceRequest?
    /// Files or Docker panel for a server.
    var panel: PanelRequest?
    /// The tour, open at this page.
    var tourPage: Int?
    /// Waiting for "yes, connect to production".
    var pendingProductionConnect: Server?
    /// Production servers the user already confirmed in this app session.
    var productionApproved: Set<UUID> = []
    let terminals = TerminalSessions()

    /// The one place every "connect" button goes through.
    func connect(_ server: Server, confirmed: Bool = false) {
        if server.isProduction, !confirmed, !productionApproved.contains(server.id) {
            pendingProductionConnect = server
            return
        }
        if server.isProduction { productionApproved.insert(server.id) }
        var connected = UserDefaults.standard.stringArray(forKey: "connectedServers") ?? []
        if !connected.contains(server.id.uuidString) { connected.append(server.id.uuidString); UserDefaults.standard.set(connected, forKey: "connectedServers") }
        let app = TerminalApp.preferred
        if app == .embedded {
            terminals.open(server)
            selection = server.id
            mode = .terminal
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            try? TerminalLauncher.open(alias: server.alias, in: app, configFile: terminals.configFile)
        }
        Haptics.tap()
    }

    /// Runs a command on the server in an in-app terminal tab (ssh -t), so the user watches it and can answer prompts.
    func runInTerminal(_ server: Server, command: String, title: String) {
        terminals.open(server, command: command, title: title)
        selection = server.id
        mode = .terminal
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct MaintenanceRequest: Identifiable {
    enum Kind { case update, reboot }
    let serverID: UUID
    let kind: Kind
    var id: String { "\(serverID)-\(kind)" }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running in the menu bar after the window is closed so scheduled checks and rotations continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon brings the main window back after ⌘W, also when only a files or preview window is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let mainVisible = sender.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
            if !mainVisible { AppLaunch.openMain?() }
        }
        return true
    }
}

@main
struct SigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DeckModel()
    @State private var router = AppRouter()
    @StateObject private var updater = UpdaterModel()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("onboardingDone") private var onboardingDone = false

    init() {
        // Needed when launched outside a proper .app bundle (e.g. `swift run`).
        NSApplication.shared.setActivationPolicy(.regular)
        TerminalLauncher.cleanup()
    }

    var body: some Scene {
        Window("Sigil", id: "main") {
            ContentView()
                .environment(model)
                .environment(router)
                .environment(router.terminals)
                .environmentObject(updater)
                .environment(\.locale, trLocale)
                .frame(minWidth: 920, minHeight: 600)
                .tint(Color.accentInk)
                .task { await start() }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Sunucu Ekle…") { router.showingAdd = true }.keyboardShortcut("n")
                Button("Hızlı Bağlan…") { router.showingQuickConnect = true }.keyboardShortcut("k")
                Button("~/.ssh/config’ten İçe Aktar…") { router.showingImport = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Eylem Çalıştır…") { router.showingActions = true }.keyboardShortcut("e")
                Divider()
                Button("Tüm Anahtarları Şimdi Yenile…") { router.showingEmergency = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                    .disabled(model.servers.isEmpty)
            }
            CommandMenu("Terminal") {
                Button("Seçili Sunucuya Bağlan") {
                    if let id = router.selection, let s = model.server(id) { router.connect(s) }
                }
                .keyboardShortcut("t")
                .disabled(router.selection == nil)
                Divider()
                Button("Genel Bakış") { router.mode = .overview }.keyboardShortcut("0")
                Button("Terminaller") { router.mode = .terminal }.keyboardShortcut("j")
                Button("Sonraki Sekme") { router.terminals.next(1); router.mode = .terminal }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Önceki Sekme") { router.terminals.next(-1); router.mode = .terminal }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Sekmeyi Kapat") {
                    if let id = router.terminals.activeID { router.terminals.close(id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(router.terminals.activeID == nil)
                Divider()
                terminalTools
                Divider()
                ForEach(0..<9, id: \.self) { i in
                    Button("Sekme \(i + 1)") { router.terminals.select(index: i); router.mode = .terminal }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                        .disabled(i >= router.terminals.sessions.count)
                }
            }
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
            CommandGroup(replacing: .help) {
                Button("Sigil’i Tanı…") { router.tourPage = 0 }
                Button("Klavye Kısayolları") { router.tourPage = 2 }
                Button("Güvenlik nasıl çalışır?") { Links.openURL("https://github.com/NNakreSS/sigil#güvenlik-sade-bir-dille") }
            }
        }

        WindowGroup("Sunucu", id: "panel", for: PanelRequest.self) { $request in
            if let request, let server = model.server(request.serverID) {
                ServerPanelSheet(server: server, kind: request.kind)
                    .environment(model)
                    .environment(router)
                    .environment(router.terminals)
                    .environment(\.locale, trLocale)
                    .tint(Color.accentInk)
            }
        }
        .defaultSize(width: 980, height: 680)

        WindowGroup("Önizleme", id: "preview", for: TextPreview.self) { $preview in
            if let preview {
                PreviewWindow(preview: preview).tint(Color.accentInk)
            }
        }
        .defaultSize(width: 820, height: 600)

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environment(model)
                .environment(router)
                .environmentObject(updater)
                .environment(\.locale, trLocale)
        } label: {
            Image(nsImage: MenuBarIcon.image(attention: needsAttention))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(updater: updater)
                .environment(model)
                .environment(router)
                .environment(\.locale, trLocale)
                .tint(Color.accentInk)
        }
    }

    /// Palette, find, zoom, split and clear: they act on the active terminal tab.
    @ViewBuilder private var terminalTools: some View {
        let t = router.terminals
        let hasTerminal = router.mode == .terminal && t.active != nil
        Button("Komut Paleti…") { t.showingFind = false; t.showingPalette = true }
            .keyboardShortcut("p").disabled(!hasTerminal)
        Button("Bul…") { t.showingPalette = false; t.showingFind = true }
            .keyboardShortcut("f").disabled(!hasTerminal)
        Button("Sonrakini Bul") { t.find() }
            .keyboardShortcut("g").disabled(!hasTerminal || t.findTerm.isEmpty)
        Button("Öncekini Bul") { t.find(backwards: true) }
            .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!hasTerminal || t.findTerm.isEmpty)
        Button("Seçili Metni Açıkla") { t.showingPalette = false; t.explaining = t.selectedText() ?? "" }
            .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!hasTerminal)
        Button("Ekranı Temizle") { t.clearScreen() }
            .keyboardShortcut("k", modifiers: [.command, .option]).disabled(!hasTerminal)
        Divider()
        Button("Yazıyı Büyüt") { t.zoom(1) }.keyboardShortcut("+")
        Button("Yazıyı Küçült") { t.zoom(-1) }.keyboardShortcut("-")
        Button("Yazı Boyutunu Sıfırla") { t.resetZoom() }.keyboardShortcut("0", modifiers: [.command, .option])
        Divider()
        Button("Yan Yana Böl") {
            if let s = t.active, let server = model.server(s.serverID) { t.splitActive(with: server) }
        }
        .keyboardShortcut("d").disabled(!hasTerminal)
        Button("Bölmeyi Kapat") { t.unsplit() }
            .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(t.split == nil)
    }

    private var needsAttention: Bool {
        model.servers.contains { $0.lastReachable == false } || !model.awaitingManualRotation.isEmpty
    }

    /// The main window's `.task` runs again whenever the window is reopened; the app only starts once.
    @MainActor
    private func start() async {
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard !AppLaunch.started else { return }
        AppLaunch.started = true
        // Theme: follow macOS light/dark for "auto", force the theme's appearance otherwise.
        let theme = ThemeStore.shared
        theme.systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        AppLaunch.appearanceObservation = DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            MainActor.assumeIsolated { ThemeStore.shared.systemIsDark = dark }
        }
        theme.applyAppearance()
        Installer.run()
        model.notify = { title, body in Notifier.post(title, body) }
        // Tunnels are child ssh processes; never leave them running (and holding ports) after Sigil quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.stopAllTunnels(); model.lockApprovalsNow() }
        }
        // Like a password manager locking: an approval does not outlive the screen lock or sleep.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [model] _ in
                Task { @MainActor in await model.lockApprovals() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [model] _ in
            Task { @MainActor in await model.lockApprovals() }
        }
        // In sandbox runs, point in-app and external ssh at the sandboxed config.
        if ProcessInfo.processInfo.environment["SIGIL_SANDBOX"] != nil { router.terminals.configFile = model.paths.mainConfig.path }
        let window = UserDefaults.standard.object(forKey: "approvalWindowMinutes") as? Int ?? 15
        model.approvalWindowMinutes = window
        model.load()
        let defaultStore = KeyStoreKind(rawValue: UserDefaults.standard.string(forKey: "defaultKeyStore") ?? "")
        if model.usesOnePassword(defaultStore: defaultStore) { await model.refreshOnePasswordStatus() }
        if !onboardingDone || UserDefaults.standard.bool(forKey: Installer.justInstalledKey) { router.showingSetup = true }
        model.startScheduler()
    }
}

@MainActor
enum AppLaunch {
    static var started = false
    static var appearanceObservation: NSObjectProtocol?
    /// Opens (or brings forward) the main window; set by the main window itself, used by the Dock icon.
    static var openMain: (() -> Void)?
}

/// Menu bar icon drawn from the brand sigil (template image, so it follows the menu bar's colour). When something
/// needs attention a small solid dot is added.
@MainActor
enum MenuBarIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func image(attention: Bool) -> NSImage {
        if let cached = cache[attention] { return cached }
        let view = ZStack(alignment: .bottomTrailing) {
            SigilOutline(vector: SigilVector(.brand), inset: 1.2)
                .stroke(Color.black, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .frame(width: 18, height: 18)
            if attention {
                Circle().fill(Color.black).frame(width: 6, height: 6)
            }
        }
        .frame(width: 18, height: 18)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "seal", accessibilityDescription: nil)!
        image.isTemplate = true
        image.accessibilityDescription = "Sigil"
        cache[attention] = image
        return image
    }
}
