import XCTest
@testable import SigilCore

/// End-to-end tests against a real OpenSSH server (a private sshd on 127.0.0.1 run as the current user).
/// Password login cannot be verified by a non-root sshd, so the first-key installation is bootstrapped with
/// a key instead; every other step (host key scan/trust, key creation, install, verify, config, rotation,
/// removal, rollback) runs for real.
@MainActor
final class IntegrationTests: XCTestCase {

    private func makeModel(_ box: Sandbox, _ sshd: LocalSSHD, authorizedKeysPath: String? = nil) -> DeckModel {
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: authorizedKeysPath ?? sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        return model
    }

    private func draft(_ sshd: LocalSSHD, alias: String = "testbox") -> ServerDraft {
        ServerDraft(alias: alias, host: "127.0.0.1", port: sshd.port, user: NSUserName(), rotationIntervalDays: 30)
    }

    private func add(_ model: DeckModel, _ sshd: LocalSSHD, alias: String = "testbox") async throws -> Server {
        let (d, hostKeys) = try await model.scanHostKeys(for: draft(sshd, alias: alias))
        return try await model.addServer(draft: d, password: "unused", hostKeys: hostKeys)
    }

    /// `ssh <alias>` using the config we generated, exactly as a user would type it.
    private func sshAlias(_ box: Sandbox, _ alias: String) async throws -> ShellResult {
        try await Shell.run("/usr/bin/ssh", [
            "-F", box.paths.mainConfig.path,
            "-o", "UserKnownHostsFile=\(box.paths.knownHosts.path)",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            alias, "echo alias-works",
        ])
    }

    func testHostKeyScanShowsTheRealServerFingerprint() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        let (_, keys) = try await model.scanHostKeys(for: draft(sshd))

        let expected = try LocalSSHD.run("/usr/bin/ssh-keygen", ["-lf", sshd.dir.appendingPathComponent("host_ed25519.pub").path])
        let ed = try XCTUnwrap(keys.first { $0.algorithm == "ssh-ed25519" })
        XCTAssertTrue(expected.contains(ed.fingerprint), "scanned \(ed.fingerprint) vs host key \(expected)")
    }

    func testAddServerEndToEndAndAliasConnects() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)

        var steps: [String] = []
        let (d, hostKeys) = try await model.scanHostKeys(for: draft(sshd))
        let server = try await model.addServer(draft: d, password: "unused", hostKeys: hostKeys) { steps.append($0) }

        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertEqual(server.alias, "testbox")
        XCTAssertTrue(server.keyFingerprint.hasPrefix("SHA256:"))

        // the new public key is on the server, next to the bootstrap key
        let lines = sshd.authorizedKeyLines
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.contains(server.publicKeyBlob) })

        // config entry exists and `ssh testbox` works with no further input
        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        XCTAssertTrue(cfg.contains("Host testbox"))
        let r = try await sshAlias(box, "testbox")
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(r.stdout.contains("alias-works"))

        // state persisted: a fresh model sees the server
        let reloaded = DeckModel(paths: box.paths, hardened: false)
        reloaded.load()
        XCTAssertEqual(reloaded.servers.map(\.alias), ["testbox"])
    }

    func testDuplicateAliasIsRejectedBeforeAnythingIsCreated() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        _ = try await add(model, sshd)

        let keyFilesBefore = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path).sorted()
        do {
            _ = try await add(model, sshd, alias: "TESTBOX")
            XCTFail("duplicate alias must be rejected")
        } catch let e as DeckError {
            XCTAssertEqual(e, .aliasTaken("TESTBOX"))
        }
        let keyFilesAfter = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path).sorted()
        XCTAssertEqual(keyFilesBefore, keyFilesAfter)
        XCTAssertEqual(sshd.authorizedKeyLines.count, 2)
    }

    func testRotationReplacesKeyOnServerAndLocally() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        let before = try await add(model, sshd)
        let oldPrivate = box.paths.keyURL(before.keyFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPrivate.path))

        let ok = await model.rotate(before.id)
        XCTAssertTrue(ok)

        let after = try XCTUnwrap(model.server(before.id))
        XCTAssertNotEqual(after.keyFileName, before.keyFileName)
        XCTAssertNotEqual(after.publicKeyBlob, before.publicKeyBlob)
        XCTAssertGreaterThan(after.lastRotatedAt, before.lastRotatedAt)
        XCTAssertNil(after.lastRotationFailureAt)
        XCTAssertTrue(after.pendingKeyRemovals.isEmpty)

        // server: old key gone, new key present, bootstrap untouched
        let lines = sshd.authorizedKeyLines
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains { $0.contains(before.publicKeyBlob) })
        XCTAssertTrue(lines.contains { $0.contains(after.publicKeyBlob) })

        // local: old key files deleted, new ones exist, config points at the new key
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPrivate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPrivate.appendingPathExtension("pub").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.paths.keyURL(after.keyFileName).path))
        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        XCTAssertTrue(cfg.contains(after.keyFileName))
        XCTAssertFalse(cfg.contains(before.keyFileName))

        // the alias still works, using the new key
        let r = try await sshAlias(box, "testbox")
        XCTAssertTrue(r.succeeded, r.stderr)

        XCTAssertTrue(after.events.contains { $0.level == .info && $0.message.contains("yenileme tamamlandı") })
    }

    func testRotationFailureKeepsOldKeyWorking() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        let before = try await add(model, sshd)

        sshd.stop()   // server goes away mid-schedule
        let ok = await model.rotate(before.id, automatic: true)
        XCTAssertFalse(ok)

        let after = try XCTUnwrap(model.server(before.id))
        XCTAssertEqual(after.keyFileName, before.keyFileName, "old key must remain the active one")
        XCTAssertEqual(after.publicKeyBlob, before.publicKeyBlob)
        XCTAssertNotNil(after.lastRotationFailureAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.paths.keyURL(before.keyFileName).path))

        // no leftover half-created key files
        let keyFiles = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path)
            .filter { !$0.hasSuffix(".pub") && !$0.hasPrefix(sshd.bootstrapKeyName) }
        XCTAssertEqual(keyFiles, [before.keyFileName])
        XCTAssertTrue(after.events.contains { $0.level == .error && $0.message.contains("Otomatik") })

        // and it backs off: not due again immediately
        var due = after
        due.lastRotatedAt = Date(timeIntervalSinceNow: -90 * 86400)
        XCTAssertFalse(due.isRotationDue())
    }

    func testRemoveServerCleansServerAndLocalState() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        let s = try await add(model, sshd)

        try await model.removeServer(s.id, removeRemoteKey: true)

        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertEqual(sshd.authorizedKeyLines.count, 1, "only the bootstrap key remains on the server")
        XCTAssertFalse(sshd.authorizedKeyLines.contains { $0.contains(s.publicKeyBlob) })
        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        XCTAssertFalse(cfg.contains("Host testbox"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.keyURL(s.keyFileName).path))
        let known = (try? String(contentsOf: box.paths.knownHosts, encoding: .utf8)) ?? ""
        XCTAssertFalse(known.contains("127.0.0.1"), "host entry forgotten when no other server uses it")
    }

    func testRemoveFailureDeletesNothing() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        let s = try await add(model, sshd)

        sshd.stop()
        do {
            try await model.removeServer(s.id, removeRemoteKey: true)
            XCTFail("should fail when the server cannot be reached")
        } catch let e as DeckError {
            if case .remoteRemovalFailed = e {} else { XCTFail("wrong error \(e)") }
        }
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.paths.keyURL(s.keyFileName).path))

        // explicit local-only removal still works
        try await model.removeServer(s.id, removeRemoteKey: false)
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.keyURL(s.keyFileName).path))
    }

    func testAddRollsBackWhenKeyLoginCannotBeVerified() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        // Install the key somewhere sshd does not read, so verification must fail.
        let decoy = sshd.dir.appendingPathComponent("decoy_authorized_keys")
        let model = makeModel(box, sshd, authorizedKeysPath: decoy.path)

        // the decoy install uses the bootstrap key to log in, which sshd accepts from its real file
        let (d, hostKeys) = try await model.scanHostKeys(for: draft(sshd))
        do {
            _ = try await model.addServer(draft: d, password: "unused", hostKeys: hostKeys)
            XCTFail("verification should have failed")
        } catch let e as DeckError {
            XCTAssertTrue(e.localizedDescription.contains("doğrulanamadı"), e.localizedDescription)
        }

        XCTAssertTrue(model.servers.isEmpty)
        let decoyText = (try? String(contentsOf: decoy, encoding: .utf8)) ?? ""
        XCTAssertTrue(decoyText.trimmed.isEmpty, "installed key must be taken back off the server, got: \(decoyText)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path)
            .filter { !$0.hasPrefix(sshd.bootstrapKeyName) }
        XCTAssertTrue(leftovers.isEmpty, "no local key files left behind: \(leftovers)")
    }

    func testStatusAndLoginHistory() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = makeModel(box, sshd)
        let s = try await add(model, sshd)

        await model.checkStatus(s.id)
        XCTAssertEqual(model.server(s.id)?.lastReachable, true)
        XCTAssertNotNil(model.server(s.id)?.lastCheckedAt)

        _ = try await model.loginHistory(s.id)   // must not throw; content depends on the OS

        sshd.stop()
        await model.checkStatus(s.id)
        XCTAssertEqual(model.server(s.id)?.lastReachable, false)
        XCTAssertTrue(model.server(s.id)?.events.contains { $0.level == .warning } ?? false)
    }

    func testAuthorizedKeysWithoutTrailingNewlineIsNotCorrupted() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        // strip the trailing newline from the bootstrap line
        let text = try String(contentsOf: sshd.authorizedKeys, encoding: .utf8).trimmed
        try text.write(to: sshd.authorizedKeys, atomically: true, encoding: .utf8)

        let model = makeModel(box, sshd)
        let s = try await add(model, sshd)
        let lines = sshd.authorizedKeyLines
        XCTAssertEqual(lines.count, 2, "keys must be on separate lines: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains(s.publicKeyBlob) })
    }

    func testRemoveKeyRefusesToEmptyAuthorizedKeysUnlessAllowed() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let remote = RemoteService(paths: box.paths, useKeychain: false, authorizedKeysPath: sshd.authorizedKeys.path)
        let model = makeModel(box, sshd)
        let (_, hostKeys) = try await model.scanHostKeys(for: draft(sshd))
        try await HostKeyService(paths: box.paths).trust(hostKeys, host: "127.0.0.1", port: sshd.port)

        // The file holds only the bootstrap key, which is also the key we authenticate with.
        let bootstrapBlob = try XCTUnwrap(sshd.authorizedKeyLines.first?.split(separator: " ").dropFirst().first.map(String.init))
        let before = try String(contentsOf: sshd.authorizedKeys, encoding: .utf8)

        do {
            try await remote.removeKey(target: sshd.target, auth: .key(fileName: sshd.bootstrapKeyName), blob: bootstrapBlob)
            XCTFail("must refuse to leave authorized_keys empty")
        } catch {}
        XCTAssertEqual(try String(contentsOf: sshd.authorizedKeys, encoding: .utf8), before, "file must be untouched")

        try await remote.removeKey(target: sshd.target, auth: .key(fileName: sshd.bootstrapKeyName), blob: bootstrapBlob, allowEmpty: true)
        XCTAssertTrue(try String(contentsOf: sshd.authorizedKeys, encoding: .utf8).trimmed.isEmpty)
    }

    /// Proves the password path reaches the server's password prompt through SSH_ASKPASS
    /// (a non-root sshd then rejects it, which is the expected outcome here).
    func testPasswordIsOfferedThroughAskpass() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box, allowPasswordAuth: true)
        let model = makeModel(box, sshd)
        let (_, hostKeys) = try await model.scanHostKeys(for: draft(sshd))
        try await HostKeyService(paths: box.paths).trust(hostKeys, host: "127.0.0.1", port: sshd.port)

        let remote = RemoteService(paths: box.paths, useKeychain: false, authorizedKeysPath: sshd.authorizedKeys.path)
        do {
            try await remote.installKey(target: sshd.target, auth: .password("definitely-wrong"), publicKeyLine: "ssh-ed25519 AAAA test")
            XCTFail("a wrong password must not succeed")
        } catch let e as DeckError {
            XCTAssertTrue(e.localizedDescription.contains("şifre"), "expected the password-rejected message, got: \(e.localizedDescription)")
        }
    }
}
