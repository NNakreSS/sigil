import Foundation
import Observation

/// App state plus the workflows: add a server, rotate its key, check it, remove it.
/// The UI only talks to this class.
@MainActor
@Observable
public final class DeckModel {
    public private(set) var servers: [Server] = []
    /// Servers with an operation in flight, mapped to a short description for the UI.
    public private(set) var busy: [UUID: String] = [:]
    /// Last problem worth showing outside a specific form (e.g. a failed save).
    public var banner: String?
    public private(set) var onePasswordStatus = OnePasswordStatus()
    /// Called for things the user should hear about while the window is closed (title, body).
    public var notify: ((String, String) -> Void)?

    public let paths: DeckPaths
    private let store: ServerStore
    private let config: ConfigManager
    private let keys: KeyService
    private let hostKeys: HostKeyService
    let remote: RemoteService
    public let onePassword: OnePasswordService
    private let secureEnclave: SecureEnclaveService
    private var scheduler: Task<Void, Never>?
    private var tunnelProcesses: [UUID: TunnelProcess] = [:]
    /// Tunnel id → server id, for every tunnel currently up.
    public private(set) var activeTunnels: [UUID: UUID] = [:]
    public private(set) var actions: [QuickAction] = []
    private var actionStore: QuickActionStore { QuickActionStore(paths: paths) }
    /// Tests only: use this instead of the password for the first key installation (a non-root test sshd
    /// cannot verify passwords).
    var initialAuthOverride: RemoteAuth?

    /// - Parameter hardened: `true` in the app (random key passphrases in the Keychain). Tests pass `false`.
    public init(
        paths: DeckPaths = .live,
        hardened: Bool = true,
        authorizedKeysPath: String = "~/.ssh/authorized_keys",
        onePassword: OnePasswordService? = nil
    ) {
        self.onePassword = onePassword ?? OnePasswordService(paths: paths)
        self.secureEnclave = SecureEnclaveService(paths: paths)
        self.paths = paths
        self.store = ServerStore(paths: paths)
        self.config = ConfigManager(paths: paths)
        self.keys = KeyService(paths: paths, protectWithKeychain: hardened)
        self.hostKeys = HostKeyService(paths: paths)
        self.remote = RemoteService(paths: paths, useKeychain: hardened, authorizedKeysPath: authorizedKeysPath)
    }

    // MARK: Loading & scheduling

    public func load() {
        let result = store.load()
        servers = result.servers
        actions = actionStore.load()
        if let warning = result.warning { banner = warning }
        // Keep the generated ssh config in sync with the list (e.g. after a manual edit or restore).
        if !servers.isEmpty {
            _ = try? config.ensureInclude()
            writeConfig()
            let keychainKeys = servers.filter { $0.store == .keychain }.map(\.keyFileName)
            if !keychainKeys.isEmpty { Task { await keys.unloadFromAgent(fileNames: keychainKeys) } }
        }
    }

    /// - Parameter verifyIntegration: also run `op`, which makes 1Password ask for authorization. Only on user request.
    public func refreshOnePasswordStatus(verifyIntegration: Bool = false) async {
        var s = await onePassword.status(verifyIntegration: verifyIntegration)
        if !verifyIntegration { s.cliIntegrationWorks = onePasswordStatus.cliIntegrationWorks }   // keep what we learned
        onePasswordStatus = s
    }

    /// Looking at 1Password's agent socket reaches into another app's container, which macOS guards with an "access
    /// data from other apps" prompt; only do it for people who use 1Password.
    public func usesOnePassword(defaultStore: KeyStoreKind?) -> Bool {
        defaultStore == .onePassword || servers.contains { $0.store == .onePassword }
    }

    /// Secure Enclave where supported, else 1Password when it is fully set up, otherwise the Keychain.
    public var recommendedKeyStore: KeyStoreKind {
        KeyStoreKind.usable(.preferredDefault, onePasswordReady: onePasswordStatus.isReady)
    }

    /// Checks reachability and rotates overdue keys now, then every 15 minutes while the app runs.
    public func startScheduler() {
        guard scheduler == nil else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.rotateDueServers()
                await self.checkAll()
                await self.auditDueServers()
                await self.collectDueHealth()
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            }
        }
    }

    public func stopScheduler() {
        scheduler?.cancel()
        scheduler = nil
    }

    public func server(_ id: UUID) -> Server? { servers.first { $0.id == id } }

    // MARK: Adding

    /// Step 1 of adding: validate the form and fetch the server's host keys for the user to confirm.
    public func scanHostKeys(for draft: ServerDraft) async throws -> (draft: ServerDraft, keys: [HostKey]) {
        let valid = try draft.validated()
        try ensureAliasFree(valid.alias)
        let found = try await scanKeys(host: valid.host, port: valid.port, jumpID: valid.jumpServerID)
        return (valid, found)
    }

    /// Step 2: trust the confirmed host key, create a dedicated key, install it using the password (once),
    /// prove that key login works, then write the ssh config entry. Anything that fails is rolled back.
    public func addServer(
        draft: ServerDraft,
        password: String,
        hostKeys confirmed: [HostKey],
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws -> Server {
        let d = try draft.validated()
        try ensureAliasFree(d.alias)
        let id = UUID()
        let target = try draftTarget(d)
        let keyFile = Self.keyFileName(for: id)
        let passwordAuth = initialAuthOverride ?? RemoteAuth.password(password)
        if d.keyStore == .onePassword, !onePasswordStatus.isReady { await refreshOnePasswordStatus() }
        if d.keyStore == .onePassword, !onePasswordStatus.isReady {
            throw DeckError.onePassword("Kurulum tamamlanmamış (CLI entegrasyonu ve SSH Agent açık olmalı).")
        }

        progress("Sunucu parmak izi kaydediliyor")
        let createdKnownHosts = try await hostKeys.trust(confirmed, host: d.host, port: d.port)

        progress("SSH yapılandırması hazırlanıyor")
        try config.ensureInclude()

        progress(Self.creatingMessage(d.keyStore))
        let material = try await generateKey(d.keyStore, fileName: keyFile, alias: d.alias)

        var installed = false
        do {
            progress("Genel anahtar sunucuya kuruluyor")
            try await remote.installKey(target: target, auth: passwordAuth, publicKeyLine: material.publicKeyLine)
            installed = true

            progress("Anahtarla giriş doğrulanıyor")
            do {
                try await remote.ping(target: target, auth: auth(d.keyStore, keyFile))
            } catch {
                throw DeckError.ssh("Anahtar sunucuya kuruldu ama anahtarla giriş doğrulanamadı: \(error.localizedDescription)")
            }

            progress("Kayıt tamamlanıyor")
            let now = Date()
            var server = Server(
                id: id, alias: d.alias, host: d.host, port: d.port, user: d.user,
                keyFileName: keyFile, publicKeyBlob: material.blob, keyFingerprint: material.fingerprint,
                createdAt: now, lastRotatedAt: now, rotationIntervalDays: d.rotationIntervalDays,
                lastCheckedAt: now, lastReachable: true
            )
            server.createdKnownHostsEntry = createdKnownHosts
            server.keyStore = d.keyStore
            server.jumpServerID = d.jumpServerID
            server.onePasswordItemID = material.onePasswordItemID
            server.onePasswordVaultID = material.onePasswordVaultID
            server.secureEnclaveKeyHash = material.secureEnclaveKeyHash
            server.events.append(ServerEvent(level: .info, message: "Sunucu eklendi; ilk anahtar kuruldu."))
            let updated = servers + [server]
            try config.writeIncludeFile(updated, onePasswordSocket: onePassword.socketPath)
            servers = updated
            persist()
            return server
        } catch {
            // Leave nothing half-installed: take the key back off the server (using the password we still hold)
            // and delete it locally.
            if installed {
                try? await remote.removeKey(target: target, auth: passwordAuth, blob: material.blob, allowEmpty: true)
            }
            await deleteKey(d.keyStore, fileName: keyFile, material: material)
            if createdKnownHosts, !servers.contains(where: { $0.host == d.host && $0.port == d.port }) {
                await hostKeys.forget(host: d.host, port: d.port)
            }
            throw error
        }
    }

    // MARK: Importing

    /// Scans a host and says whether known_hosts already vouches for it.
    public func scanForImport(_ c: ImportCandidate) async throws -> (keys: [HostKey], status: HostKeyService.KnownStatus) {
        let keys = try await hostKeys.scan(host: c.host, port: c.port)
        return (keys, await hostKeys.knownStatus(keys, host: c.host, port: c.port))
    }

    /// Servers in the user's ~/.ssh/config that Sigil could take over.
    public func importCandidates() -> [ImportCandidate] {
        config.importCandidates(excluding: Set(servers.map { $0.alias.lowercased() }))
    }

    /// Takes over a host from ~/.ssh/config: same alias, but a fresh dedicated key from the chosen store.
    /// Logs in with the user's existing setup (or the password, if given) to install the new key, proves the new key
    /// works, then comments out the old block (backup first) and serves the alias from Sigil's config.
    /// - Parameter removeOldKey: also remove the key the old block used from the server's authorized_keys.
    public func importServer(
        _ candidate: ImportCandidate,
        keyStore: KeyStoreKind,
        rotationIntervalDays: Int,
        hostKeys confirmed: [HostKey],
        password: String?,
        removeOldKey: Bool,
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws -> Server {
        guard !servers.contains(where: { $0.alias.lowercased() == candidate.alias.lowercased() }) else {
            throw DeckError.aliasTaken(candidate.alias)
        }
        if keyStore == .onePassword, !onePasswordStatus.isReady { await refreshOnePasswordStatus() }
        if keyStore == .onePassword, !onePasswordStatus.isReady {
            throw DeckError.onePassword("Kurulum tamamlanmamış (CLI entegrasyonu ve SSH Agent açık olmalı).")
        }
        let id = UUID()
        let target = RemoteTarget(host: candidate.host, port: candidate.port, user: candidate.user)
        let keyFile = Self.keyFileName(for: id)
        let oldAuth: RemoteAuth = initialAuthOverride
            ?? password.map(RemoteAuth.password)
            ?? .userConfig(alias: candidate.alias, configFile: paths.mainConfig.path)

        progress("Sunucu parmak izi doğrulanıyor")
        let createdKnownHosts = try await hostKeys.trust(confirmed, host: candidate.host, port: candidate.port)
        try config.ensureInclude()

        progress(Self.creatingMessage(keyStore))
        let material = try await generateKey(keyStore, fileName: keyFile, alias: candidate.alias)

        var installed = false
        do {
            progress("Mevcut bağlantınla yeni anahtar kuruluyor")
            try await remote.installKey(target: target, auth: oldAuth, publicKeyLine: material.publicKeyLine)
            installed = true

            progress("Yeni anahtarla giriş doğrulanıyor")
            do {
                try await remote.ping(target: target, auth: auth(keyStore, keyFile))
            } catch {
                throw DeckError.ssh("Yeni anahtar kuruldu ama onunla giriş doğrulanamadı: \(error.localizedDescription)")
            }

            let now = Date()
            var server = Server(
                id: id, alias: candidate.alias, host: candidate.host, port: candidate.port, user: candidate.user,
                keyFileName: keyFile, publicKeyBlob: material.blob, keyFingerprint: material.fingerprint,
                createdAt: now, lastRotatedAt: now, rotationIntervalDays: rotationIntervalDays,
                lastCheckedAt: now, lastReachable: true
            )
            server.createdKnownHostsEntry = createdKnownHosts
            server.keyStore = keyStore
            server.onePasswordItemID = material.onePasswordItemID
            server.onePasswordVaultID = material.onePasswordVaultID
            server.secureEnclaveKeyHash = material.secureEnclaveKeyHash
            server.events.append(ServerEvent(level: .info, message: "~/.ssh/config’ten içe aktarıldı; yeni anahtar kuruldu."))
            let updated = servers + [server]
            try config.writeIncludeFile(updated, onePasswordSocket: onePassword.socketPath)
            servers = updated
            persist()

            // Sigil's entry is live (its Include comes first), so the old block can go. If commenting it out fails the
            // alias still works through Sigil; just tell the user.
            progress("Eski ayar devralınıyor")
            do { try config.retire(candidate) } catch {
                log(id, .warning, "~/.ssh/config’teki eski blok yorum satırına alınamadı: \(error.localizedDescription)")
            }

            if removeOldKey, let blob = Self.publicKeyBlob(ofIdentityFile: candidate.identityFile, sshDir: paths.sshDir) {
                progress("Eski anahtar sunucudan kaldırılıyor")
                do {
                    try await remote.removeKey(target: target, auth: auth(keyStore, keyFile), blob: blob)
                    log(id, .info, "Eski anahtar sunucudan kaldırıldı.")
                } catch {
                    log(id, .warning, "Eski anahtar sunucudan kaldırılamadı: \(error.localizedDescription)")
                }
            }
            return servers.first { $0.id == id } ?? server
        } catch {
            if installed {
                try? await remote.removeKey(target: target, auth: oldAuth, blob: material.blob)
            }
            await deleteKey(keyStore, fileName: keyFile, material: material)
            if createdKnownHosts, !servers.contains(where: { $0.host == candidate.host && $0.port == candidate.port }) {
                await hostKeys.forget(host: candidate.host, port: candidate.port)
            }
            throw error
        }
    }

    /// Base64 body of `<identityFile>.pub`, if it exists.
    static func publicKeyBlob(ofIdentityFile file: String?, sshDir: URL) -> String? {
        guard var path = file else { return nil }
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + "/" + path.dropFirst(2) }
        guard let text = try? String(contentsOfFile: path + ".pub", encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return try? Validation.keyBlob(String(parts[1]))
    }

    // MARK: Rotation

    /// Keychain keys rotate silently. Keys that need approval (1Password, Secure Enclave) would pop prompts out of
    /// nowhere, so those wait for the user. 1Password servers get a notification (once per due period); Secure Enclave
    /// servers are never handled in the background at all and only show as due in the app.
    public func rotateDueServers() async {
        for s in servers where s.isRotationDue() {
            if runsUnattended(s) {
                await rotate(s.id, automatic: true)
                continue
            }
            guard !backgroundOff(s), !notifiedDue.contains(s.id) else { continue }
            notifiedDue.insert(s.id)
            notify?("\(s.alias): anahtar yenileme zamanı", "Onay gerektiği için seni bekliyor. Sigil’te “Anahtarı Şimdi Yenile”ye bas.")
        }
    }

    /// Servers whose rotation is due and waiting for the user's approval.
    public var awaitingManualRotation: [Server] { servers.filter { !runsUnattended($0) && $0.isRotationDue(retryAfter: 0) } }

    /// Using this server's key, and its jump host's, never asks the user for anything: Sigil may do it unattended.
    public func runsUnattended(_ s: Server) -> Bool {
        guard !s.store.asksForApproval else { return false }
        guard let j = s.jumpServerID, let jump = server(j) else { return true }
        return !jump.store.asksForApproval
    }

    /// Secure Enclave servers (and servers reached through one) are never contacted in the background, not even to
    /// check that they are up: only when the user asks.
    public func backgroundOff(_ s: Server) -> Bool {
        if s.store == .secureEnclave { return true }
        guard let j = s.jumpServerID, let jump = server(j) else { return false }
        return jump.store == .secureEnclave
    }
    private var notifiedDue: Set<UUID> = []

    /// Replaces the server's key without ever being locked out:
    /// new key → install (authenticated with the old key) → verify login with the new key →
    /// switch the local config → only then remove the old key from the server → delete the old key locally.
    @discardableResult
    public func rotate(_ id: UUID, automatic: Bool = false) async -> Bool {
        guard let old = server(id), busy[id] == nil else { return false }
        busy[id] = "Anahtar yenileniyor"
        defer { busy[id] = nil }

        let target = self.target(for: old)
        let newFile = Self.keyFileName(for: id)
        let origin = automatic ? "Otomatik" : "Manuel"
        var material: KeyMaterial?

        do {
            let m = try await generateKey(old.store, fileName: newFile, alias: old.alias)
            material = m

            try await remote.installKey(target: target, auth: auth(old.store, old.keyFileName), publicKeyLine: m.publicKeyLine)
            do {
                try await remote.ping(target: target, auth: auth(old.store, newFile))
            } catch {
                throw DeckError.ssh("Yeni anahtarla giriş doğrulanamadı: \(error.localizedDescription)")
            }

            // The new key demonstrably works: make it the one we use from now on.
            let previous = servers
            update(id) {
                $0.keyFileName = newFile
                $0.publicKeyBlob = m.blob
                $0.keyFingerprint = m.fingerprint
                $0.onePasswordItemID = m.onePasswordItemID
                $0.onePasswordVaultID = m.onePasswordVaultID
                $0.secureEnclaveKeyHash = m.secureEnclaveKeyHash
                $0.lastRotatedAt = Date()
                $0.lastRotationFailureAt = nil
                $0.lastReachable = true
                $0.lastCheckedAt = Date()
            }
            do {
                try config.writeIncludeFile(servers, onePasswordSocket: onePassword.socketPath)
            } catch {
                servers = previous
                persist()
                throw error
            }

            // Cut off the old key. If that fails, remember it and retry later rather than leave it forever.
            var warning: String?
            do {
                try await remote.removeKey(target: target, auth: auth(old.store, newFile), blob: old.publicKeyBlob)
            } catch {
                warning = error.localizedDescription
                update(id) { $0.pendingKeyRemovals.append(old.publicKeyBlob) }
            }
            await deleteKey(of: old)
            notifiedDue.remove(id)

            if let warning {
                log(id, .warning, "\(origin) anahtar yenileme tamamlandı ama eski anahtar sunucudan kaldırılamadı (sonra tekrar denenecek): \(warning)")
            } else {
                log(id, .info, "\(origin) anahtar yenileme tamamlandı; eski anahtar sunucudan silindi.")
            }
            return true
        } catch {
            // The old key is still the active one. Clean up whatever we created for the new key.
            if let m = material {
                try? await remote.removeKey(target: target, auth: auth(old.store, old.keyFileName), blob: m.blob)
                await deleteKey(old.store, fileName: newFile, material: m)
            }
            update(id) { $0.lastRotationFailureAt = Date() }
            log(id, .error, "\(origin) anahtar yenileme başarısız (eski anahtar geçerli): \(error.localizedDescription)")
            if automatic { notify?("\(old.alias): anahtar yenilenemedi", "Eski anahtar geçerli. 6 saat sonra tekrar denenecek.") }
            return false
        }
    }

    /// Existing group names, for pickers.
    public var groups: [String] {
        Array(Set(servers.compactMap { $0.group?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func setGroup(_ id: UUID, _ group: String?) {
        let g = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.group = (g?.isEmpty ?? true) ? nil : String(g!.prefix(60)) }
    }

    public func setEnvironment(_ id: UUID, _ env: ServerEnvironment?) {
        update(id) { $0.environment = env }
    }

    /// Renames the ssh alias (the `ssh <alias>` shortcut). The key and the server are unchanged.
    public func rename(_ id: UUID, to newAlias: String) throws {
        guard let s = server(id) else { throw DeckError.notFound }
        let alias = try Validation.alias(newAlias)
        guard alias != s.alias else { return }
        if alias.lowercased() != s.alias.lowercased() { try ensureAliasFree(alias) }
        var updated = servers
        guard let i = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[i].alias = alias
        try config.writeIncludeFile(updated, onePasswordSocket: onePassword.socketPath)
        servers = updated
        persist()
        log(id, .info, "Kısayol adı “\(s.alias)” → “\(alias)” olarak değişti.")
    }

    public func setRotationInterval(_ id: UUID, days: Int) {
        update(id) { $0.rotationIntervalDays = max(0, days) }
    }

    // MARK: Status & history

    /// - Parameter interactive: the user asked for it. For keys that need approval only an interactive check logs in
    ///   (approval prompt); background checks just confirm the SSH server answers, and skip Secure Enclave servers.
    public func checkStatus(_ id: UUID, interactive: Bool = false) async {
        guard let s = server(id), busy[id] == nil else { return }
        if !interactive && backgroundOff(s) { return }
        busy[id] = "Bağlantı denetleniyor"
        defer { busy[id] = nil }

        let target = self.target(for: s)
        let useKey = interactive || runsUnattended(s)

        // Host key watch: does the server still present the key we trusted?
        let scanned = try? await scanKeys(host: s.host, port: s.port, jumpID: s.jumpServerID)
        if let keys = scanned {
            let status = await hostKeys.knownStatus(keys, host: s.host, port: s.port)
            let mismatch = status == .mismatch
            if mismatch && s.hostKeyMismatch != true {
                log(id, .error, "Sunucunun host key’i değişti! Sunucu yeniden kurulmadıysa araya biri girmiş olabilir; Sigil bu sunucuya bağlanmayı reddediyor.")
                notify?("\(s.alias): sunucunun mührü değişti", "Host key, kayıtlı olandan farklı. Yeniden kurulum yapılmadıysa bağlanma.")
            }
            if mismatch != (s.hostKeyMismatch ?? false) { update(id) { $0.hostKeyMismatch = mismatch } }
        }

        do {
            if useKey {
                try await remote.ping(target: target, auth: auth(s.store, s.keyFileName))
            } else if scanned == nil {
                try await remote.probe(target: target)   // throws a readable "not answering" error
            }
            update(id) { $0.lastCheckedAt = Date(); $0.lastReachable = true }
            if useKey { await retryPendingRemovals(id) }
        } catch {
            let wasReachable = s.lastReachable != false
            update(id) { $0.lastCheckedAt = Date(); $0.lastReachable = false }
            if wasReachable {
                log(id, .warning, "Sunucuya bağlanılamadı: \(error.localizedDescription)")
                notify?("\(s.alias) ulaşılamıyor", error.localizedDescription)
            }
        }
    }

    /// - Parameter interactive: the user pressed a button, so servers that need Touch ID are checked too.
    public func checkAll(interactive: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for id in servers.map(\.id) {
                group.addTask { await self.checkStatus(id, interactive: interactive) }
            }
        }
    }

    /// Recent logins as recorded by the server itself.
    public func loginHistory(_ id: UUID) async throws -> [String] {
        guard let s = server(id) else { throw DeckError.notFound }
        let target = self.target(for: s)
        return try await remote.loginHistory(target: target, auth: auth(s.store, s.keyFileName))
    }

    private func retryPendingRemovals(_ id: UUID) async {
        guard let s = server(id), !s.pendingKeyRemovals.isEmpty else { return }
        let target = self.target(for: s)
        var remaining: [String] = []
        for blob in s.pendingKeyRemovals {
            do { try await remote.removeKey(target: target, auth: auth(s.store, s.keyFileName), blob: blob) }
            catch { remaining.append(blob) }
        }
        if remaining.count != s.pendingKeyRemovals.count {
            update(id) { $0.pendingKeyRemovals = remaining }
            if remaining.isEmpty { log(id, .info, "Eski anahtar sunucudan sonunda kaldırıldı.") }
        }
    }

    // MARK: Foreign key audit

    /// Reads the server's authorized_keys and records every key Sigil did not install. Returns the number of keys
    /// seen for the first time (and notifies about them). 1Password servers only audit when `interactive`, since
    /// using the key asks for approval.
    @discardableResult
    public func audit(_ id: UUID, interactive: Bool = true) async throws -> Int {
        guard let s = server(id) else { throw DeckError.notFound }
        if !interactive && !runsUnattended(s) { return 0 }
        guard busy[id] == nil else { throw DeckError.busy }
        busy[id] = "Mühürler denetleniyor"
        defer { busy[id] = nil }

        let target = self.target(for: s)
        let lines = try await remote.listAuthorizedKeys(target: target, auth: auth(s.store, s.keyFileName))
        // Keys the user granted through Sigil are known, not foreign.
        let ours = Set([s.publicKeyBlob] + s.pendingKeyRemovals + (s.grants ?? []).map(\.publicKeyBlob))
        let previous = Dictionary(uniqueKeysWithValues: (s.foreignKeys ?? []).map { ($0.blob, $0) })
        let local = Self.localPublicKeys(sshDir: paths.sshDir)

        var fresh = 0
        let found: [ForeignKey] = lines.filter { !ours.contains($0.blob) }.map { line in
            if let known = previous[line.blob] { return known }
            fresh += 1
            return ForeignKey(type: line.type, blob: line.blob, comment: line.comment,
                              fingerprint: Fingerprint.sha256(ofBase64: line.blob) ?? "", localMatch: local[line.blob])
        }
        update(id) { $0.foreignKeys = found; $0.lastAuditAt = Date() }

        // Only alert when something new appeared after a first baseline.
        if fresh > 0, s.lastAuditAt != nil {
            log(id, .warning, "\(fresh) yeni yabancı anahtar bulundu.")
            notify?("\(s.alias): yeni yabancı anahtar", "Sunucunun authorized_keys dosyasına Sigil dışından \(fresh) anahtar eklenmiş.")
        }
        return fresh
    }

    /// Background audits every 6 hours, for servers whose key needs no approval (the rest only on demand).
    public func auditDueServers() async {
        for s in servers where runsUnattended(s) && s.lastReachable != false {
            if let last = s.lastAuditAt, Date().timeIntervalSince(last) < 6 * 3600 { continue }
            _ = try? await audit(s.id, interactive: false)
        }
    }

    public func acknowledgeForeignKey(_ id: UUID, blob: String, _ value: Bool = true) {
        update(id) { s in
            guard let i = s.foreignKeys?.firstIndex(where: { $0.blob == blob }) else { return }
            s.foreignKeys?[i].acknowledged = value
        }
    }

    public func removeForeignKey(_ id: UUID, blob: String) async throws {
        guard let s = server(id) else { throw DeckError.notFound }
        guard blob != s.publicKeyBlob else { throw DeckError.invalid("Sigil’in kendi anahtarı buradan silinemez.") }
        guard busy[id] == nil else { throw DeckError.busy }
        busy[id] = "Anahtar kaldırılıyor"
        defer { busy[id] = nil }
        let target = self.target(for: s)
        try await remote.removeKey(target: target, auth: auth(s.store, s.keyFileName), blob: blob)
        update(id) { $0.foreignKeys?.removeAll { $0.blob == blob } }
        log(id, .info, "Yabancı anahtar sunucudan kaldırıldı (\(Fingerprint.sha256(ofBase64: blob) ?? "?")).")
    }

    /// `blob → "~/.ssh/name.pub"` for public keys on this Mac, to label keys the user will recognise.
    static func localPublicKeys(sshDir: URL) -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: sshDir.path)) ?? [] where name.hasSuffix(".pub") {
            guard let text = try? String(contentsOf: sshDir.appendingPathComponent(name), encoding: .utf8) else { continue }
            let parts = text.split(separator: " ")
            if parts.count >= 2 { out[String(parts[1])] = "~/.ssh/\(name)" }
        }
        return out
    }

    /// Current host keys of a managed server (for re-verifying after a host key change).
    public func scanHostKeys(of id: UUID) async throws -> [HostKey] {
        guard let s = server(id) else { throw DeckError.notFound }
        return try await scanKeys(host: s.host, port: s.port, jumpID: s.jumpServerID)
    }

    /// The user confirmed (out of band) that the server really was rebuilt: replace the recorded host key.
    public func acceptNewHostKey(_ id: UUID, keys: [HostKey]) async throws {
        guard let s = server(id) else { throw DeckError.notFound }
        await hostKeys.forget(host: s.host, port: s.port)
        try await hostKeys.trust(keys, host: s.host, port: s.port)
        update(id) { $0.hostKeyMismatch = false; $0.createdKnownHostsEntry = true }
        log(id, .warning, "Yeni host key kullanıcı onayıyla kabul edildi (\(keys.first?.fingerprint ?? "")).")
        await checkStatus(id, interactive: true)
    }

    // MARK: Health

    /// Collects a read-only snapshot. Servers whose key needs approval only when `interactive`.
    @discardableResult
    public func collectHealth(_ id: UUID, interactive: Bool = true) async throws -> ServerHealth? {
        guard let s = server(id) else { throw DeckError.notFound }
        if !interactive && !runsUnattended(s) { return nil }
        guard busy[id] == nil else { throw DeckError.busy }
        busy[id] = "Sağlık ölçülüyor"
        defer { busy[id] = nil }

        let target = self.target(for: s)
        let h = try await remote.collectHealth(target: target, auth: auth(s.store, s.keyFileName))
        let problems = h.problems()
        let fresh = problems.filter { !(s.announcedProblems ?? []).contains($0) }
        update(id) {
            $0.health = h
            var history = $0.healthHistory ?? []
            history.append(HealthSample(at: h.collectedAt, disk: h.diskUsage, memory: h.memoryUsage, load: h.loadRatio))
            $0.healthHistory = Array(history.suffix(48))
            $0.announcedProblems = problems
        }
        if !fresh.isEmpty {
            notify?("\(s.alias): dikkat", fresh.joined(separator: " · "))
        }
        return h
    }

    /// Background health checks, hourly, for servers whose key needs no approval.
    public func collectDueHealth() async {
        for s in servers where runsUnattended(s) && s.lastReachable == true {
            if let last = s.health?.collectedAt, Date().timeIntervalSince(last) < 3600 { continue }
            _ = try? await collectHealth(s.id, interactive: false)
        }
    }

    // MARK: Hardening

    public enum HardeningOutcome: Equatable, Sendable {
        case applied(HardeningState)
        /// The access change could not be confirmed and the server rolled itself back.
        case rolledBack(String)
    }

    public func hardeningState(_ id: UUID) async throws -> HardeningState {
        guard let s = server(id) else { throw DeckError.notFound }
        let target = self.target(for: s)
        return try await remote.hardeningState(target: target, auth: auth(s.store, s.keyFileName))
    }

    /// Applies the plan. Access-changing parts go in with a watchdog on the server and are only kept once a fresh
    /// connection with Sigil's key succeeds; otherwise the server undoes them by itself.
    public func harden(_ id: UUID, plan: HardeningPlan, progress: @MainActor (String) -> Void = { _ in }) async throws -> HardeningOutcome {
        guard let s = server(id) else { throw DeckError.notFound }
        guard busy[id] == nil else { throw DeckError.busy }
        busy[id] = "Sertleştiriliyor"
        defer { busy[id] = nil }
        let target = self.target(for: s)
        let a = auth(s.store, s.keyFileName)

        progress("Sunucunun durumu okunuyor")
        let state = try await remote.hardeningState(target: target, auth: a)
        guard state.canAdminister else {
            throw DeckError.invalid("Bu kullanıcı root değil ve şifresiz sudo yetkisi yok; değişiklik yapılamaz.")
        }
        if (plan.disablePasswordLogin || plan.restrictRootLogin) && !state.sshdIncludesDropIns {
            throw DeckError.invalid("sshd_config, /etc/ssh/sshd_config.d klasörünü içermiyor; Sigil ana dosyayı değiştirmeyecek.")
        }
        if (plan.enableFirewall || plan.installFail2ban || plan.enableUnattendedUpgrades) && !state.isDebianLike {
            throw DeckError.invalid("Firewall, fail2ban ve otomatik güncellemeler şimdilik yalnızca Ubuntu/Debian’da destekleniyor.")
        }

        if plan.touchesAccess {
            let token = (0..<2).map { _ in UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }.joined().prefix(32)
            progress("Ayarlar uygulanıyor (45 sn içinde doğrulanmazsa kendiliğinden geri alınır)")
            let out = try await remote.runScript(target: target, auth: a, HardeningScript.apply(plan, state: state, token: String(token)))
            if out.contains("RESULT sshd_invalid") { throw DeckError.invalid("Yeni sshd ayarı doğrulamadan geçemedi; hiçbir şey değişmedi.") }
            guard out.contains("RESULT applied") else { throw DeckError.ssh("Sunucu beklenen yanıtı vermedi: \(out.trimmed)") }

            progress("Yeni bağlantıyla erişim doğrulanıyor")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let confirmed = (try? await remote.runScript(target: target, auth: a, HardeningScript.confirm(token: String(token))))?
                .contains("RESULT confirmed") ?? false
            if !confirmed {
                progress("Doğrulanamadı; sunucunun geri almasını bekliyorum")
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                let back = (try? await remote.ping(target: target, auth: a)) != nil
                let message = back ? "Değişiklik doğrulanamadı ve sunucu eski ayarlara döndü; erişim yerinde."
                                   : "Değişiklik doğrulanamadı; sunucu geri alma yaptı ama erişim henüz doğrulanamadı."
                log(id, .error, "Sertleştirme geri alındı: \(message)")
                return .rolledBack(message)
            }
            log(id, .info, "Sertleştirme uygulandı ve doğrulandı: " + [
                plan.disablePasswordLogin ? "şifreyle giriş kapatıldı" : nil,
                plan.restrictRootLogin ? (state.isRoot ? "root yalnızca anahtarla" : "root girişi kapatıldı") : nil,
                plan.enableFirewall ? "firewall açıldı" : nil,
            ].compactMap { $0 }.joined(separator: ", ") + ".")
        }

        if plan.installFail2ban || plan.enableUnattendedUpgrades {
            progress("Paketler kuruluyor")
            let out = try await remote.runScript(target: target, auth: a, HardeningScript.extras(plan))
            log(id, out.contains("extras_ok") ? .info : .warning,
                out.contains("extras_ok") ? "fail2ban / otomatik güncellemeler hazır." : "Paket kurulumu tam tamamlanmadı.")
        }

        progress("Son durum okunuyor")
        return .applied(try await remote.hardeningState(target: target, auth: a))
    }

    // MARK: Quick actions

    public func saveAction(_ action: QuickAction) throws {
        let a = try action.validated()
        if let i = actions.firstIndex(where: { $0.id == a.id }) { actions[i] = a } else { actions.append(a) }
        try actionStore.save(actions)
    }

    public func deleteAction(_ id: UUID) throws {
        actions.removeAll { $0.id == id }
        try actionStore.save(actions)
    }

    /// Runs the command on every listed server at once; results arrive as each server finishes.
    public func run(_ action: QuickAction, on serverIDs: [UUID], each: @MainActor (ActionResult) -> Void = { _ in }) async -> [ActionResult] {
        let targets: [(UUID, RemoteTarget, RemoteAuth)] = serverIDs.compactMap { id in
            guard let s = server(id) else { return nil }
            return (id, self.target(for: s), auth(s.store, s.keyFileName))
        }
        let remote = self.remote
        var results: [ActionResult] = []
        await withTaskGroup(of: ActionResult.self) { group in
            for (id, target, a) in targets {
                group.addTask {
                    let start = Date()
                    do {
                        let r = try await remote.run(command: action.command, target: target, auth: a)
                        return ActionResult(serverID: id, exitCode: r.exitCode, output: r.stdout, errorOutput: r.stderr,
                                            duration: Date().timeIntervalSince(start))
                    } catch {
                        return ActionResult(serverID: id, exitCode: -1, output: "", errorOutput: error.localizedDescription,
                                            duration: Date().timeIntervalSince(start))
                    }
                }
            }
            for await r in group {
                results.append(r)
                each(r)
            }
        }
        for r in results {
            log(r.serverID, r.succeeded ? .info : .warning, "“\(action.name)” çalıştırıldı (çıkış kodu \(r.exitCode)).")
        }
        return results
    }

    // MARK: Tunnels

    public func saveTunnel(_ serverID: UUID, _ tunnel: TunnelProfile) throws {
        let t = try tunnel.validated()
        let clash = servers.flatMap { s in (s.tunnels ?? []).map { (s.id, $0) } }
            .first { $0.1.localPort == t.localPort && $0.1.id != t.id }
        if let clash { throw DeckError.invalid("Yerel port \(t.localPort) zaten “\(clash.1.name)” tünelinde kullanılıyor.") }
        update(serverID) { s in
            var list = s.tunnels ?? []
            if let i = list.firstIndex(where: { $0.id == t.id }) { list[i] = t } else { list.append(t) }
            s.tunnels = list
        }
    }

    public func deleteTunnel(_ serverID: UUID, _ tunnelID: UUID) {
        stopTunnel(tunnelID)
        update(serverID) { $0.tunnels?.removeAll { $0.id == tunnelID } }
    }

    public func startTunnel(_ serverID: UUID, _ tunnelID: UUID) async throws {
        guard let s = server(serverID), let t = s.tunnels?.first(where: { $0.id == tunnelID }) else { throw DeckError.notFound }
        guard activeTunnels[tunnelID] == nil else { return }
        if RemoteService.isListening(port: t.localPort) {
            throw DeckError.invalid("localhost:\(t.localPort) başka bir uygulama tarafından kullanılıyor.")
        }
        let target = self.target(for: s)
        let proc = try await remote.startTunnel(target: target, auth: auth(s.store, s.keyFileName), tunnel: t) { [weak self] reason in
            Task { @MainActor in
                guard let self, self.activeTunnels[tunnelID] != nil else { return }
                self.tunnelProcesses[tunnelID] = nil
                self.activeTunnels[tunnelID] = nil
                self.log(serverID, .warning, "“\(t.name)” tüneli kapandı\(reason.trimmed.isEmpty ? "" : ": " + reason.trimmed)")
                self.notify?("\(s.alias): tünel kapandı", t.name)
            }
        }
        tunnelProcesses[tunnelID] = proc
        activeTunnels[tunnelID] = serverID
    }

    public func stopTunnel(_ tunnelID: UUID) {
        guard let p = tunnelProcesses[tunnelID] else { return }
        activeTunnels[tunnelID] = nil        // first, so the exit handler stays quiet
        tunnelProcesses[tunnelID] = nil
        p.process.terminate()
    }

    public func stopAllTunnels() {
        for id in Array(tunnelProcesses.keys) { stopTunnel(id) }
    }

    // MARK: Emergency

    /// "My Mac or a key may be compromised": rotate every server now, one after another. Returns per-server success.
    public func rotateAll(progress: @MainActor (Server, Bool) -> Void = { _, _ in }) async -> [UUID: Bool] {
        var results: [UUID: Bool] = [:]
        for s in servers {
            let ok = await rotate(s.id)
            results[s.id] = ok
            if let latest = server(s.id) { progress(latest, ok) }
        }
        let failed = results.values.filter { !$0 }.count
        notify?("Acil yenileme bitti", failed == 0 ? "Tüm anahtarlar yenilendi." : "\(failed) sunucuda yenileme başarısız; ayrıntılar uygulamada.")
        return results
    }

    // MARK: Removing

    /// - Parameter removeRemoteKey: also take our public key off the server. If that fails this throws and
    ///   nothing is deleted, so the user can retry or choose to delete locally only.
    public func removeServer(_ id: UUID, removeRemoteKey: Bool) async throws {
        guard let s = server(id) else { throw DeckError.notFound }
        guard busy[id] == nil else { throw DeckError.busy }
        let deps = dependents(of: id)
        guard deps.isEmpty else {
            throw DeckError.invalid("Önce şu sunucuların atlama ayarını değiştir: " + deps.map(\.alias).joined(separator: ", "))
        }
        busy[id] = "Siliniyor"
        defer { busy[id] = nil }

        if removeRemoteKey {
            let target = self.target(for: s)
            do {
                for blob in s.pendingKeyRemovals + [s.publicKeyBlob] {
                    try await remote.removeKey(target: target, auth: auth(s.store, s.keyFileName), blob: blob, allowEmpty: true)
                }
            } catch {
                throw DeckError.remoteRemovalFailed(error.localizedDescription)
            }
        }

        let remaining = servers.filter { $0.id != id }
        try config.writeIncludeFile(remaining, onePasswordSocket: onePassword.socketPath)
        servers = remaining
        persist()
        await deleteKey(of: s)
        if s.createdKnownHostsEntry == true, !remaining.contains(where: { $0.host == s.host && $0.port == s.port }) {
            await hostKeys.forget(host: s.host, port: s.port)
        }
    }

    // MARK: Jump hosts

    /// How to reach a managed server (directly, or through its jump server).
    public func target(for s: Server) -> RemoteTarget {
        guard let j = s.jumpServerID, let jump = server(j) else { return RemoteTarget(host: s.host, port: s.port, user: s.user) }
        let pc = remote.proxyCommand(through: RemoteTarget(host: jump.host, port: jump.port, user: jump.user),
                                     auth: auth(jump.store, jump.keyFileName))
        return RemoteTarget(host: s.host, port: s.port, user: s.user, proxyCommand: pc)
    }

    func draftTarget(_ d: ServerDraft) throws -> RemoteTarget {
        guard let j = d.jumpServerID else { return RemoteTarget(host: d.host, port: d.port, user: d.user) }
        guard let jump = server(j) else { throw DeckError.invalid("Atlama sunucusu bulunamadı.") }
        guard jump.jumpServerID == nil else { throw DeckError.invalid("Atlama sunucusunun kendisi başka bir sunucu üzerinden bağlanıyor; tek seviye destekleniyor.") }
        let pc = remote.proxyCommand(through: RemoteTarget(host: jump.host, port: jump.port, user: jump.user),
                                     auth: auth(jump.store, jump.keyFileName))
        return RemoteTarget(host: d.host, port: d.port, user: d.user, proxyCommand: pc)
    }

    /// Host keys, scanned locally or — for servers behind a jump host — from the jump server.
    func scanKeys(host: String, port: Int, jumpID: UUID?) async throws -> [HostKey] {
        guard let j = jumpID, let jump = server(j) else { return try await hostKeys.scan(host: host, port: port) }
        return try await remote.keyscan(host: host, port: port,
                                        via: RemoteTarget(host: jump.host, port: jump.port, user: jump.user),
                                        auth: auth(jump.store, jump.keyFileName))
    }

    /// Servers that use `id` as their jump host.
    public func dependents(of id: UUID) -> [Server] { servers.filter { $0.jumpServerID == id } }

    public func setJump(_ id: UUID, _ jumpID: UUID?) throws {
        if let jumpID {
            guard jumpID != id, let jump = server(jumpID) else { throw DeckError.invalid("Geçersiz atlama sunucusu.") }
            guard jump.jumpServerID == nil else { throw DeckError.invalid("Atlama sunucusu doğrudan erişilebilir olmalı (tek seviye).") }
            guard dependents(of: id).isEmpty else { throw DeckError.invalid("Bu sunucu başkalarına atlama noktası; kendisi atlamalı olamaz.") }
        }
        var updated = servers
        guard let i = updated.firstIndex(where: { $0.id == id }) else { throw DeckError.notFound }
        updated[i].jumpServerID = jumpID
        try config.writeIncludeFile(updated, onePasswordSocket: onePassword.socketPath)
        servers = updated
        persist()
    }

    // MARK: Key store plumbing

    private func generateKey(_ store: KeyStoreKind, fileName: String, alias: String) async throws -> KeyMaterial {
        switch store {
        case .keychain: return try await keys.generate(fileName: fileName, comment: "sigil:\(alias)")
        case .onePassword: return try await onePassword.generate(fileName: fileName, alias: alias)
        case .secureEnclave: return try await secureEnclave.generate(fileName: fileName, alias: alias)
        }
    }

    static func creatingMessage(_ store: KeyStoreKind) -> String {
        switch store {
        case .keychain: return "Bu sunucuya özel anahtar oluşturuluyor"
        case .onePassword: return "Anahtar 1Password’de oluşturuluyor"
        case .secureEnclave: return "Anahtar Secure Enclave’de oluşturuluyor"
        }
    }

    /// Keychain: key files + Keychain passphrase removed. 1Password: item moved to Archive (recoverable).
    /// Secure Enclave: identity deleted, handle files removed.
    private func deleteKey(_ store: KeyStoreKind, fileName: String, itemID: String?, vaultID: String?, secureEnclaveHash: String?) async {
        switch store {
        case .keychain:
            await keys.delete(fileName: fileName)
        case .onePassword:
            if let itemID { await onePassword.archive(itemID: itemID, vaultID: vaultID) }
            onePassword.deletePublicKey(fileName: fileName)
        case .secureEnclave:
            await secureEnclave.delete(fileName: fileName, keyHash: secureEnclaveHash)
        }
    }

    private func deleteKey(_ store: KeyStoreKind, fileName: String, material m: KeyMaterial) async {
        await deleteKey(store, fileName: fileName, itemID: m.onePasswordItemID, vaultID: m.onePasswordVaultID,
                        secureEnclaveHash: m.secureEnclaveKeyHash)
    }

    private func deleteKey(of s: Server) async {
        await deleteKey(s.store, fileName: s.keyFileName, itemID: s.onePasswordItemID, vaultID: s.onePasswordVaultID,
                        secureEnclaveHash: s.secureEnclaveKeyHash)
    }

    func auth(_ store: KeyStoreKind, _ fileName: String) -> RemoteAuth {
        switch store {
        case .keychain: return .key(fileName: fileName)
        case .onePassword: return .agent(publicKeyFile: fileName, socket: onePassword.socketPath)
        case .secureEnclave: return .securityKey(fileName: fileName)
        }
    }

    private func writeConfig() {
        try? config.writeIncludeFile(servers, onePasswordSocket: onePassword.socketPath)
    }

    // MARK: Helpers

    private func ensureAliasFree(_ alias: String) throws {
        if servers.contains(where: { $0.alias.lowercased() == alias.lowercased() }) { throw DeckError.aliasTaken(alias) }
        try config.ensureAliasAvailable(alias)
    }

    /// Runs `body` with the server marked busy (one operation per server at a time).
    func withBusy<T>(_ id: UUID, _ label: String, _ body: () async throws -> T) async throws -> T {
        guard busy[id] == nil else { throw DeckError.busy }
        busy[id] = label
        defer { busy[id] = nil }
        return try await body()
    }

    func update(_ id: UUID, _ change: (inout Server) -> Void) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        change(&servers[i])
        persist()
    }

    func log(_ id: UUID, _ level: ServerEvent.Level, _ message: String) {
        update(id) {
            $0.events.append(ServerEvent(level: level, message: message))
            if $0.events.count > 100 { $0.events.removeFirst($0.events.count - 100) }
        }
    }

    private func persist() {
        do { try store.save(servers) } catch { banner = "Liste kaydedilemedi: \(error.localizedDescription)" }
    }

    static func keyFileName(for id: UUID) -> String {
        let unique = UUID().uuidString.lowercased().prefix(6)
        return "\(id.uuidString.lowercased().prefix(8))-\(ConfigManager.stamp())-\(unique)_ed25519"
    }
}
