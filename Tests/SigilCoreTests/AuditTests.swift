import XCTest
@testable import SigilCore

final class AuthorizedKeysParserTests: XCTestCase {
    func testParsesKeysWithOptionsAndComments() {
        let text = """
        # comment
        ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlainKeyBlobxxxxxxxx me@laptop
        command="/usr/bin/rsync",no-pty ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCxx backup bot

        ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAA
        not a key line
        """
        let keys = RemoteService.parseAuthorizedKeys(text)
        XCTAssertEqual(keys.map(\.type), ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"])
        XCTAssertEqual(keys[0].comment, "me@laptop")
        XCTAssertEqual(keys[1].comment, "backup bot")
        XCTAssertEqual(keys[2].comment, "")
    }
}

@MainActor
final class AuditFlowTests: XCTestCase {
    private func setUp() async throws -> (Sandbox, LocalSSHD, DeckModel, Server) {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let (d, keys) = try await model.scanHostKeys(for: ServerDraft(alias: "audited", host: "127.0.0.1", port: sshd.port, user: NSUserName()))
        let s = try await model.addServer(draft: d, password: "x", hostKeys: keys)
        return (box, sshd, model, s)
    }

    func testAuditFindsForeignKeysAndRemovesThem() async throws {
        let (box, sshd, model, s) = try await setUp()
        _ = box
        var notes: [String] = []
        model.notify = { t, _ in notes.append(t) }

        // Baseline: only the bootstrap key is foreign. First audit never alerts.
        let first = try await model.audit(s.id)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(model.server(s.id)?.foreignKeys?.count, 1)
        XCTAssertTrue(notes.isEmpty, "first audit is a baseline")

        // Someone adds a key behind our back.
        let intruder = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIntruderKeyIntruderKeyIntruderKey99 intruder@evil"
        let fh = try FileHandle(forWritingTo: sshd.authorizedKeys)
        try fh.seekToEnd(); try fh.write(contentsOf: Data((intruder + "\n").utf8)); try fh.close()

        let second = try await model.audit(s.id)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(notes.count, 1)
        let foreign = try XCTUnwrap(model.server(s.id)?.foreignKeys?.first { $0.comment == "intruder@evil" })
        XCTAssertEqual(model.server(s.id)?.unacknowledgedForeignKeys.count, 2)

        // Acknowledge the bootstrap key, remove the intruder.
        let bootstrap = try XCTUnwrap(model.server(s.id)?.foreignKeys?.first { $0.comment != "intruder@evil" })
        model.acknowledgeForeignKey(s.id, blob: bootstrap.blob)
        try await model.removeForeignKey(s.id, blob: foreign.blob)
        XCTAssertFalse(sshd.authorizedKeyLines.contains { $0.contains("intruder@evil") })
        XCTAssertEqual(model.server(s.id)?.unacknowledgedForeignKeys.count, 0)

        // Sigil's own key can't be removed through this path.
        do { try await model.removeForeignKey(s.id, blob: s.publicKeyBlob); XCTFail("must refuse") } catch {}
    }

    func testHostKeyChangeRaisesAlarmOnce() async throws {
        let (box, sshd, model, s) = try await setUp(); _ = sshd
        var notes: [String] = []
        model.notify = { t, _ in notes.append(t) }

        // Replace the recorded host key with a different one, as if the server (or an attacker) changed.
        let fake = "AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyFakeHostKeyFakeHostKey000"
        let text = try String(contentsOf: box.paths.knownHosts, encoding: .utf8)
        let swapped = text.split(separator: "\n").map { line -> String in
            let p = line.split(separator: " ").map(String.init)
            return p.count >= 3 && p[1] == "ssh-ed25519" ? "\(p[0]) \(p[1]) \(fake)" : String(line)
        }.joined(separator: "\n") + "\n"
        try swapped.write(to: box.paths.knownHosts, atomically: true, encoding: .utf8)

        await model.checkStatus(s.id)
        await model.checkStatus(s.id)
        XCTAssertEqual(model.server(s.id)?.hostKeyMismatch, true)
        XCTAssertEqual(model.server(s.id)?.lastReachable, false, "ssh refuses a changed host key")
        XCTAssertEqual(notes.filter { $0.contains("mührü değişti") }.count, 1, "alarm raised once, not every check")
    }

    func testRotateAllRotatesEveryServer() async throws {
        let (box, sshd, model, s) = try await setUp(); _ = box
        let (d2, k2) = try await model.scanHostKeys(for: ServerDraft(alias: "second", host: "127.0.0.1", port: sshd.port, user: NSUserName()))
        let s2 = try await model.addServer(draft: d2, password: "x", hostKeys: k2)
        let results = await model.rotateAll()
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.values.allSatisfy { $0 })
        XCTAssertNotEqual(model.server(s.id)?.publicKeyBlob, s.publicKeyBlob)
        XCTAssertNotEqual(model.server(s2.id)?.publicKeyBlob, s2.publicKeyBlob)
    }
}

@MainActor
final class AcceptHostKeyTests: XCTestCase {
    func testAcceptingNewHostKeyRestoresAccess() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let (d, keys) = try await model.scanHostKeys(for: ServerDraft(alias: "rebuilt", host: "127.0.0.1", port: sshd.port, user: NSUserName()))
        let s = try await model.addServer(draft: d, password: "x", hostKeys: keys)

        // Corrupt the recorded host key → mismatch.
        let text = try String(contentsOf: box.paths.knownHosts, encoding: .utf8)
        try text.replacingOccurrences(of: keys[0].blob, with: "AAAAC3NzaC1lZDI1NTE5AAAAIOtherOtherOtherOtherOtherOther0000")
            .write(to: box.paths.knownHosts, atomically: true, encoding: .utf8)
        await model.checkStatus(s.id)
        XCTAssertEqual(model.server(s.id)?.hostKeyMismatch, true)

        let fresh = try await model.scanHostKeys(of: s.id)
        try await model.acceptNewHostKey(s.id, keys: fresh)
        XCTAssertEqual(model.server(s.id)?.hostKeyMismatch, false)
        XCTAssertEqual(model.server(s.id)?.lastReachable, true)
    }
}
