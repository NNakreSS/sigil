import Foundation

public struct OnePasswordStatus: Sendable, Equatable {
    public var appInstalled = false
    public var cliPath: String?
    public var cliVersion: String?
    /// `op` can reach the desktop app (Settings → Developer → Integrate with 1Password CLI). nil = not checked: checking
    /// makes 1Password ask the user to authorize `op`, so it only happens when the user asks for it.
    public var cliIntegrationWorks: Bool?
    /// The SSH agent socket exists (Settings → Developer → Use the SSH Agent).
    public var agentRunning = false

    public init() {}

    /// Everything that can be seen without asking 1Password is in place, and the integration is not known to be off.
    public var isReady: Bool { cliPath != nil && cliIntegrationWorks != false && agentRunning }
}

/// 1Password as a key store, through the `op` CLI and the 1Password SSH agent.
///
/// Private keys are generated inside 1Password and never leave it: `op item create` prints the private key in
/// its JSON output, so that output is discarded unread; the item is then located by a unique tag and only the
/// `public_key` / `fingerprint` fields are requested. ssh authenticates through the agent socket, pinned to the
/// server's key by its public key file, and every use is approved by the user in 1Password (Touch ID).
public struct OnePasswordService: Sendable {
    let paths: DeckPaths
    public let cliPath: String?
    public let socketPath: String
    /// Extra environment for `op` (tests point a fake `op` at a scratch agent with it).
    let environment: [String: String]

    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock").path
    }

    /// GUI apps do not inherit the shell PATH, so look in the places Homebrew and the 1Password installer use.
    public static func locateCLI() -> String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public init(
        paths: DeckPaths,
        cliPath: String? = OnePasswordService.locateCLI(),
        socketPath: String = OnePasswordService.defaultSocketPath,
        environment: [String: String] = [:]
    ) {
        self.paths = paths
        self.cliPath = cliPath
        self.socketPath = socketPath
        self.environment = environment
    }

    // MARK: Status

    /// Without `verifyIntegration` these are local checks only and 1Password shows nothing. With it, `op account list`
    /// runs, and 1Password asks the user to authorize the CLI (account-wide, as 1Password scopes it) — so that is only
    /// done when the user presses "check" in setup.
    public func status(verifyIntegration: Bool = false) async -> OnePasswordStatus {
        var s = OnePasswordStatus()
        s.appInstalled = FileManager.default.fileExists(atPath: "/Applications/1Password.app")
        s.agentRunning = FileManager.default.fileExists(atPath: socketPath)
        guard let cliPath else { return s }
        s.cliPath = cliPath
        if let v = try? await op(["--version"], timeout: 15), v.succeeded { s.cliVersion = v.stdout.trimmed }
        guard verifyIntegration else { return s }
        s.cliIntegrationWorks = false
        if let r = try? await op(["account", "list", "--format", "json"], timeout: 30), r.succeeded,
           let data = r.stdout.data(using: .utf8),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            s.cliIntegrationWorks = !accounts.isEmpty
        }
        return s
    }

    // MARK: Keys

    /// The vault the 1Password SSH agent serves by default (Private, Personal or Employee). Keys elsewhere are not
    /// offered by the agent without extra agent.toml configuration, so we always create keys there.
    func agentVault() async throws -> (id: String, name: String) {
        let r = try await op(["vault", "list", "--format", "json"])
        guard r.succeeded else { throw DeckError.onePassword(Self.friendly(r.stderr)) }
        struct Vault: Decodable { let id: String; let name: String }
        let vaults = (try? JSONDecoder().decode([Vault].self, from: Data(r.stdout.utf8))) ?? []
        for wanted in ["private", "personal", "employee"] {
            if let v = vaults.first(where: { $0.name.lowercased() == wanted }) { return (v.id, v.name) }
        }
        throw DeckError.onePassword("SSH agent’ın kullandığı kasa (Private / Personal / Employee) bulunamadı.")
    }

    public func generate(fileName: String, alias: String) async throws -> KeyMaterial {
        try paths.ensureDirectories()
        let pubURL = paths.keyURL(fileName).appendingPathExtension("pub")
        guard !FileManager.default.fileExists(atPath: pubURL.path) else { throw DeckError.keyGeneration("\(fileName) zaten var.") }

        let vault = try await agentVault()
        let tag = "sigil-\(UUID().uuidString.lowercased().prefix(12))"

        // stdout carries the private key: never read it.
        let create = try await op(
            ["item", "create", "--category", "ssh", "--title", "Sigil – \(alias)",
             "--vault", vault.id, "--tags", "sigil,\(tag)"],
            discardStdout: true
        )
        guard create.succeeded else { throw DeckError.onePassword(Self.friendly(create.stderr)) }

        let list = try await op(["item", "list", "--vault", vault.id, "--tags", tag, "--format", "json"])
        struct Item: Decodable { let id: String }
        guard list.succeeded,
              let items = try? JSONDecoder().decode([Item].self, from: Data(list.stdout.utf8)),
              items.count == 1, let itemID = items.first?.id
        else { throw DeckError.onePassword("Oluşturulan anahtar 1Password’de bulunamadı. \(Self.friendly(list.stderr))") }

        do {
            let (publicKey, opFingerprint) = try await publicFields(itemID: itemID, vaultID: vault.id)
            let parts = publicKey.split(separator: " ").map(String.init)
            guard parts.count >= 2, parts[0] == "ssh-ed25519" || parts[0] == "ssh-rsa" else {
                throw DeckError.onePassword("Beklenmeyen genel anahtar biçimi.")
            }
            let blob = try Validation.keyBlob(parts[1])
            let fingerprint = Fingerprint.sha256(ofBase64: blob) ?? opFingerprint
            if !opFingerprint.isEmpty, opFingerprint != fingerprint {
                throw DeckError.onePassword("1Password’ün bildirdiği parmak izi genel anahtarla uyuşmuyor.")
            }
            let line = "\(parts[0]) \(blob) sigil:\(alias)"
            try (line + "\n").write(to: pubURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pubURL.path)
            return KeyMaterial(
                fileName: fileName, privateKeyURL: pubURL, publicKeyLine: line, blob: blob, fingerprint: fingerprint,
                onePasswordItemID: itemID, onePasswordVaultID: vault.id
            )
        } catch {
            await archive(itemID: itemID, vaultID: vault.id)
            throw error
        }
    }

    func publicFields(itemID: String, vaultID: String) async throws -> (publicKey: String, fingerprint: String) {
        let r = try await op(["item", "get", itemID, "--vault", vaultID,
                              "--fields", "label=public_key,label=fingerprint", "--format", "json"])
        guard r.succeeded else { throw DeckError.onePassword(Self.friendly(r.stderr)) }
        struct Field: Decodable { let id: String?; let label: String?; let value: String? }
        let data = Data(r.stdout.utf8)
        let fields = (try? JSONDecoder().decode([Field].self, from: data))
            ?? (try? JSONDecoder().decode(Field.self, from: data)).map { [$0] } ?? []
        func value(_ name: String) -> String? {
            fields.first { $0.id == name || $0.label?.replacingOccurrences(of: " ", with: "_") == name }?.value
        }
        guard let pub = value("public_key"), !pub.isEmpty else { throw DeckError.onePassword("Genel anahtar okunamadı.") }
        return (pub.trimmed, value("fingerprint")?.trimmed ?? "")
    }

    /// Moves the item to 1Password's Archive (recoverable) and removes our public key file.
    public func archive(itemID: String, vaultID: String?) async {
        var args = ["item", "delete", itemID, "--archive"]
        if let vaultID { args += ["--vault", vaultID] }
        _ = try? await op(args)
    }

    public func deletePublicKey(fileName: String) {
        try? FileManager.default.removeItem(at: paths.keyURL(fileName).appendingPathExtension("pub"))
    }

    // MARK: Plumbing

    func op(_ args: [String], discardStdout: Bool = false, timeout: TimeInterval = 120) async throws -> ShellResult {
        guard let cliPath else { throw DeckError.onePassword("1Password CLI (op) bulunamadı.") }
        // Generous timeout: commands may wait for the user to approve with Touch ID.
        return try await Shell.run(cliPath, args, environment: environment, discardStdout: discardStdout, timeout: timeout)
    }

    static func friendly(_ stderr: String) -> String {
        let t = stderr.trimmed
        let lower = t.lowercased()
        if lower.contains("authorization prompt dismissed") || lower.contains("authorization denied") || lower.contains("cancel") {
            return "Onay verilmedi."
        }
        if lower.contains("connecting to desktop app") || lower.contains("app integration") {
            return "1Password uygulamasına bağlanılamadı. Settings → Developer → “Integrate with 1Password CLI” açık mı?"
        }
        return t.isEmpty ? "Bilinmeyen hata." : t
    }
}
