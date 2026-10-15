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

    func testParsesFindOutput() {
        let out = "d\t4096\t1760500000.0\tdrwxr-xr-x\troot\tetc\nf\t12\t1760500001.5\t-rw-r--r--\troot\t.bashrc\nl\t7\t1760500002\tlrwxrwxrwx\troot\tbin\n"
        let files = FileScript.parse(out, in: "/")
        XCTAssertEqual(files.map(\.name), ["etc", ".bashrc", "bin"])
        XCTAssertEqual(files.map(\.path), ["/etc", "/.bashrc", "/bin"])
        XCTAssertTrue(files[1].isHidden)
        XCTAssertEqual(files[2].kind, .link)
    }
}
