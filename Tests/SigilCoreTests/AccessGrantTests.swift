import XCTest
@testable import SigilCore

final class GuestKeyTests: XCTestCase {
    private func generatedPublicKey(_ box: Sandbox, name: String = "friend") async throws -> (line: String, file: URL) {
        let file = box.root.appendingPathComponent(name)
        let r = try await Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "ali@laptop", "-f", file.path])
        XCTAssertTrue(r.succeeded, r.stderr)
        return (try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8), file)
    }

    func testParsesAPublicKeyLine() async throws {
        let box = try Sandbox()
        let (line, _) = try await generatedPublicKey(box)
        let k = try GuestKey.parse("  \(line)\n")
        XCTAssertEqual(k.type, "ssh-ed25519")
        XCTAssertEqual(k.comment, "ali@laptop")
        XCTAssertTrue(k.fingerprint.hasPrefix("SHA256:"))
    }

    func testRefusesPrivateKeysAndJunk() async throws {
        let box = try Sandbox()
        let (_, file) = try await generatedPublicKey(box)
        let privateKey = try String(contentsOf: file, encoding: .utf8)
        XCTAssertThrowsError(try GuestKey.parse(privateKey)) { e in
            XCTAssertTrue(e.localizedDescription.contains("GİZLİ"))
        }
        XCTAssertThrowsError(try GuestKey.parse("hello world"))
        XCTAssertThrowsError(try GuestKey.parse("command=\"rm -rf /\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc x"), "options are ours to set")
        // Label says rsa, blob says ed25519.
        let (line, _) = try await generatedPublicKey(box, name: "other")
        XCTAssertThrowsError(try GuestKey.parse(line.replacingOccurrences(of: "ssh-ed25519", with: "ssh-rsa")))
    }

    func testKeyLineCarriesTheLimits() throws {
        let key = GuestKey(type: "ssh-ed25519", blob: "AAAAC3NzaC1lZDI1NTE5AAAAIabc", comment: "")
        let expiry = ISO8601DateFormatter().date(from: "2026-11-15T09:30:00Z")!
        let line = try GrantScript.keyLine(GrantRequest(name: "Ali Çelik", key: key, expiresAt: expiry,
                                                        fromAddresses: ["203.0.113.7", "198.51.100.0/24"]))
        XCTAssertEqual(line, #"expiry-time="202611150930Z",from="203.0.113.7,198.51.100.0/24",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc sigil-guest:ali-celik"#)
        XCTAssertThrowsError(try GrantScript.keyLine(GrantRequest(name: "x", key: key, fromAddresses: ["1.2.3.4\" ,command=\"x"])))
        XCTAssertThrowsError(try GrantScript.account("Root; rm"))
        XCTAssertEqual(try GrantScript.account("ali"), "ali")
    }

    func testRemoteScriptsAreValidShell() async throws {
        let line = #"no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc sigil-guest:ali"#
        for script in [GrantScript.add(account: "ali", line: line, sudo: true), GrantScript.add(account: "ali", line: line, sudo: false),
                       GrantScript.remove(account: "ali", blob: "AAAAC3NzaC1lZDI1NTE5AAAAIabc", removeAccount: true)] {
            let r = try await Shell.run("/bin/sh", ["-n", "-c", script])
            XCTAssertTrue(r.succeeded, "\(r.stderr)\n\(script)")
        }
    }
}

/// End to end against a throw-away sshd: a friend's key gets in, is not reported as foreign, and is out again after
/// revoking; an expired grant is refused by sshd itself.
@MainActor
final class AccessGrantIntegrationTests: XCTestCase {
    private func setUp() async throws -> (Sandbox, LocalSSHD, DeckModel, Server) {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let draft = ServerDraft(alias: "shared", host: "127.0.0.1", port: sshd.port, user: NSUserName(), keyStore: .keychain)
        let (d, keys) = try await model.scanHostKeys(for: draft)
        let s = try await model.addServer(draft: d, password: "unused", hostKeys: keys)
        return (box, sshd, model, s)
    }

    private func friend(_ box: Sandbox, _ name: String) async throws -> (key: GuestKey, file: URL) {
        let file = box.root.appendingPathComponent(name)
        _ = try await Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", file.path])
        return (try GuestKey.parse(String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)), file)
    }

    private func friendCanLogIn(_ sshd: LocalSSHD, _ file: URL) async throws -> Bool {
        let r = try await Shell.run("/usr/bin/ssh", [
            "-F", "/dev/null", "-p", String(sshd.port), "-i", file.path,
            "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "\(NSUserName())@127.0.0.1", "echo friend-in",
        ], timeout: 30)
        return r.stdout.contains("friend-in")
    }

    func testGrantLetsTheFriendInAndRevokeTakesItBack() async throws {
        let (box, sshd, model, s) = try await setUp()
        let (key, file) = try await friend(box, "ali")
        let can0 = try await friendCanLogIn(sshd, file)
        XCTAssertFalse(can0)

        let grant = try await model.grantAccess(s.id, GrantRequest(name: "Ali", key: key, expiresAt: Date(timeIntervalSinceNow: 86400)))
        XCTAssertEqual(grant.account, NSUserName())
        let can1 = try await friendCanLogIn(sshd, file)
        XCTAssertTrue(can1, "the friend's own key opens the server")
        let line = try String(contentsOf: sshd.authorizedKeys, encoding: .utf8)
        XCTAssertTrue(line.contains("expiry-time=") && line.contains("sigil-guest:ali") && line.contains("no-port-forwarding"))

        _ = try await model.audit(s.id)
        let foreign = model.server(s.id)?.foreignKeys?.map(\.blob) ?? []
        XCTAssertFalse(foreign.contains(key.blob), "a granted key is not a foreign key (the test's bootstrap key is)")

        try await model.revokeAccess(s.id, grantID: grant.id)
        let can2 = try await friendCanLogIn(sshd, file)
        XCTAssertFalse(can2)
        XCTAssertEqual(model.server(s.id)?.grants ?? [], [])
        let ping = try await model.remote.ping(target: model.target(for: s), auth: .key(fileName: s.keyFileName))
        XCTAssertGreaterThanOrEqual(ping, 0, "Sigil's own key still works")
    }

    func testExpiredGrantIsRefusedBySSHDItself() async throws {
        let (box, sshd, model, s) = try await setUp()
        let (key, file) = try await friend(box, "veli")
        // Grant for a minute, then wind the clock on the line back so it has already lapsed.
        _ = try await model.grantAccess(s.id, GrantRequest(name: "Veli", key: key, expiresAt: Date(timeIntervalSinceNow: 60)))
        var text = try String(contentsOf: sshd.authorizedKeys, encoding: .utf8)
        text = text.replacingOccurrences(of: #"expiry-time="\d{12}Z""#, with: #"expiry-time="200001010000Z""#, options: .regularExpression)
        try text.write(to: sshd.authorizedKeys, atomically: true, encoding: .utf8)
        let can = try await friendCanLogIn(sshd, file)
        XCTAssertFalse(can, "sshd enforces expiry-time")
    }

    func testRefusesSigilsOwnKeyAndPastExpiry() async throws {
        let (box, sshd, model, s) = try await setUp(); _ = (box, sshd)
        let own = GuestKey(type: "ssh-ed25519", blob: s.publicKeyBlob, comment: "")
        do { _ = try await model.grantAccess(s.id, GrantRequest(name: "x", key: own)); XCTFail() } catch {}
        let (key, _) = try await friend(box, "eski")
        do { _ = try await model.grantAccess(s.id, GrantRequest(name: "x", key: key, expiresAt: Date(timeIntervalSinceNow: -60))); XCTFail() } catch {}
    }
}
