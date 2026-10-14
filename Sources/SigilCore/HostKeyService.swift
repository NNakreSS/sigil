import Foundation

/// First-contact handling: fetch the server's host keys so the user can compare the fingerprint with
/// what their provider shows, and only then trust them. The password is never sent to an unverified host.
public struct HostKeyService: Sendable {
    let paths: DeckPaths

    public init(paths: DeckPaths) { self.paths = paths }

    static func hostSpec(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    public func scan(host: String, port: Int) async throws -> [HostKey] {
        let result = try await Shell.run(
            "/usr/bin/ssh-keyscan",
            ["-T", "10", "-p", String(port), "-t", "ed25519,ecdsa,rsa", host],
            timeout: 30
        )
        let keys = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmed.isEmpty }
            .compactMap(Self.parse)
        guard !keys.isEmpty else {
            throw DeckError.ssh("Sunucudan parmak izi alınamadı. Adres ve port doğru mu, SSH çalışıyor mu?")
        }
        // ed25519 first: it is the one providers usually display.
        return keys.sorted { ($0.algorithm == "ssh-ed25519" ? 0 : 1) < ($1.algorithm == "ssh-ed25519" ? 0 : 1) }
    }

    static func parse(_ line: String) -> HostKey? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, let fp = Fingerprint.sha256(ofBase64: parts[2]) else { return nil }
        return HostKey(algorithm: parts[1], fingerprint: fp, knownHostsLine: parts[0...2].joined(separator: " "), blob: parts[2])
    }

    /// Adds the confirmed keys to known_hosts, matching OpenSSH's strict behaviour for hosts it already knows:
    /// - a known host must present at least one key that is already recorded, otherwise it is refused
    ///   (a man-in-the-middle can simply offer a key *type* that was never recorded);
    /// - a different key of an already-recorded type is refused;
    /// - for a known host nothing new is added, so an injected key of another type can never become trusted.
    /// Returns true only if this call created the host's entries (so removal may later forget them).
    @discardableResult
    public func trust(_ keys: [HostKey], host: String, port: Int) async throws -> Bool {
        let fm = FileManager.default
        try paths.ensureDirectories()
        let spec = Self.hostSpec(host: host, port: port)

        var known: [(algorithm: String, blob: String)] = []
        if fm.fileExists(atPath: paths.knownHosts.path) {
            let lookup = try await Shell.run("/usr/bin/ssh-keygen", ["-F", spec, "-f", paths.knownHosts.path], timeout: 15)
            if lookup.exitCode == 0 {
                for line in lookup.stdout.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                    let p = line.split(separator: " ").map(String.init)
                    if p.count >= 3 { known.append((p[1], p[2])) }
                }
            }
        }

        let changed = DeckError.hostKeyChanged(
            "Bu adres için kayıtlı parmak izi (known_hosts) sunucunun şimdiki parmak izinden farklı. Sunucu yeniden kurulmadıysa bağlanma; araya biri girmiş olabilir."
        )
        func isKnown(_ key: HostKey) -> Bool { known.contains { $0.algorithm == key.algorithm && $0.blob == key.blob } }

        if !known.isEmpty {
            if keys.contains(where: { key in known.contains { $0.algorithm == key.algorithm && $0.blob != key.blob } }) {
                throw changed
            }
            guard keys.contains(where: isKnown) else { throw changed }
            return false
        }

        guard !keys.isEmpty else { return false }
        var existing = (try? String(contentsOf: paths.knownHosts, encoding: .utf8)) ?? ""
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        existing += keys.map(\.knownHostsLine).joined(separator: "\n") + "\n"
        try existing.write(to: paths.knownHosts, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.knownHosts.path)
        return true
    }

    public enum KnownStatus: Sendable, Equatable {
        /// Never seen: the user must compare the fingerprint.
        case unknown
        /// known_hosts already vouches for at least one of these keys and none contradicts it.
        case matches
        /// known_hosts holds a different key for this host.
        case mismatch
    }

    /// Compares freshly scanned keys with known_hosts without changing anything.
    public func knownStatus(_ keys: [HostKey], host: String, port: Int) async -> KnownStatus {
        guard FileManager.default.fileExists(atPath: paths.knownHosts.path),
              let lookup = try? await Shell.run("/usr/bin/ssh-keygen", ["-F", Self.hostSpec(host: host, port: port), "-f", paths.knownHosts.path], timeout: 15),
              lookup.exitCode == 0
        else { return .unknown }
        let known = lookup.stdout.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: " ").map(String.init) }.filter { $0.count >= 3 }.map { ($0[1], $0[2]) }
        if known.isEmpty { return .unknown }
        if keys.contains(where: { k in known.contains { $0.0 == k.algorithm && $0.1 != k.blob } }) { return .mismatch }
        return keys.contains(where: { k in known.contains { $0.0 == k.algorithm && $0.1 == k.blob } }) ? .matches : .mismatch
    }

    /// Drops the host from known_hosts (ssh-keygen keeps a known_hosts.old backup). Only call this for entries
    /// the app created itself (see `trust`'s return value); never for a host the user trusted on their own.
    public func forget(host: String, port: Int) async {
        guard FileManager.default.fileExists(atPath: paths.knownHosts.path) else { return }
        _ = try? await Shell.run(
            "/usr/bin/ssh-keygen",
            ["-R", Self.hostSpec(host: host, port: port), "-f", paths.knownHosts.path],
            timeout: 15
        )
    }
}
