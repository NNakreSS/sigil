import XCTest
@testable import SigilCore

/// Regressions for the issues found in the security review.
final class HostKeyTrustRegressionTests: XCTestCase {
    private func key(_ box: Sandbox, _ name: String, type: String) async throws -> String {
        let url = box.paths.keyURL(name)
        var args = ["-q", "-t", type, "-N", "", "-f", url.path]
        if type == "rsa" { args += ["-b", "2048"] }
        let r = try await Shell.run("/usr/bin/ssh-keygen", args)
        XCTAssertTrue(r.succeeded, r.stderr)
        return String(try String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ")[1])
    }

    /// A MITM that only offers a key type never recorded for this host must be refused, not added.
    func testKnownHostOfferingOnlyANewKeyTypeIsRefused() async throws {
        let box = try Sandbox()
        let realBlob = try await key(box, "real", type: "ed25519")
        let mitmBlob = try await key(box, "mitm", type: "rsa")
        try "198.51.100.7 ssh-ed25519 \(realBlob)\n".write(to: box.paths.knownHosts, atomically: true, encoding: .utf8)

        let mitm = try XCTUnwrap(HostKeyService.parse("198.51.100.7 ssh-rsa \(mitmBlob)"))
        do {
            try await HostKeyService(paths: box.paths).trust([mitm], host: "198.51.100.7", port: 22)
            XCTFail("must refuse")
        } catch let e as DeckError {
            if case .hostKeyChanged = e {} else { XCTFail("wrong error \(e)") }
        }
        XCTAssertFalse(try String(contentsOf: box.paths.knownHosts, encoding: .utf8).contains(mitmBlob))
    }

    /// Even when the real key is presented, an extra key of a new type for a known host is not added.
    func testKnownHostNeverGainsNewKeyTypes() async throws {
        let box = try Sandbox()
        let realBlob = try await key(box, "real", type: "ed25519")
        let extraBlob = try await key(box, "extra", type: "rsa")
        try "198.51.100.7 ssh-ed25519 \(realBlob)\n".write(to: box.paths.knownHosts, atomically: true, encoding: .utf8)

        let keys = [
            try XCTUnwrap(HostKeyService.parse("198.51.100.7 ssh-ed25519 \(realBlob)")),
            try XCTUnwrap(HostKeyService.parse("198.51.100.7 ssh-rsa \(extraBlob)")),
        ]
        let created = try await HostKeyService(paths: box.paths).trust(keys, host: "198.51.100.7", port: 22)
        XCTAssertFalse(created)
        XCTAssertFalse(try String(contentsOf: box.paths.knownHosts, encoding: .utf8).contains(extraBlob))
    }

    func testUnknownHostIsAddedAndReportedAsCreated() async throws {
        let box = try Sandbox()
        let blob = try await key(box, "k", type: "ed25519")
        let created = try await HostKeyService(paths: box.paths)
            .trust([try XCTUnwrap(HostKeyService.parse("203.0.113.9 ssh-ed25519 \(blob)"))], host: "203.0.113.9", port: 22)
        XCTAssertTrue(created)
        XCTAssertTrue(try String(contentsOf: box.paths.knownHosts, encoding: .utf8).contains(blob))
    }
}

final class ShellOutputCapTests: XCTestCase {
    /// A (malicious) server streaming unbounded output must not exhaust memory; the process still completes.
    func testOutputIsCappedAndProcessStillFinishes() async throws {
        let r = try await Shell.run("/bin/sh", ["-c", "head -c 5000000 /dev/zero; echo done >&2"], timeout: 30)
        XCTAssertTrue(r.succeeded)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.stdout.utf8.count, Shell.maxOutputBytes)
        XCTAssertTrue(r.stderr.contains("done"))
    }
}

@MainActor
final class KnownHostsOwnershipTests: XCTestCase {
    /// Removing a server must not delete a known_hosts entry the user had created on their own.
    func testRemovingServerKeepsUsersOwnHostTrust() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)

        let draft = ServerDraft(alias: "mine", host: "127.0.0.1", port: sshd.port, user: NSUserName())
        let (d, hostKeys) = try await model.scanHostKeys(for: draft)

        // The user already trusted this host before using the app.
        try await HostKeyService(paths: box.paths).trust(hostKeys, host: "127.0.0.1", port: sshd.port)
        let before = try String(contentsOf: box.paths.knownHosts, encoding: .utf8)

        let s = try await model.addServer(draft: d, password: "unused", hostKeys: hostKeys)
        XCTAssertEqual(s.createdKnownHostsEntry, false)
        try await model.removeServer(s.id, removeRemoteKey: true)

        XCTAssertEqual(try String(contentsOf: box.paths.knownHosts, encoding: .utf8), before)
    }
}
