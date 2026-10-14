import XCTest
@testable import SigilCore

final class ValidationTests: XCTestCase {
    func testAcceptsNormalValues() throws {
        XCTAssertEqual(try Validation.alias("webserver"), "webserver")
        XCTAssertEqual(try Validation.alias("web-01.prod"), "web-01.prod")
        XCTAssertEqual(try Validation.host("203.0.113.7"), "203.0.113.7")
        XCTAssertEqual(try Validation.host("sunucum.example.com"), "sunucum.example.com")
        XCTAssertEqual(try Validation.host("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(try Validation.user("root"), "root")
        XCTAssertEqual(try Validation.user("deploy_user-1"), "deploy_user-1")
        XCTAssertEqual(try Validation.port(22), 22)
    }

    func testRejectsInjection() {
        // option injection
        XCTAssertThrowsError(try Validation.host("-oProxyCommand=touch /tmp/pwned"))
        XCTAssertThrowsError(try Validation.host("-o"))
        XCTAssertThrowsError(try Validation.user("-oProxyCommand=x"))
        // ssh_config injection through newline / whitespace
        XCTAssertThrowsError(try Validation.alias("x\nProxyCommand evil"))
        XCTAssertThrowsError(try Validation.alias("a b"))
        XCTAssertThrowsError(try Validation.host("1.2.3.4\nHost *"))
        XCTAssertThrowsError(try Validation.host("host name"))
        XCTAssertThrowsError(try Validation.user("root;id"))
        XCTAssertThrowsError(try Validation.alias(""))
        XCTAssertThrowsError(try Validation.port(0))
        XCTAssertThrowsError(try Validation.port(70000))
        XCTAssertThrowsError(try Validation.keyBlob("AAAA'; rm -rf ~; '"))
    }
}

final class ConfigManagerTests: XCTestCase {
    func sample(_ alias: String, file: String = "k1") -> Server {
        Server(alias: alias, host: "10.0.0.5", port: 2222, user: "deploy", keyFileName: file,
               publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIabc", keyFingerprint: "SHA256:x")
    }

    func testRenderContainsExpectedDirectives() throws {
        let box = try Sandbox()
        let text = ConfigManager(paths: box.paths).render([sample("alpha")])
        XCTAssertTrue(text.contains("Host alpha"))
        XCTAssertTrue(text.contains("HostName 10.0.0.5"))
        XCTAssertTrue(text.contains("User deploy"))
        XCTAssertTrue(text.contains("Port 2222"))
        XCTAssertTrue(text.contains("IdentityFile \(box.paths.keyURL("k1").path)"))
        XCTAssertTrue(text.contains("IdentitiesOnly yes"))
        XCTAssertTrue(text.contains("UseKeychain yes"))
    }

    func testEnsureIncludeIsIdempotentAndPreservesExistingConfigWithBackup() throws {
        let box = try Sandbox()
        let original = "Host webserver\n  HostName 203.0.113.7\n  User root\n"
        try original.write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)
        let cm = ConfigManager(paths: box.paths)

        XCTAssertTrue(try cm.ensureInclude())
        XCTAssertFalse(try cm.ensureInclude(), "second call must not change anything")
        XCTAssertFalse(try cm.ensureInclude())

        let after = try String(contentsOf: box.paths.mainConfig, encoding: .utf8)
        XCTAssertEqual(after.components(separatedBy: "Include").count - 1, 1, "exactly one Include line")
        XCTAssertTrue(after.hasSuffix(original), "user's own entries are untouched, still at the end")
        XCTAssertTrue(after.range(of: "Include")!.lowerBound < after.range(of: "Host webserver")!.lowerBound,
                      "Include must precede Host blocks so it applies globally")

        let backups = try FileManager.default.contentsOfDirectory(atPath: box.paths.sshDir.path)
            .filter { $0.hasPrefix("config.sigil-backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try String(contentsOf: box.paths.sshDir.appendingPathComponent(backups[0]), encoding: .utf8)
        XCTAssertEqual(backup, original)

        let attrs = try FileManager.default.attributesOfItem(atPath: box.paths.mainConfig.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEnsureIncludeCreatesConfigWhenMissing() throws {
        let box = try Sandbox()
        let cm = ConfigManager(paths: box.paths)
        XCTAssertTrue(try cm.ensureInclude())
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.paths.includeFile.path))
        let text = try String(contentsOf: box.paths.mainConfig, encoding: .utf8)
        XCTAssertTrue(text.contains("Include"))
    }

    func testDetectsAliasAlreadyDefinedByUser() throws {
        let box = try Sandbox()
        try "Host webserver other\n  HostName x\nHost *\n  ServerAliveInterval 5\n"
            .write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)
        let cm = ConfigManager(paths: box.paths)
        XCTAssertThrowsError(try cm.ensureAliasAvailable("webserver"))
        XCTAssertThrowsError(try cm.ensureAliasAvailable("WebServer"))
        XCTAssertThrowsError(try cm.ensureAliasAvailable("other"))
        XCTAssertNoThrow(try cm.ensureAliasAvailable("fresh"))
    }
}

final class StoreTests: XCTestCase {
    func testRoundTripAndPermissions() throws {
        let box = try Sandbox()
        let store = ServerStore(paths: box.paths)
        var s = Server(alias: "a", host: "h", port: 22, user: "u", keyFileName: "k", publicKeyBlob: "B", keyFingerprint: "F")
        s.events.append(ServerEvent(level: .warning, message: "hello"))
        try store.save([s])
        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.servers.count, 1)
        XCTAssertEqual(loaded.servers[0].alias, "a")
        XCTAssertEqual(loaded.servers[0].events.first?.message, "hello")
        let attrs = try FileManager.default.attributesOfItem(atPath: box.paths.storeFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        let box = try Sandbox()
        try "{ not json".write(to: box.paths.storeFile, atomically: true, encoding: .utf8)
        let loaded = ServerStore(paths: box.paths).load()
        XCTAssertTrue(loaded.servers.isEmpty)
        XCTAssertNotNil(loaded.warning)
        let files = try FileManager.default.contentsOfDirectory(atPath: box.paths.supportDir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("servers.json.corrupt-") })
    }

    func testRotationDueLogic() {
        var s = Server(alias: "a", host: "h", port: 22, user: "u", keyFileName: "k", publicKeyBlob: "B", keyFingerprint: "F",
                       lastRotatedAt: Date(timeIntervalSinceNow: -40 * 86400), rotationIntervalDays: 30)
        XCTAssertTrue(s.isRotationDue())
        s.lastRotationFailureAt = Date(timeIntervalSinceNow: -3600)
        XCTAssertFalse(s.isRotationDue(), "recent failure backs off")
        s.lastRotationFailureAt = Date(timeIntervalSinceNow: -7 * 3600)
        XCTAssertTrue(s.isRotationDue())
        s.rotationIntervalDays = 0
        XCTAssertFalse(s.isRotationDue(), "0 = off")
        s.rotationIntervalDays = 90
        XCTAssertFalse(s.isRotationDue())
    }
}

final class KeyTests: XCTestCase {
    func testGeneratedKeyAndFingerprintMatchOpenSSH() async throws {
        let box = try Sandbox()
        let ks = KeyService(paths: box.paths, protectWithKeychain: false)
        let m = try await ks.generate(fileName: "t_ed25519", comment: "sigil:test")
        XCTAssertTrue(m.publicKeyLine.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(m.fingerprint.hasPrefix("SHA256:"))

        let out = try LocalSSHD.run("/usr/bin/ssh-keygen", ["-lf", box.paths.keyURL("t_ed25519").appendingPathExtension("pub").path])
        XCTAssertTrue(out.contains(m.fingerprint), "our SHA256 must equal ssh-keygen's: \(out) vs \(m.fingerprint)")

        let attrs = try FileManager.default.attributesOfItem(atPath: box.paths.keyURL("t_ed25519").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        await ks.delete(fileName: "t_ed25519")
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.keyURL("t_ed25519").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.keyURL("t_ed25519").appendingPathExtension("pub").path))
    }

    func testDoesNotOverwriteExistingKey() async throws {
        let box = try Sandbox()
        let ks = KeyService(paths: box.paths, protectWithKeychain: false)
        _ = try await ks.generate(fileName: "dup", comment: "c")
        do {
            _ = try await ks.generate(fileName: "dup", comment: "c")
            XCTFail("should refuse to overwrite")
        } catch {}
    }

    /// The passphrase must reach ssh-keygen through SSH_ASKPASS (never argv) and really encrypt the key.
    func testAskpassSetsPassphraseWithoutCommandLine() async throws {
        let box = try Sandbox()
        let key = box.paths.keyURL("enc_ed25519")
        let secret = "correct-horse-battery-staple-1234"
        let gen = try await Askpass.withSecret(secret) { env in
            try await Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-a", "16", "-C", "t", "-f", key.path], environment: env)
        }
        XCTAssertTrue(gen.succeeded, gen.stderr)

        let wrong = try await Shell.run("/usr/bin/ssh-keygen", ["-y", "-P", "wrong", "-f", key.path])
        XCTAssertFalse(wrong.succeeded, "key must be encrypted")
        let right = try await Shell.run("/usr/bin/ssh-keygen", ["-y", "-P", secret, "-f", key.path])
        XCTAssertTrue(right.succeeded, right.stderr)
    }

    func testAskpassScriptIsCleanedUp() async throws {
        var scriptPath = ""
        try await Askpass.withSecret("x") { env in
            scriptPath = env["SSH_ASKPASS"]!
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptPath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptPath))
    }

    func testRandomPassphraseIsLongAndUnique() {
        let a = Askpass.randomPassphrase(), b = Askpass.randomPassphrase()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }
}

final class HostKeyTests: XCTestCase {
    func testParseKeyscanLine() throws {
        let box = try Sandbox()
        let ks = KeyService(paths: box.paths, protectWithKeychain: false)
        let m = try awaitSync { try await ks.generate(fileName: "hk", comment: "c") }
        let line = "203.0.113.9 ssh-ed25519 \(m.blob)"
        let k = try XCTUnwrap(HostKeyService.parse(line))
        XCTAssertEqual(k.algorithm, "ssh-ed25519")
        XCTAssertEqual(k.fingerprint, m.fingerprint)
    }

    func testTrustAddsOnceAndRefusesChangedKey() async throws {
        let box = try Sandbox()
        let ks = KeyService(paths: box.paths, protectWithKeychain: false)
        let a = try await ks.generate(fileName: "a", comment: "c")
        let b = try await ks.generate(fileName: "b", comment: "c")
        let svc = HostKeyService(paths: box.paths)

        let keyA = try XCTUnwrap(HostKeyService.parse("198.51.100.7 ssh-ed25519 \(a.blob)"))
        let keyB = try XCTUnwrap(HostKeyService.parse("198.51.100.7 ssh-ed25519 \(b.blob)"))

        try await svc.trust([keyA], host: "198.51.100.7", port: 22)
        try await svc.trust([keyA], host: "198.51.100.7", port: 22)   // idempotent
        let text = try String(contentsOf: box.paths.knownHosts, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "ssh-ed25519").count - 1, 1)

        do {
            try await svc.trust([keyB], host: "198.51.100.7", port: 22)
            XCTFail("a different key for a known host must be refused")
        } catch let e as DeckError {
            if case .hostKeyChanged = e {} else { XCTFail("wrong error \(e)") }
        }
        let after = try String(contentsOf: box.paths.knownHosts, encoding: .utf8)
        XCTAssertFalse(after.contains(b.blob), "the mismatching key must not have been written")

        let attrs = try FileManager.default.attributesOfItem(atPath: box.paths.knownHosts.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

/// Runs an async throwing closure to completion from a sync test.
func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let exp = XCTestExpectation(description: "awaitSync")
    var result: Result<T, Error>?
    Task {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        exp.fulfill()
    }
    XCTWaiter().wait(for: [exp], timeout: 60)
    return try XCTUnwrap(result).get()
}

@MainActor
final class MetadataTests: XCTestCase {
    func testGroupsEnvironmentAndRenamePersistAndRewriteConfig() throws {
        let box = try Sandbox()
        var s = Server(alias: "alpha", host: "10.0.0.1", port: 22, user: "u", keyFileName: "k", publicKeyBlob: "B", keyFingerprint: "F")
        s.group = nil
        try ServerStore(paths: box.paths).save([s])
        let model = DeckModel(paths: box.paths, hardened: false)
        model.load()

        model.setGroup(s.id, "  Müşteri A ")
        model.setEnvironment(s.id, .production)
        XCTAssertEqual(model.groups, ["Müşteri A"])
        XCTAssertTrue(model.server(s.id)!.isProduction)

        try model.rename(s.id, to: "alpha-prod")
        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        XCTAssertTrue(cfg.contains("Host alpha-prod"))
        XCTAssertFalse(cfg.contains("Host alpha\n"))

        XCTAssertThrowsError(try model.rename(s.id, to: "bad alias"))

        let reloaded = DeckModel(paths: box.paths, hardened: false)
        reloaded.load()
        XCTAssertEqual(reloaded.servers.first?.alias, "alpha-prod")
        XCTAssertEqual(reloaded.servers.first?.group, "Müşteri A")
        XCTAssertEqual(reloaded.servers.first?.environment, .production)

        model.setGroup(s.id, "   ")
        XCTAssertNil(model.server(s.id)!.group)
    }
}
