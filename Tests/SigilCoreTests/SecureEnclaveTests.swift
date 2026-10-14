import CryptoKit
import XCTest
@testable import SigilCore

final class SecureEnclaveKeyHandleTests: XCTestCase {
    /// The handle file Sigil writes must be one OpenSSH reads as the same sk-ecdsa key it advertises.
    func testKeyHandleFileIsAValidOpenSSHSecurityKey() async throws {
        let box = try Sandbox()
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let handle = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let file = SecureEnclaveService.keyHandleFile(point: point, keyHandle: handle, comment: "sigil:web")

        let url = box.root.appendingPathComponent("handle")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(file.privateText.utf8),
                                                     attributes: [.posixPermissions: 0o600]))

        let derived = try await Shell.run("/usr/bin/ssh-keygen", ["-y", "-f", url.path])
        XCTAssertTrue(derived.succeeded, derived.stderr)
        let fields = file.publicLine.split(separator: " ")
        XCTAssertEqual(fields.first, "sk-ecdsa-sha2-nistp256@openssh.com")
        XCTAssertEqual(derived.stdout.split(separator: " ").prefix(2), fields.prefix(2))

        let listed = try await Shell.run("/usr/bin/ssh-keygen", ["-l", "-f", url.path])
        XCTAssertTrue(listed.succeeded, listed.stderr)
        XCTAssertTrue(listed.stdout.contains("ECDSA-SK"), listed.stdout)
        XCTAssertTrue(listed.stdout.contains(Fingerprint.sha256(ofBase64: String(fields[1]))!), listed.stdout)
    }

    func testKeyHandleFileCarriesTheIdentityHashUnencrypted() throws {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let handle = Data(repeating: 0xAB, count: 20)
        let text = SecureEnclaveService.keyHandleFile(point: point, keyHandle: handle, comment: "c", checkInt: 7).privateText
        let b64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let body = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertNotNil(body.range(of: Data("none".utf8)), "unencrypted container")
        XCTAssertNotNil(body.range(of: handle), "the key handle is the identity's public-key hash")
    }

    func testConfigUsesApplesProviderAndNoAgent() throws {
        let box = try Sandbox()
        var s = Server(alias: "enclave", host: "203.0.113.7", port: 22, user: "deploy", keyFileName: "k1",
                       publicKeyBlob: "AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAA", keyFingerprint: "SHA256:x")
        s.keyStore = .secureEnclave
        let text = ConfigManager(paths: box.paths).render([s])
        XCTAssertTrue(text.contains("IdentityFile \(box.paths.keyURL("k1").path)\n"))
        XCTAssertTrue(text.contains("SecurityKeyProvider /usr/lib/ssh-keychain.dylib"))
        XCTAssertTrue(text.contains("IdentityAgent none"))
        XCTAssertTrue(text.contains("IdentitiesOnly yes"))
        XCTAssertFalse(text.contains("UseKeychain"))
    }

    func testSSHArgumentsForSecurityKey() throws {
        let box = try Sandbox()
        let args = RemoteService(paths: box.paths).arguments(
            for: RemoteTarget(host: "203.0.113.7", port: 22, user: "deploy"), auth: .securityKey(fileName: "k1"), command: "true")
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("-i \(box.paths.keyURL("k1").path)"))
        XCTAssertTrue(joined.contains("SecurityKeyProvider=/usr/lib/ssh-keychain.dylib"))
        XCTAssertTrue(joined.contains("IdentityAgent=none"))
        XCTAssertTrue(joined.contains("BatchMode=yes"))
        XCTAssertTrue(joined.contains("PasswordAuthentication=no"))
    }

    func testRotationIsForcedBeforeTheIdentityCertificateLapses() {
        var s = Server(alias: "a", host: "203.0.113.7", port: 22, user: "u", keyFileName: "k",
                       publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIabc", keyFingerprint: "SHA256:x",
                       lastRotatedAt: Date(timeIntervalSinceNow: -340 * 86400), rotationIntervalDays: 0)
        XCTAssertNil(s.nextRotation, "keychain: rotation off means never")
        s.keyStore = .secureEnclave
        XCTAssertTrue(s.isRotationDue(), "Secure Enclave: due within a year even with rotation off")
        s.rotationIntervalDays = 30
        s.lastRotatedAt = Date(timeIntervalSinceNow: -10 * 86400)
        XCTAssertFalse(s.isRotationDue())
    }

    func testDecodesStoreKind() throws {
        let kind = try JSONDecoder().decode(KeyStoreKind.self, from: Data(#""secureEnclave""#.utf8))
        XCTAssertEqual(kind, .secureEnclave)
        XCTAssertTrue(kind.asksForApproval)
        XCTAssertFalse(KeyStoreKind.keychain.asksForApproval)
    }
}

/// Secure Enclave servers are never contacted unless the user asks: no reachability checks, audits, health or rotation.
@MainActor
final class SecureEnclaveBackgroundTests: XCTestCase {
    private func model(_ box: Sandbox, _ servers: [Server]) throws -> DeckModel {
        try ServerStore(paths: box.paths).save(servers)
        let m = DeckModel(paths: box.paths, hardened: false)
        m.load()
        return m
    }

    private func server(_ alias: String, _ store: KeyStoreKind, overdue: Bool = false, jump: UUID? = nil) -> Server {
        var s = Server(alias: alias, host: "203.0.113.7", port: 22, user: "u", keyFileName: "k-\(alias)",
                       publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAI\(alias)", keyFingerprint: "SHA256:x",
                       lastRotatedAt: Date(timeIntervalSinceNow: overdue ? -60 * 86400 : 0))
        s.keyStore = store
        s.jumpServerID = jump
        return s
    }

    func testNothingRunsInTheBackground() async throws {
        let box = try Sandbox()
        let enclave = server("enclave", .secureEnclave, overdue: true)
        let behind = server("behind", .keychain, jump: enclave.id)
        let m = try model(box, [enclave, behind])
        var notes: [String] = []
        m.notify = { title, _ in notes.append(title) }

        XCTAssertTrue(m.backgroundOff(m.server(enclave.id)!))
        XCTAssertTrue(m.backgroundOff(m.server(behind.id)!), "a server reached through it would need its Touch ID too")
        XCTAssertFalse(m.runsUnattended(m.server(behind.id)!))

        await m.checkAll()
        await m.rotateDueServers()
        await m.auditDueServers()
        await m.collectDueHealth()
        let none = try await m.collectHealth(enclave.id, interactive: false)
        let fresh = try await m.audit(enclave.id, interactive: false)

        XCTAssertNil(none)
        XCTAssertEqual(fresh, 0)
        for id in [enclave.id, behind.id] {
            let s = try XCTUnwrap(m.server(id))
            XCTAssertNil(s.lastCheckedAt, "never contacted")
            XCTAssertNil(s.lastAuditAt)
            XCTAssertNil(s.health)
        }
        XCTAssertEqual(m.server(enclave.id)?.publicKeyBlob, enclave.publicKeyBlob, "not rotated unattended")
        XCTAssertTrue(notes.isEmpty, "no notifications either")
        XCTAssertEqual(m.awaitingManualRotation.map(\.id), [enclave.id], "shown as due in the app")
    }
}

/// Real Secure Enclave, real Touch ID: run by hand with `SIGIL_SE_E2E=1 swift test --filter SecureEnclaveEndToEnd`.
/// Expect about five Touch ID prompts (add, ssh, rotate ×3).
@MainActor
final class SecureEnclaveEndToEndTests: XCTestCase {
    func testAddConnectRotateRemove() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_SE_E2E"] == "1", "needs Touch ID; opt-in")
        try XCTSkipUnless(SecureEnclaveService.isSupported, "macOS 26+")
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)

        let draft = ServerDraft(alias: "enclave", host: "127.0.0.1", port: sshd.port, user: NSUserName(), keyStore: .secureEnclave)
        let (d, hostKeys) = try await model.scanHostKeys(for: draft)
        let s = try await model.addServer(draft: d, password: "unused", hostKeys: hostKeys)
        let hash = try XCTUnwrap(s.secureEnclaveKeyHash)
        XCTAssertTrue(try String(contentsOf: sshd.authorizedKeys, encoding: .utf8).contains(s.publicKeyBlob))

        // The plain `ssh <alias>` path the user's terminal takes.
        let r = try await Shell.run("/usr/bin/ssh", [
            "-F", box.paths.mainConfig.path, "-o", "UserKnownHostsFile=\(box.paths.knownHosts.path)",
            "-o", "BatchMode=yes", "enclave", "echo alias-works",
        ], timeout: 120)
        XCTAssertTrue(r.stdout.contains("alias-works"), r.stderr)

        let rotated = await model.rotate(s.id)
        XCTAssertTrue(rotated)
        let after = try XCTUnwrap(model.server(s.id))
        XCTAssertNotEqual(after.secureEnclaveKeyHash, hash)
        let keys = try String(contentsOf: sshd.authorizedKeys, encoding: .utf8)
        XCTAssertFalse(keys.contains(s.publicKeyBlob), "old key removed from the server")
        XCTAssertTrue(keys.contains(after.publicKeyBlob))
        let identities = try await Shell.run("/usr/sbin/sc_auth", ["list-ctk-identities"])
        XCTAssertFalse(identities.stdout.contains(hash), "old identity deleted from the Secure Enclave")

        try await model.removeServer(s.id, removeRemoteKey: false)
        let left = try await Shell.run("/usr/sbin/sc_auth", ["list-ctk-identities"])
        XCTAssertFalse(left.stdout.contains(after.secureEnclaveKeyHash ?? "-"))
    }
}
