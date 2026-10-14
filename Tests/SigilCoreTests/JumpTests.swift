import XCTest
@testable import SigilCore

@MainActor
final class JumpHostTests: XCTestCase {
    func testServerBehindJumpHostIsAddedReachedAndProtected() async throws {
        let box = try Sandbox()
        let bastion = try LocalSSHD(sandbox: box, name: "bastion", bootstrapKeyName: "bootstrap-a")
        let inner = try LocalSSHD(sandbox: box, name: "inner", bootstrapKeyName: "bootstrap-b")
        // Both test servers share the same authorized_keys path setting, so point the model at each in turn.
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: bastion.authorizedKeys.path)

        model.initialAuthOverride = .key(fileName: bastion.bootstrapKeyName)
        let (dj, kj) = try await model.scanHostKeys(for: ServerDraft(alias: "bastion", host: "127.0.0.1", port: bastion.port, user: NSUserName()))
        let jump = try await model.addServer(draft: dj, password: "x", hostKeys: kj)

        // The inner server's key goes to its own authorized_keys file.
        let innerModel = model
        _ = innerModel
        let model2 = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: inner.authorizedKeys.path)
        model2.load()
        model2.initialAuthOverride = .key(fileName: inner.bootstrapKeyName)
        let draft = ServerDraft(alias: "inner", host: "127.0.0.1", port: inner.port, user: NSUserName(), jumpServerID: jump.id)
        let (di, ki) = try await model2.scanHostKeys(for: draft)
        XCTAssertFalse(ki.isEmpty, "host keys scanned through the jump server")
        let s = try await model2.addServer(draft: di, password: "x", hostKeys: ki)
        XCTAssertEqual(s.jumpServerID, jump.id)
        XCTAssertTrue(model2.target(for: s).proxyCommand?.contains("-W") ?? false)

        await model2.checkStatus(s.id)
        XCTAssertEqual(model2.server(s.id)?.lastReachable, true)

        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        XCTAssertTrue(cfg.contains("ProxyJump bastion"))
        // The ProxyJump child ssh reads known_hosts from config, not from our -o; point the test config at the sandbox.
        let main = try String(contentsOf: box.paths.mainConfig, encoding: .utf8)
        try (main + "\nHost *\n  UserKnownHostsFile \(box.paths.knownHosts.path)\n").write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)
        let r = try await Shell.run("/usr/bin/ssh", [
            "-F", box.paths.mainConfig.path, "-o", "UserKnownHostsFile=\(box.paths.knownHosts.path)",
            "-o", "BatchMode=yes", "inner", "echo through-the-bastion",
        ])
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(r.stdout.contains("through-the-bastion"))

        // The bastion can't be deleted while something depends on it.
        do { try await model2.removeServer(jump.id, removeRemoteKey: false); XCTFail("must refuse") } catch {}
        XCTAssertThrowsError(try model2.setJump(jump.id, s.id), "no chains")
    }
}
