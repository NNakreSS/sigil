import Foundation

/// Every location the app touches. Tests inject a temp directory so the real ~/.ssh is never modified.
public struct DeckPaths: Sendable {
    public let sshDir: URL
    public let supportDir: URL

    public init(sshDir: URL, supportDir: URL) {
        self.sshDir = sshDir
        self.supportDir = supportDir
    }

    /// The real ~/.ssh and Application Support. Set `SIGIL_SANDBOX=/some/dir` to run the app against a
    /// scratch directory instead, so it can be tried without touching your real SSH configuration.
    public static var live: DeckPaths {
        let fm = FileManager.default
        if let sandbox = ProcessInfo.processInfo.environment["SIGIL_SANDBOX"], !sandbox.isEmpty {
            let root = URL(fileURLWithPath: sandbox, isDirectory: true)
            return DeckPaths(
                sshDir: root.appendingPathComponent("ssh", isDirectory: true),
                supportDir: root.appendingPathComponent("support", isDirectory: true)
            )
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sigil", isDirectory: true)
        return DeckPaths(
            sshDir: fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true),
            supportDir: support
        )
    }

    public var deckDir: URL { sshDir.appendingPathComponent("sigil", isDirectory: true) }
    public var keysDir: URL { deckDir.appendingPathComponent("keys", isDirectory: true) }
    /// Generated file that ~/.ssh/config pulls in with an Include line.
    public var includeFile: URL { deckDir.appendingPathComponent("config") }
    public var mainConfig: URL { sshDir.appendingPathComponent("config") }
    public var knownHosts: URL { sshDir.appendingPathComponent("known_hosts") }
    public var storeFile: URL { supportDir.appendingPathComponent("servers.json") }

    public func keyURL(_ fileName: String) -> URL { keysDir.appendingPathComponent(fileName) }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [sshDir, deckDir, keysDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}
