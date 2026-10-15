import AppKit

/// "Is Sigil installed?" — answered by the app itself: when launched from anywhere other than an Applications folder
/// (typically straight from the DMG), it offers to move itself there, relaunches from the new place and ejects the DMG.
@MainActor
enum Installer {
    static let justInstalledKey = "justInstalled"
    private static let ejectArgument = "--sigil-eject"

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(user + "/")
    }

    /// Local builds (scripts/make-app.sh without VERSION) run from build/ and must not replace the installed release.
    static var isDevelopmentBuild: Bool {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.hasSuffix("-dev") == true
    }

    /// Call once at launch.
    static func run() {
        guard Platform.isBundled else { return }
        ejectIfAsked()
        guard !isInApplications, !isDevelopmentBuild else { return }

        let fromDMG = Bundle.main.bundleURL.path.hasPrefix("/Volumes/")
        let alert = NSAlert()
        alert.messageText = "Sigil’i Applications klasörüne taşıyalım mı?"
        alert.informativeText = fromDMG
            ? "Sigil şu an kurulum diskinden çalışıyor. Taşıyınca kalıcı olarak kurulur, disk çıkarılır ve Sigil yeni yerinden açılır."
            : "Applications klasöründe çalışmak, otomatik güncellemelerin ve “Mac açılınca başlat” seçeneğinin düzgün çalışmasını sağlar."
        alert.addButton(withTitle: "Taşı ve aç")
        alert.addButton(withTitle: "Şimdi değil")
        alert.icon = NSApp.applicationIconImage
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let destination = try install()
            UserDefaults.standard.set(true, forKey: justInstalledKey)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            if fromDMG { config.arguments = [ejectArgument, volumeRoot(of: Bundle.main.bundleURL).path] }
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let fail = NSAlert()
            fail.messageText = "Taşınamadı"
            fail.informativeText = "\(error.localizedDescription)\n\nSigil’i Finder’da Applications klasörüne sürükleyebilirsin."
            fail.runModal()
        }
    }

    /// Copies the bundle into /Applications (or ~/Applications without admin rights). An older copy goes to the Trash.
    private static func install() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var lastError: Error?
        for dir in candidates {
            let dest = dir.appendingPathComponent(source.lastPathComponent)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
                try fm.copyItem(at: source, to: dest)
                return dest
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private static func volumeRoot(of url: URL) -> URL {
        let parts = url.pathComponents   // ["/", "Volumes", "Sigil", "Sigil.app"]
        return parts.count >= 3 ? URL(fileURLWithPath: "/" + parts[1] + "/" + parts[2]) : url.deletingLastPathComponent()
    }

    private static func ejectIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: ejectArgument), i + 1 < args.count else { return }
        let volume = URL(fileURLWithPath: args[i + 1])
        guard volume.path.hasPrefix("/Volumes/") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        }
    }
}
