import Foundation

/// Owns ~/.ssh/sigil/config (fully generated) and the single `Include` line in ~/.ssh/config that
/// pulls it in. The user's own entries in ~/.ssh/config are never rewritten.
public struct ConfigManager: Sendable {
    let paths: DeckPaths

    public init(paths: DeckPaths) { self.paths = paths }

    static let header = "# Managed by Sigil. Manage servers in the app; manual edits to this file are overwritten.\n"

    public func render(_ servers: [Server], onePasswordSocket: String = OnePasswordService.defaultSocketPath) -> String {
        var out = Self.header
        for s in servers.sorted(by: { $0.alias.lowercased() < $1.alias.lowercased() }) {
            out += "\nHost \(s.alias)\n"
            out += "  HostName \(s.host)\n  User \(s.user)\n  Port \(s.port)\n"
            switch s.store {
            case .keychain:
                // Explicit agent so a later global `IdentityAgent` (e.g. 1Password's) does not change this host.
                out += "  IdentityFile \(paths.keyURL(s.keyFileName).path)\n"
                out += "  IdentitiesOnly yes\n  IdentityAgent SSH_AUTH_SOCK\n  AddKeysToAgent yes\n  UseKeychain yes\n"
            case .onePassword:
                // Public key pins the 1Password key for this host; the private key stays in 1Password.
                out += "  IdentityFile \(paths.keyURL(s.keyFileName).appendingPathExtension("pub").path)\n"
                out += "  IdentitiesOnly yes\n  IdentityAgent \"\(onePasswordSocket)\"\n"
            case .secureEnclave:
                // Key handle file (no secret); Apple's provider signs inside the Secure Enclave after Touch ID.
                out += "  IdentityFile \(paths.keyURL(s.keyFileName).path)\n"
                out += "  IdentitiesOnly yes\n  IdentityAgent none\n  SecurityKeyProvider \(SecureEnclaveService.provider)\n"
            }
            if let j = s.jumpServerID, let jump = servers.first(where: { $0.id == j }) {
                out += "  ProxyJump \(jump.alias)\n"
            }
            out += "  ServerAliveInterval 30\n"
        }
        return out
    }

    public func writeIncludeFile(_ servers: [Server], onePasswordSocket: String = OnePasswordService.defaultSocketPath) throws {
        try paths.ensureDirectories()
        try render(servers, onePasswordSocket: onePasswordSocket).write(to: paths.includeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.includeFile.path)
    }

    var includeLine: String { "Include \"\(paths.includeFile.path)\"" }

    /// Makes sure ~/.ssh/config starts with our Include line (it must come before any Host block to apply
    /// globally). A timestamped backup of the previous file is written first. Returns true if it changed.
    @discardableResult
    public func ensureInclude() throws -> Bool {
        let fm = FileManager.default
        try paths.ensureDirectories()
        let existing = (try? String(contentsOf: paths.mainConfig, encoding: .utf8)) ?? ""

        let alreadyIncluded = existing.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmed
            return t.lowercased().hasPrefix("include") && t.contains(paths.includeFile.path)
        }
        if alreadyIncluded {
            if !fm.fileExists(atPath: paths.includeFile.path) { try writeIncludeFile([]) }
            return false
        }

        if !existing.isEmpty {
            let stamp = Self.stamp()
            let backup = paths.sshDir.appendingPathComponent("config.sigil-backup-\(stamp)")
            try existing.write(to: backup, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }

        let updated = "# Added by Sigil\n\(includeLine)\n\n" + existing
        try updated.write(to: paths.mainConfig, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.mainConfig.path)
        if !fm.fileExists(atPath: paths.includeFile.path) { try writeIncludeFile([]) }
        return true
    }

    /// Host names/aliases already defined by the user in ~/.ssh/config (wildcards ignored).
    public func existingHostPatterns() -> Set<String> {
        guard let text = try? String(contentsOf: paths.mainConfig, encoding: .utf8) else { return [] }
        var patterns = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let first = tokens.first, first.lowercased() == "host" else { continue }
            for t in tokens.dropFirst() {
                let name = t.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.contains("*"), !name.contains("?"), !name.hasPrefix("!") { patterns.insert(name.lowercased()) }
            }
        }
        return patterns
    }

    public func ensureAliasAvailable(_ alias: String) throws {
        if existingHostPatterns().contains(alias.lowercased()) { throw DeckError.aliasTaken(alias) }
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
