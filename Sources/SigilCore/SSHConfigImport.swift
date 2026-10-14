import Foundation

/// A `Host` block from the user's own ~/.ssh/config that Sigil can take over.
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public var id: String { alias }
    public let alias: String
    public let host: String
    public let user: String
    public let port: Int
    /// IdentityFile as written (may start with ~), if any.
    public let identityFile: String?
    /// The block's lines in the file (0-based, inclusive of the Host line).
    public let lineRange: ClosedRange<Int>
}

extension ConfigManager {
    /// Simple, single-name `Host` blocks in ~/.ssh/config. Wildcard and multi-pattern hosts, `Match` blocks and
    /// anything pulled in by `Include` are left alone. Values are validated like the add form.
    public func importCandidates(excluding managed: Set<String> = []) -> [ImportCandidate] {
        guard let text = try? String(contentsOf: paths.mainConfig, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        var result: [ImportCandidate] = []

        var current: (alias: String?, start: Int, opts: [String: String])?
        func flush(endingBefore end: Int) {
            guard let c = current, let alias = c.alias else { return }
            let host = c.opts["hostname"] ?? alias
            let user = c.opts["user"] ?? NSUserName()
            let port = Int(c.opts["port"] ?? "22") ?? 22
            guard (try? Validation.alias(alias)) != nil, (try? Validation.host(host)) != nil,
                  (try? Validation.user(user)) != nil, (1...65535).contains(port),
                  !managed.contains(alias.lowercased()), c.opts["proxycommand"] == nil
            else { return }
            var last = end - 1
            while last > c.start && lines[last].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
            result.append(ImportCandidate(alias: alias, host: host, user: user, port: port,
                                          identityFile: c.opts["identityfile"], lineRange: c.start...last))
        }

        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (key, value) = Self.split(line)
            switch key {
            case "host":
                flush(endingBefore: i)
                let names = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                let single = names.count == 1 && !names[0].contains("*") && !names[0].contains("?") && !names[0].hasPrefix("!")
                current = (single ? names[0] : nil, i, [:])
            case "match":
                flush(endingBefore: i)
                current = nil
            default:
                // First value wins in ssh_config; keep that behaviour.
                if current != nil, current!.opts[key] == nil { current!.opts[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
        }
        flush(endingBefore: lines.count)
        return result
    }

    /// Comments out the block (after a timestamped backup) so the alias can be served by Sigil's entry instead.
    public func retire(_ candidate: ImportCandidate) throws {
        let text = try String(contentsOf: paths.mainConfig, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(candidate.lineRange.upperBound),
              Self.split(lines[candidate.lineRange.lowerBound].trimmingCharacters(in: .whitespaces)).key == "host"
        else { throw DeckError.invalid("~/.ssh/config değişmiş; içe aktarmayı yeniden başlat.") }

        let backup = paths.sshDir.appendingPathComponent("config.sigil-backup-\(Self.stamp())")
        try text.write(to: backup, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)

        lines.insert("# Sigil’e taşındı (\(Self.stamp())). Geri almak için bu satırların başındaki “# ” işaretini kaldır.",
                     at: candidate.lineRange.lowerBound)
        for i in (candidate.lineRange.lowerBound + 1)...(candidate.lineRange.upperBound + 1) where !lines[i].isEmpty {
            lines[i] = "# " + lines[i]
        }
        try lines.joined(separator: "\n").write(to: paths.mainConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.mainConfig.path)
    }

    static func split(_ line: String) -> (key: String, value: String) {
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return (line.lowercased(), "") }
        let key = line[..<sep].lowercased()
        let value = line[sep...].drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
        return (key, String(value).trimmingCharacters(in: .whitespaces))
    }
}
