import Foundation

public struct RemoteTarget: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let user: String
    /// Reach the host through a jump server (built by `RemoteService.proxyCommand`).
    public let proxyCommand: String?
    public init(host: String, port: Int, user: String, proxyCommand: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.proxyCommand = proxyCommand
    }
}

public enum RemoteAuth: Sendable {
    /// Only used once, to install the first key. Fed to ssh through askpass, never stored.
    case password(String)
    /// Key file in ~/.ssh/sigil/keys, passphrase from the macOS Keychain.
    case key(fileName: String)
    /// Key held by an SSH agent (1Password), pinned by its public key file so only that key is offered.
    case agent(publicKeyFile: String, socket: String)
    /// Secure Enclave key: the handle file in ~/.ssh/sigil/keys, signed by Apple's provider after Touch ID.
    case securityKey(fileName: String)
    /// The user's own existing setup (`ssh -F <their config> <alias>`), used once to migrate a server they already
    /// reach with their own key. Never prompts (BatchMode).
    case userConfig(alias: String, configFile: String)
}

/// Everything that talks to a server. Always the system `ssh`, always with an argv array, always with
/// StrictHostKeyChecking=yes against the known_hosts we manage, and `-F /dev/null` so the user's own
/// config cannot change behaviour underneath us.
public struct RemoteService: Sendable {
    let paths: DeckPaths
    let useKeychain: Bool

    public init(paths: DeckPaths, useKeychain: Bool = true, authorizedKeysPath: String = "~/.ssh/authorized_keys") {
        precondition(
            Validation.matches(authorizedKeysPath, #"^[A-Za-z0-9_./~-]+$"#),
            "authorizedKeysPath contains unsafe characters"
        )
        self.paths = paths
        self.useKeychain = useKeychain
        self.authorizedKeysPath = authorizedKeysPath
    }

    // MARK: Scripts (sent as `sh -c '…'`; they contain no single quotes)

    /// Where the server keeps authorized keys. Always `~/.ssh/authorized_keys` in the app; tests point it at a
    /// scratch file so the real one is never touched. Restricted to plain path characters because it is
    /// interpolated into a remote shell command.
    let authorizedKeysPath: String

    static func installScript(_ path: String) -> String {
        """
        f=\(path); d=$(dirname "$f"); umask 077; mkdir -p "$d"; touch "$f"; \
        if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi; \
        read -r K; grep -qxF -- "$K" "$f" || printf "%s\\n" "$K" >> "$f"
        """
    }

    /// Removes one key line. Unless `allowEmpty`, it aborts (exit 3) rather than leave authorized_keys empty,
    /// a safety net for rotation where the replacement key must always remain. grep exits 1 when nothing is left.
    static func removeScript(_ path: String, allowEmpty: Bool) -> String {
        let maxRC = allowEmpty ? 1 : 0
        return """
        f=\(path); [ -s "$f" ] || exit 0; read -r B; tmp=$(mktemp) || exit 1; \
        grep -vF -- "$B" "$f" > "$tmp"; rc=$?; \
        if [ "$rc" -le \(maxRC) ]; then cat "$tmp" > "$f"; rc=$?; else rc=3; fi; rm -f "$tmp"; exit $rc
        """
    }

    static let historyScript = "last -n 8 -w -F 2>/dev/null || last -n 8 -w 2>/dev/null || last -n 8 2>/dev/null"

    static func wrap(_ script: String) -> String {
        let oneLine = script.replacingOccurrences(of: "\\\n", with: "").replacingOccurrences(of: "\n", with: " ")
        return "sh -c '\(oneLine)'"
    }

    // MARK: Operations

    public func installKey(target: RemoteTarget, auth: RemoteAuth, publicKeyLine: String) async throws {
        let r = try await execute(target, auth, Self.wrap(Self.installScript(authorizedKeysPath)), stdin: publicKeyLine + "\n")
        guard r.succeeded else { throw failure(r, auth) }
    }

    /// - Parameter allowEmpty: permit removing the last key in the file (rolling back a failed add, deleting a server).
    public func removeKey(target: RemoteTarget, auth: RemoteAuth, blob: String, allowEmpty: Bool = false) async throws {
        _ = try Validation.keyBlob(blob)
        let r = try await execute(target, auth, Self.wrap(Self.removeScript(authorizedKeysPath, allowEmpty: allowEmpty)), stdin: blob + "\n")
        guard r.succeeded else {
            if r.exitCode == 3 { throw DeckError.ssh("Kaldırma durduruldu: bu işlem authorized_keys dosyasını boş bırakacaktı.") }
            throw failure(r, auth)
        }
    }

    /// Logs in with the key and runs a no-op. Returns the round-trip time.
    @discardableResult
    public func ping(target: RemoteTarget, auth: RemoteAuth) async throws -> TimeInterval {
        let start = Date()
        let r = try await execute(target, auth, "echo sigil-ok")
        guard r.succeeded, r.stdout.contains("sigil-ok") else { throw failure(r, auth) }
        return Date().timeIntervalSince(start)
    }

    /// Reachability without authenticating: is an SSH server answering on host:port? Used for background checks of
    /// 1Password-backed servers, where using the key would trigger an approval prompt every time.
    public func probe(target: RemoteTarget) async throws {
        let r = try await Shell.run(
            "/usr/bin/ssh-keyscan", ["-T", "10", "-p", String(target.port), "-t", "ed25519", target.host], timeout: 20
        )
        guard r.stdout.contains("ssh-") else {
            throw DeckError.ssh("SSH sunucusu yanıt vermedi (\(target.host):\(target.port)).")
        }
    }

    @discardableResult
    public func ping(target: RemoteTarget, keyFile: String) async throws -> TimeInterval {
        try await ping(target: target, auth: .key(fileName: keyFile))
    }

    /// The server's own record of recent logins (`last`), which includes logins made from other machines.
    public func loginHistory(target: RemoteTarget, auth: RemoteAuth) async throws -> [String] {
        let r = try await execute(target, auth, Self.wrap(Self.historyScript))
        // `last` exits non-zero on some systems even when it printed rows; only a connection failure is fatal.
        if r.exitCode == 255 || r.timedOut { throw failure(r, auth) }
        return r.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && !$0.hasPrefix("wtmp begins") && !$0.hasPrefix("btmp begins") }
    }

    /// Lines of authorized_keys, parsed. Options before the key type (`command="…" ssh-ed25519 …`) are tolerated.
    public func listAuthorizedKeys(target: RemoteTarget, auth: RemoteAuth) async throws -> [(type: String, blob: String, comment: String)] {
        let r = try await execute(target, auth, Self.wrap("f=\(authorizedKeysPath); [ -f \"$f\" ] && cat \"$f\" || true"))
        guard r.succeeded else { throw failure(r, auth) }
        return Self.parseAuthorizedKeys(r.stdout)
    }

    static func parseAuthorizedKeys(_ text: String) -> [(type: String, blob: String, comment: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let i = tokens.firstIndex(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") }),
                  i + 1 < tokens.count, (try? Validation.keyBlob(tokens[i + 1])) != nil
            else { return nil }
            return (tokens[i], tokens[i + 1], tokens.dropFirst(i + 2).joined(separator: " "))
        }
    }

    // MARK: Jump hosts

    /// `ProxyCommand` that opens a stdio channel through `jump` with the jump server's own Sigil key. Every argument
    /// is single-quoted for the shell ssh runs it through; ssh still expands %h/%p inside.
    public func proxyCommand(through jump: RemoteTarget, auth: RemoteAuth) -> String {
        var args = arguments(for: jump, auth: auth, command: "")
        args.removeLast()                    // command
        let destination = args.removeLast()
        let all = ["/usr/bin/ssh"] + args + ["-W", "%h:%p", destination]
        return all.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// Host keys of a machine only the jump server can see.
    public func keyscan(host: String, port: Int, via jump: RemoteTarget, auth: RemoteAuth) async throws -> [HostKey] {
        let h = try Validation.host(host)
        let r = try await execute(jump, auth, "ssh-keyscan -T 10 -p \(port) -t ed25519,ecdsa,rsa \(h) 2>/dev/null")
        if r.exitCode == 255 && r.stdout.isEmpty { throw failure(r, auth) }
        let keys = r.stdout.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmed.isEmpty }.compactMap(HostKeyService.parse)
        guard !keys.isEmpty else { throw DeckError.ssh("Atlama sunucusu \(h):\(port) adresine ulaşamadı.") }
        return keys.sorted { ($0.algorithm == "ssh-ed25519" ? 0 : 1) < ($1.algorithm == "ssh-ed25519" ? 0 : 1) }
    }

    // MARK: Plumbing

    func arguments(for target: RemoteTarget, auth: RemoteAuth, command: String) -> [String] {
        if case .userConfig(let alias, let configFile) = auth {
            return [
                "-F", configFile,
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(paths.knownHosts.path)",
                "-o", "ConnectTimeout=15",
                "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "LogLevel=ERROR",
                alias, command,
            ]
        }
        var a = [
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(paths.knownHosts.path)",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "LogLevel=ERROR",
            "-p", String(target.port),
        ]
        switch auth {
        case .key(let fileName):
            a += [
                "-i", paths.keyURL(fileName).path,
                "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            ]
            if useKeychain { a += ["-o", "UseKeychain=yes", "-o", "AddKeysToAgent=yes"] }
        case .agent(let publicKeyFile, let socket):
            a += [
                "-i", paths.keyURL(publicKeyFile).appendingPathExtension("pub").path,
                "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=\(socket)", "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            ]
        case .securityKey(let fileName):
            a += [
                "-i", paths.keyURL(fileName).path,
                "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "SecurityKeyProvider=\(SecureEnclaveService.provider)", "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            ]
        case .userConfig:
            break   // handled above
        case .password:
            a += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        }
        if let pc = target.proxyCommand { a += ["-o", "ProxyCommand=\(pc)"] }
        a += ["\(target.user)@\(target.host)", command]
        return a
    }

    func execute(_ target: RemoteTarget, _ auth: RemoteAuth, _ command: String, stdin: String? = nil) async throws -> ShellResult {
        let args = arguments(for: target, auth: auth, command: command)
        switch auth {
        case .key, .userConfig:
            return try await Shell.run("/usr/bin/ssh", args, stdin: stdin, timeout: 45)
        case .agent, .securityKey:
            // Longer: the user may be approving the key use (1Password, Touch ID).
            return try await Shell.run("/usr/bin/ssh", args, stdin: stdin, timeout: 120)
        case .password(let secret):
            return try await Askpass.withSecret(secret) { env in
                try await Shell.run("/usr/bin/ssh", args, environment: env, stdin: stdin, timeout: 45)
            }
        }
    }

    func failure(_ r: ShellResult, _ auth: RemoteAuth) -> DeckError {
        var usedPassword = false
        if case .password = auth { usedPassword = true }
        return DeckError.ssh(SSHErrorText.friendly(r.stderr, exitCode: r.exitCode, timedOut: r.timedOut, usedPassword: usedPassword))
    }
}
