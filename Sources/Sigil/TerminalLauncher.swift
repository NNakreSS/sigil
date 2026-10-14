import AppKit
import Foundation

/// Where `ssh <alias>` runs.
enum TerminalApp: String, CaseIterable, Identifiable {
    case embedded, terminal, iterm2, ghostty, warp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded: return "Sigil (uygulama içi)"
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        }
    }

    var bundleID: String? {
        switch self {
        case .embedded: return nil
        case .terminal: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        }
    }

    var appURL: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }

    var isAvailable: Bool {
        self == .embedded ? TerminalSessions.isSupported : appURL != nil
    }

    static var available: [TerminalApp] { allCases.filter(\.isAvailable) }

    /// The user's choice, falling back to something that exists on this Mac.
    static var preferred: TerminalApp {
        let stored = UserDefaults.standard.string(forKey: "terminalApp").flatMap(TerminalApp.init(rawValue:))
        if let stored, stored.isAvailable { return stored }
        return TerminalSessions.isSupported ? .embedded : .terminal
    }
}

/// Opens an external terminal already running `ssh <alias>`.
enum TerminalLauncher {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sigil-terminal", isDirectory: true)
    }

    static func open(alias: String, in app: TerminalApp = .terminal, configFile: String? = nil) throws {
        // Aliases are validated when a server is added; check again because this ends up in a script.
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var sshArgs = [alias]
        if let configFile { sshArgs = ["-F", configFile, alias] }

        switch app {
        case .ghostty:
            // Ghostty runs a command given with -e.
            guard let url = app.appURL else { throw CocoaError(.fileNoSuchFile) }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.arguments = ["-e", "/usr/bin/ssh"] + sshArgs
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        case .terminal, .iterm2, .warp, .embedded:
            // A throw-away .command script; Terminal runs it directly, iTerm2 and Warp open shell scripts too.
            let script = try writeScript(sshArgs: sshArgs, alias: alias)
            if app == .terminal || app == .embedded {
                NSWorkspace.shared.open(script)
            } else if let appURL = app.appURL {
                NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
    }

    private static func writeScript(sshArgs: [String], alias: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("ssh-\(alias)-\(UUID().uuidString.prefix(6)).command")
        let quoted = sshArgs.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        try "#!/bin/zsh\nclear\nexec /usr/bin/ssh \(quoted)\n".write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
