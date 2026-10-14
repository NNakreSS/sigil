import Foundation

/// A saved command the user runs on one or more servers.
public struct QuickAction: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String

    public init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    public static let defaults: [QuickAction] = [
        QuickAction(name: "Disk durumu", command: "df -h /"),
        QuickAction(name: "Bellek", command: "free -h"),
        QuickAction(name: "Çalışan servisler", command: "systemctl list-units --type=service --state=running --no-pager --no-legend | head -n 40"),
        QuickAction(name: "Son sistem günlükleri", command: "journalctl -n 40 --no-pager 2>/dev/null || tail -n 40 /var/log/syslog"),
        QuickAction(name: "Bekleyen güncellemeler", command: "apt list --upgradable 2>/dev/null | tail -n +2"),
        QuickAction(name: "nginx yapılandırmasını test et", command: "sudo -n nginx -t"),
    ]

    public func validated() throws -> QuickAction {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 60 else { throw DeckError.invalid("Eyleme bir ad ver.") }
        guard !c.isEmpty, c.count <= 4000 else { throw DeckError.invalid("Komut boş olamaz.") }
        return QuickAction(id: id, name: n, command: c)
    }
}

public struct ActionResult: Hashable, Sendable {
    public let serverID: UUID
    public let exitCode: Int32
    public let output: String
    public let errorOutput: String
    public let duration: TimeInterval
    public var succeeded: Bool { exitCode == 0 }
}

struct QuickActionStore: Sendable {
    let paths: DeckPaths
    var file: URL { paths.supportDir.appendingPathComponent("actions.json") }

    func load() -> [QuickAction] {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([QuickAction].self, from: data) else {
            return QuickAction.defaults
        }
        return list
    }

    func save(_ list: [QuickAction]) throws {
        try paths.ensureDirectories()
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(list).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

extension RemoteService {
    /// Runs a user-defined command (interpreted by the server's shell, as the user intends).
    func run(command: String, target: RemoteTarget, auth: RemoteAuth, timeout: TimeInterval = 120) async throws -> ShellResult {
        let r = try await execute(target, auth, command)
        if r.exitCode == 255 && !r.stderr.isEmpty && r.stdout.isEmpty { throw failure(r, auth) }
        return r
    }
}
