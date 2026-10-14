import XCTest
@testable import SigilCore

final class ImportParserTests: XCTestCase {
    func testFindsOnlySimpleHostBlocks() throws {
        let box = try Sandbox()
        try """
        # my config
        Include "/somewhere/else"

        Host *
          ServerAliveInterval 5

        Host webserver
          HostName 203.0.113.7
          User root
          IdentityFile ~/.ssh/id_ed25519_work
          IdentitiesOnly yes

        Host a b
          HostName 1.2.3.4

        Host web-*
          User deploy

        Host viaProxy
          HostName 10.0.0.9
          ProxyCommand nc %h %p

        Host noHostName
          User ubuntu
          Port 2222

        Match host foo
          User bar
        """.write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)

        let found = ConfigManager(paths: box.paths).importCandidates()
        XCTAssertEqual(found.map(\.alias), ["webserver", "noHostName"])
        let p = found[0]
        XCTAssertEqual(p.host, "203.0.113.7")
        XCTAssertEqual(p.user, "root")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.identityFile, "~/.ssh/id_ed25519_work")
        XCTAssertEqual(found[1].host, "noHostName")
        XCTAssertEqual(found[1].port, 2222)

        XCTAssertEqual(ConfigManager(paths: box.paths).importCandidates(excluding: ["webserver"]).map(\.alias), ["noHostName"])
    }

    func testRetireCommentsOutExactlyTheBlockWithBackup() throws {
        let box = try Sandbox()
        let original = "Host keep\n  HostName 1.1.1.1\n\nHost move\n  HostName 2.2.2.2\n  User root\n\nHost after\n  HostName 3.3.3.3\n"
        try original.write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)
        let cm = ConfigManager(paths: box.paths)
        let move = try XCTUnwrap(cm.importCandidates().first { $0.alias == "move" })
        try cm.retire(move)

        let text = try String(contentsOf: box.paths.mainConfig, encoding: .utf8)
        XCTAssertTrue(text.contains("# Host move"))
        XCTAssertTrue(text.contains("#   HostName 2.2.2.2"))
        XCTAssertTrue(text.hasPrefix("Host keep\n"))
        XCTAssertTrue(text.contains("\nHost after\n  HostName 3.3.3.3"))
        XCTAssertEqual(cm.importCandidates().map(\.alias), ["keep", "after"])

        let backups = try FileManager.default.contentsOfDirectory(atPath: box.paths.sshDir.path).filter { $0.hasPrefix("config.sigil-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: box.paths.sshDir.appendingPathComponent(backups[0]), encoding: .utf8), original)
    }
}

@MainActor
final class ImportFlowTests: XCTestCase {
    /// Migrates a host the user already reaches with their own key — no password, no override.
    func testImportUsesExistingSetupAndTakesOverAlias() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        try """
        Host *
          ServerAliveInterval 5

        Host oldbox
          HostName 127.0.0.1
          Port \(sshd.port)
          User \(NSUserName())
          IdentityFile \(box.paths.keyURL(sshd.bootstrapKeyName).path)
          IdentitiesOnly yes
        """.write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)

        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        let candidate = try XCTUnwrap(model.importCandidates().first)
        XCTAssertEqual(candidate.alias, "oldbox")

        let keys = try await HostKeyService(paths: box.paths).scan(host: "127.0.0.1", port: sshd.port)
        let server = try await model.importServer(candidate, keyStore: .keychain, rotationIntervalDays: 30,
                                                  hostKeys: keys, password: nil, removeOldKey: true)

        XCTAssertEqual(server.alias, "oldbox")
        XCTAssertEqual(model.servers.count, 1)
        // Only the new key is left on the server; the old one was removed as requested.
        XCTAssertEqual(sshd.authorizedKeyLines.count, 1)
        XCTAssertTrue(sshd.authorizedKeyLines[0].contains(server.publicKeyBlob))

        let cfg = try String(contentsOf: box.paths.mainConfig, encoding: .utf8)
        XCTAssertTrue(cfg.contains("# Host oldbox"), "old block commented out")
        XCTAssertTrue(cfg.contains("Include"), "Sigil include added")

        // `ssh oldbox` now goes through Sigil's entry and the new key.
        let r = try await Shell.run("/usr/bin/ssh", [
            "-F", box.paths.mainConfig.path, "-o", "UserKnownHostsFile=\(box.paths.knownHosts.path)",
            "-o", "BatchMode=yes", "oldbox", "echo migrated",
        ])
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(r.stdout.contains("migrated"))
        XCTAssertTrue(model.importCandidates().isEmpty)
    }

    func testImportFailureLeavesUserConfigUntouched() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let config = """
        Host brokenbox
          HostName 127.0.0.1
          Port \(sshd.port)
          User \(NSUserName())
          IdentityFile /nonexistent/key
          IdentitiesOnly yes
        """
        try config.write(to: box.paths.mainConfig, atomically: true, encoding: .utf8)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        let candidate = try XCTUnwrap(model.importCandidates().first)
        let keys = try await HostKeyService(paths: box.paths).scan(host: "127.0.0.1", port: sshd.port)

        do {
            _ = try await model.importServer(candidate, keyStore: .keychain, rotationIntervalDays: 30,
                                             hostKeys: keys, password: nil, removeOldKey: false)
            XCTFail("should fail: the existing setup cannot log in")
        } catch {}

        XCTAssertTrue(model.servers.isEmpty)
        let after = try String(contentsOf: box.paths.mainConfig, encoding: .utf8)
        XCTAssertTrue(after.contains("\nHost brokenbox") || after.hasPrefix("Host brokenbox") || after.contains("Host brokenbox\n"),
                      "user block must still be active")
        XCTAssertFalse(after.contains("# Host brokenbox"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path).filter { !$0.hasPrefix(sshd.bootstrapKeyName) }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertEqual(sshd.authorizedKeyLines.count, 1)
    }
}
