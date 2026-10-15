import Foundation

public struct DockerContainer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    /// running, exited, paused, restarting, created, dead
    public let state: String
    public let status: String
    public let ports: String
    /// docker compose project, if any.
    public let project: String?
    public var cpu: String?
    public var memory: String?
    public var isRunning: Bool { state == "running" }
}

/// Docker on the server, through the shared connection. Falls back to password-less sudo when the login user is not
/// in the docker group.
enum DockerScript {
    static let prefix = #"D=docker; docker info >/dev/null 2>&1 || { sudo -n docker info >/dev/null 2>&1 && D="sudo -n docker"; } || { command -v docker >/dev/null 2>&1 && exit 3 || exit 4; }"#

    static let list = prefix + #"; $D ps -a --no-trunc --format "{{json .}}"; echo "--stats--"; $D stats --no-stream --format "{{json .}}" 2>/dev/null"#

    /// `name` is validated (letters, digits, _ . -) before it is placed in the script.
    static func action(_ verb: String, _ name: String) -> String { prefix + "; $D \(verb) \(name)" }
    static func logs(_ name: String) -> String { prefix + "; $D logs --tail 300 --timestamps \(name) 2>&1" }

    static func parse(_ text: String) -> [DockerContainer] {
        let parts = text.components(separatedBy: "--stats--")
        var stats: [String: (String, String)] = [:]
        if parts.count > 1 {
            for line in parts[1].split(whereSeparator: \.isNewline) {
                guard let o = json(line), let name = o["Name"] as? String else { continue }
                stats[name] = (o["CPUPerc"] as? String ?? "", o["MemUsage"] as? String ?? "")
            }
        }
        return parts[0].split(whereSeparator: \.isNewline).compactMap { line in
            guard let o = json(line), let id = o["ID"] as? String, let name = o["Names"] as? String else { return nil }
            let labels = (o["Labels"] as? String ?? "").split(separator: ",")
            let project = labels.first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
            return DockerContainer(id: String(id.prefix(12)), name: name, image: o["Image"] as? String ?? "",
                                   state: (o["State"] as? String ?? "").lowercased(), status: o["Status"] as? String ?? "",
                                   ports: o["Ports"] as? String ?? "", project: project,
                                   cpu: stats[name]?.0, memory: stats[name]?.1)
        }
        .sorted { ($0.project ?? "~", $0.name) < ($1.project ?? "~", $1.name) }
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func checkName(_ s: String) throws -> String {
        guard Validation.matches(s, #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#) else { throw DeckError.invalid("Geçersiz container adı.") }
        return s
    }
}

extension DeckModel {
    public func dockerContainers(_ id: UUID) async throws -> [DockerContainer] {
        let r = try await runShared(id, "sh -s", stdin: DockerScript.list, timeout: 60)
        try Self.dockerFailure(r)
        return DockerScript.parse(r.stdout)
    }

    /// start, stop, restart or rm (rm only for stopped containers; Docker refuses a running one).
    public func dockerAction(_ id: UUID, _ verb: String, container: String) async throws {
        guard ["start", "stop", "restart", "rm"].contains(verb) else { throw DeckError.invalid("Bilinmeyen işlem.") }
        let r = try await runShared(id, "sh -s", stdin: DockerScript.action(verb, try DockerScript.checkName(container)), timeout: 120)
        try Self.dockerFailure(r)
        log(id, verb == "rm" ? .warning : .info, "Docker: \(container) → \(verb)")
    }

    public func dockerLogs(_ id: UUID, container: String) async throws -> String {
        let r = try await runShared(id, "sh -s", stdin: DockerScript.logs(try DockerScript.checkName(container)), timeout: 60)
        try Self.dockerFailure(r)
        return r.stdout
    }

    static func dockerFailure(_ r: ShellResult) throws {
        switch r.exitCode {
        case 0: return
        case 3: throw DeckError.invalid("Docker kurulu ama bu kullanıcı kullanamıyor (docker grubunda değil ve şifresiz sudo yok).")
        case 4: throw DeckError.invalid("Bu sunucuda Docker yok.")
        default: throw DeckError.ssh(r.stderr.trimmed.isEmpty ? "Docker komutu başarısız oldu." : r.stderr.trimmed)
        }
    }
}
