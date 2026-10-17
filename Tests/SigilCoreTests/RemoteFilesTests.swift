import XCTest
@testable import SigilCore

@MainActor
final class RemoteFilesTests: XCTestCase {
    private func setUp() async throws -> (Sandbox, LocalSSHD, DeckModel, Server) {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let draft = ServerDraft(alias: "files", host: "127.0.0.1", port: sshd.port, user: NSUserName(), keyStore: .keychain)
        let (d, keys) = try await model.scanHostKeys(for: draft)
        let s = try await model.addServer(draft: d, password: "unused", hostKeys: keys)
        return (box, sshd, model, s)
    }

    func testSharedConnectionDoesNotAuthenticateAgain() async throws {
        let (box, sshd, model, s) = try await setUp(); _ = sshd
        defer { model.closeAllSessions() }
        _ = try await model.sessionTarget(s.id)
        // Take Sigil's key away: only the already open connection can still get in.
        let key = box.paths.keyURL(s.keyFileName)
        try FileManager.default.moveItem(at: key, to: key.appendingPathExtension("away"))
        let (dir, _) = try await model.listDirectory(s.id, box.root.path)
        XCTAssertEqual(dir, box.root.resolvingSymlinksInPath().path)
        model.closeSession(s.id)
        do { _ = try await model.listDirectory(s.id, box.root.path); XCTFail("without the shared connection the key is needed") } catch {}
    }

    func testBrowseCreateRenamePreviewCopyDelete() async throws {
        let (box, sshd, model, s) = try await setUp(); _ = sshd
        defer { model.closeAllSessions() }
        let base = box.root.appendingPathComponent("remote dir $x", isDirectory: true).path   // awkward name on purpose
        try await model.makeDirectory(s.id, base)
        let note = box.root.appendingPathComponent("note's.txt")
        try "merhaba dünya\n".write(to: note, atomically: true, encoding: .utf8)
        try await model.copy(s.id, local: note, remote: base, toServer: true)

        var (dir, files) = try await model.listDirectory(s.id, base)
        XCTAssertTrue(dir.hasSuffix("remote dir $x"))
        XCTAssertEqual(files.map(\.name), ["note's.txt"])
        XCTAssertEqual(files.first?.kind, .file)
        XCTAssertEqual(files.first?.size, 15)

        let text = try await model.readFile(s.id, base + "/note's.txt")
        XCTAssertEqual(text, "merhaba dünya\n")

        try await model.makeDirectory(s.id, base + "/alt")
        try await model.renameFile(s.id, from: base + "/note's.txt", to: base + "/alt/renamed.txt")
        do { try await model.renameFile(s.id, from: base + "/alt", to: base + "/alt/renamed.txt"); XCTFail() } catch {}
        (_, files) = try await model.listDirectory(s.id, base)
        XCTAssertEqual(files.map(\.name), ["alt"])
        XCTAssertEqual(files.first?.kind, .directory)

        let back = box.root.appendingPathComponent("downloaded.txt")
        try await model.copy(s.id, local: back, remote: base + "/alt/renamed.txt", toServer: false)
        XCTAssertEqual(try String(contentsOf: back, encoding: .utf8), "merhaba dünya\n")

        try await model.deleteFile(s.id, base + "/alt")
        (_, files) = try await model.listDirectory(s.id, base)
        XCTAssertTrue(files.isEmpty)
        do { try await model.deleteFile(s.id, "/"); XCTFail("refuses /") } catch {}
    }

    func testEditAndSaveKeepsModeAndRefusesStaleVersions() async throws {
        let (box, sshd, model, s) = try await setUp(); _ = sshd
        defer { model.closeAllSessions() }
        let file = box.root.appendingPathComponent("app $x/.env")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "A=1\nB='iki'\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let opened = try await model.openForEditing(s.id, file.path)
        XCTAssertEqual(opened.text, "A=1\nB='iki'\n")
        XCTAssertNil(opened.readOnlyReason)

        let edited = "A=1\nB='iki'\nC=\"üç $HOME\"\nno newline at end"
        let version = try await model.saveFile(s.id, file.path, text: edited, version: opened.version)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited, "byte for byte, quotes and $ untouched")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int), 0o600, "mode kept")
        XCTAssertTrue(version.hasSuffix(" \(edited.utf8.count)"))

        // Someone else changes the file: the old version must not overwrite it.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "changed elsewhere\n".write(to: file, atomically: false, encoding: .utf8)
        do { _ = try await model.saveFile(s.id, file.path, text: "mine", version: version); XCTFail("stale version accepted") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed elsewhere\n")

        let binary = box.root.appendingPathComponent("blob.bin")
        try Data([0x00, 0xFF, 0xFE, 0x41]).write(to: binary)
        let b = try await model.openForEditing(s.id, binary.path)
        XCTAssertNotNil(b.readOnlyReason, "binary files are not saved back")
    }

    func testParsesFindOutput() {
        let out = "d\t4096\t1760500000.0\tdrwxr-xr-x\troot\tetc\nf\t12\t1760500001.5\t-rw-r--r--\troot\t.bashrc\nl\t7\t1760500002\tlrwxrwxrwx\troot\tbin\n"
        let files = FileScript.parse(out, in: "/")
        XCTAssertEqual(files.map(\.name), ["etc", ".bashrc", "bin"])
        XCTAssertEqual(files.map(\.path), ["/etc", "/.bashrc", "/bin"])
        XCTAssertTrue(files[1].isHidden)
        XCTAssertEqual(files[2].kind, .link)
    }
}

/// The approval window: one login is shared for a while (ControlPersist), Sigil's calls do not hang on the
/// backgrounded master, and locking ends it.
@MainActor
final class ApprovalWindowTests: XCTestCase {
    func testOneLoginIsSharedUntilLocked() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let draft = ServerDraft(alias: "win", host: "127.0.0.1", port: sshd.port, user: NSUserName(), keyStore: .keychain)
        let (d, keys) = try await model.scanHostKeys(for: draft)
        let s = try await model.addServer(draft: d, password: "unused", hostKeys: keys)
        defer { Task { await model.lockApprovals() } }

        var t = model.target(for: s)
        t.persist = (ConfigManager(paths: box.paths).controlDirectory.path, 1)
        try FileManager.default.createDirectory(at: ConfigManager(paths: box.paths).controlDirectory, withIntermediateDirectories: true)
        let auth = RemoteAuth.key(fileName: s.keyFileName)

        let start = Date()
        try await model.remote.ping(target: t, auth: auth)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "the backgrounded master must not hold the call open")

        let key = box.paths.keyURL(s.keyFileName)
        try FileManager.default.moveItem(at: key, to: key.appendingPathExtension("away"))
        try await model.remote.ping(target: t, auth: auth)   // no key: only the shared login can do this

        await model.lockApprovals()
        do { try await model.remote.ping(target: t, auth: auth); XCTFail("locked: a new login needs the key") } catch {}
    }

    func testConfigSharesOnlyForServersThatAskForApproval() throws {
        let box = try Sandbox()
        var se = Server(alias: "se", host: "203.0.113.7", port: 22, user: "u", keyFileName: "k1",
                        publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIabc", keyFingerprint: "SHA256:x")
        se.keyStore = .secureEnclave
        let kc = Server(alias: "kc", host: "203.0.113.8", port: 22, user: "u", keyFileName: "k2",
                        publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIdef", keyFingerprint: "SHA256:y")
        let text = ConfigManager(paths: box.paths).render([se, kc], persistMinutes: 15)
        // Blocks are sorted by alias: kc, then se.
        let parts = text.components(separatedBy: "Host se")
        XCTAssertTrue(parts[1].contains("ControlMaster auto") && parts[1].contains("ControlPersist 15m") && parts[1].contains("/cm/%C"))
        XCTAssertFalse(parts[0].contains("ControlMaster"), "Keychain keys never ask, so nothing to share")
        XCTAssertFalse(ConfigManager(paths: box.paths).render([se], persistMinutes: 0).contains("ControlMaster"), "0 = ask every time")
    }
}
