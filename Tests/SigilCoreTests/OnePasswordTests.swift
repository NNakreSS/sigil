import XCTest
@testable import SigilCore

/// Stands in for 1Password: a fake `op` CLI (Python) backed by a scratch directory, and a scratch `ssh-agent`
/// standing in for the 1Password SSH agent. Mirrors the real CLI's behaviour that matters here, including that
/// `op item create` prints the private key in its JSON output.
final class FakeOnePassword {
    let dir: URL
    let opPath: URL
    let socket: String
    private var agent: Process?

    init(sandbox: Sandbox) throws {
        dir = sandbox.root.appendingPathComponent("fakeop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("items"), withIntermediateDirectories: true)
        socket = sandbox.root.appendingPathComponent("agent.sock").path
        opPath = dir.appendingPathComponent("op")
        try Self.script.write(to: opPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opPath.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        p.arguments = ["-D", "-a", socket]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        agent = p
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { Thread.sleep(forTimeInterval: 0.05) }
    }

    deinit {
        agent?.terminate()
        agent?.waitUntilExit()
    }

    func service(_ paths: DeckPaths, deny: Bool = false) -> OnePasswordService {
        var env = ["FAKEOP_DIR": dir.path, "SSH_AUTH_SOCK": socket]
        if deny { env["FAKEOP_DENY"] = "1" }
        return OnePasswordService(paths: paths, cliPath: opPath.path, socketPath: socket, environment: env)
    }

    struct Meta: Decodable { let id: String; let vault: String; let tags: [String]; let archived: Bool }

    var items: [Meta] {
        let itemsDir = dir.appendingPathComponent("items")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: itemsDir.path)) ?? []
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: itemsDir.appendingPathComponent(id).appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder().decode(Meta.self, from: data)
        }
    }

    var agentKeyCount: Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = ["-l"]
        p.environment = ["SSH_AUTH_SOCK": socket]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(whereSeparator: \.isNewline).filter { $0.contains("SHA256:") }.count
    }

    static let script = #"""
    #!/usr/bin/python3 -I
    import sys, os, json, subprocess, uuid
    root = os.environ["FAKEOP_DIR"]; items = os.path.join(root, "items")
    a = sys.argv[1:]
    def opt(n):
        return a[a.index(n) + 1] if n in a else None
    def meta(i):
        return json.load(open(os.path.join(items, i, "meta.json")))
    def save(i, m):
        json.dump(m, open(os.path.join(items, i, "meta.json"), "w"))
    if a[:1] == ["--version"]:
        print("2.41.0"); sys.exit(0)
    if a[:2] == ["account", "list"]:
        print(json.dumps([{"url": "fake.1password.com"}])); sys.exit(0)
    if a[:2] == ["vault", "list"]:
        print(json.dumps([{"id": "v-shared", "name": "Shared"}, {"id": "v-priv", "name": "Private"}])); sys.exit(0)
    if a[:2] == ["item", "create"]:
        if os.environ.get("FAKEOP_DENY"):
            sys.stderr.write("[ERROR] authorization prompt dismissed, please try again\n"); sys.exit(1)
        assert opt("--category") == "ssh"
        i = uuid.uuid4().hex[:26]; d = os.path.join(items, i); os.makedirs(d); k = os.path.join(d, "key")
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "fake", "-f", k], check=True)
        subprocess.run(["/usr/bin/ssh-add", "-q", k], check=True, capture_output=True)
        pub = open(k + ".pub").read().split()
        fp = subprocess.run(["/usr/bin/ssh-keygen", "-lf", k + ".pub"], capture_output=True, text=True).stdout.split()[1]
        save(i, {"id": i, "vault": opt("--vault"), "tags": opt("--tags").split(","),
                 "public_key": pub[0] + " " + pub[1], "fingerprint": fp, "archived": False})
        print(json.dumps({"id": i, "fields": [{"id": "private_key", "value": open(k).read()}]}))
        sys.exit(0)
    if a[:2] == ["item", "list"]:
        out = [{"id": i} for i in os.listdir(items)
               if opt("--tags") in meta(i)["tags"] and not meta(i)["archived"] and meta(i)["vault"] == opt("--vault")]
        print(json.dumps(out)); sys.exit(0)
    if a[:2] == ["item", "get"]:
        m = meta(a[2])
        print(json.dumps([{"id": "public_key", "label": "public key", "value": m["public_key"]},
                          {"id": "fingerprint", "label": "fingerprint", "value": m["fingerprint"]}]))
        sys.exit(0)
    if a[:2] == ["item", "delete"]:
        assert "--archive" in a
        m = meta(a[2])
        subprocess.run(["/usr/bin/ssh-add", "-d", os.path.join(items, a[2], "key.pub")], capture_output=True)
        m["archived"] = True; save(a[2], m); sys.exit(0)
    sys.stderr.write("fake op: unsupported %r\n" % a); sys.exit(2)
    """#
}

@MainActor
final class OnePasswordFlowTests: XCTestCase {
    private func setUp1P(deny: Bool = false) throws -> (Sandbox, LocalSSHD, FakeOnePassword, DeckModel) {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let fake = try FakeOnePassword(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path,
                              onePassword: fake.service(box.paths, deny: deny))
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        return (box, sshd, fake, model)
    }

    private func add(_ model: DeckModel, _ sshd: LocalSSHD, alias: String = "opbox") async throws -> Server {
        let draft = ServerDraft(alias: alias, host: "127.0.0.1", port: sshd.port, user: NSUserName(), keyStore: .onePassword)
        let (d, hostKeys) = try await model.scanHostKeys(for: draft)
        return try await model.addServer(draft: d, password: "unused", hostKeys: hostKeys)
    }

    private func sshAlias(_ box: Sandbox, _ alias: String) async throws -> ShellResult {
        try await Shell.run("/usr/bin/ssh", [
            "-F", box.paths.mainConfig.path, "-o", "UserKnownHostsFile=\(box.paths.knownHosts.path)",
            "-o", "BatchMode=yes", alias, "echo alias-works",
        ], environment: ["SSH_AUTH_SOCK": "/nonexistent"])   // only the config's IdentityAgent may supply the key
    }

    func testStatusReportsReady() async throws {
        let (box, sshd, fake, model) = try setUp1P(); _ = (box, sshd, fake)
        await model.refreshOnePasswordStatus()
        XCTAssertTrue(model.onePasswordStatus.isReady)
        XCTAssertEqual(model.onePasswordStatus.cliVersion, "2.41.0")
        XCTAssertEqual(model.recommendedKeyStore, SecureEnclaveService.isSupported ? .secureEnclave : .onePassword)
    }

    func testAddWithOnePasswordKeepsPrivateKeyOutOfDiskAndConnects() async throws {
        let (box, sshd, fake, model) = try setUp1P()
        let s = try await add(model, sshd)

        XCTAssertEqual(s.store, .onePassword)
        XCTAssertNotNil(s.onePasswordItemID)
        XCTAssertEqual(s.onePasswordVaultID, "v-priv", "keys must go to the vault the agent serves")
        XCTAssertEqual(fake.items.count, 1)
        XCTAssertTrue(fake.items[0].tags.contains("sigil"))

        // Only the public key exists locally.
        let local = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path)
            .filter { !$0.hasPrefix(sshd.bootstrapKeyName) }
        XCTAssertEqual(local, [s.keyFileName + ".pub"])
        for f in try FileManager.default.subpathsOfDirectory(atPath: box.root.path) where !f.contains("fakeop") && !f.contains("sshd") && !f.contains(sshd.bootstrapKeyName) {
            let text = (try? String(contentsOf: box.root.appendingPathComponent(f), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("PRIVATE KEY"), "private key leaked into \(f)")
        }

        XCTAssertTrue(sshd.authorizedKeyLines.contains { $0.contains(s.publicKeyBlob) })

        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        XCTAssertTrue(cfg.contains("IdentityAgent \"\(fake.socket)\""))
        XCTAssertTrue(cfg.contains("IdentityFile \(box.paths.keyURL(s.keyFileName).path).pub"))
        XCTAssertFalse(cfg.contains("UseKeychain"))

        let r = try await sshAlias(box, "opbox")
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(r.stdout.contains("alias-works"))
    }

    func testRotationReplacesItemAndArchivesOldOne() async throws {
        let (box, sshd, fake, model) = try setUp1P()
        let before = try await add(model, sshd)

        let ok = await model.rotate(before.id)
        XCTAssertTrue(ok, model.server(before.id)?.events.last?.message ?? "")
        let after = try XCTUnwrap(model.server(before.id))

        XCTAssertNotEqual(after.onePasswordItemID, before.onePasswordItemID)
        XCTAssertEqual(fake.items.first { $0.id == before.onePasswordItemID }?.archived, true, "old item archived, not deleted")
        XCTAssertEqual(fake.items.first { $0.id == after.onePasswordItemID }?.archived, false)
        XCTAssertEqual(fake.agentKeyCount, 1, "old key no longer offered by the agent")

        XCTAssertFalse(sshd.authorizedKeyLines.contains { $0.contains(before.publicKeyBlob) })
        XCTAssertTrue(sshd.authorizedKeyLines.contains { $0.contains(after.publicKeyBlob) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.keyURL(before.keyFileName).path + ".pub"))

        let r = try await sshAlias(box, "opbox")
        XCTAssertTrue(r.succeeded, r.stderr)
    }

    func testDueOnePasswordServerIsNotRotatedSilentlyButNotifiedOnce() async throws {
        let (box, sshd, fake, model) = try setUp1P(); _ = (box, fake)
        let s = try await add(model, sshd)
        var notes: [String] = []
        model.notify = { title, _ in notes.append(title) }

        // Make it overdue by editing the persisted list and reloading.
        var list = ServerStore(paths: model.paths).load().servers
        list[0].lastRotatedAt = Date(timeIntervalSinceNow: -60 * 86400)
        try ServerStore(paths: model.paths).save(list)
        model.load()

        await model.rotateDueServers()
        await model.rotateDueServers()
        XCTAssertEqual(model.server(s.id)?.publicKeyBlob, s.publicKeyBlob, "no unattended rotation for 1Password keys")
        XCTAssertEqual(notes.count, 1, "notified exactly once per due period")
        XCTAssertEqual(model.awaitingManualRotation.map(\.id), [s.id])
    }

    func testRemovalArchivesItem() async throws {
        let (box, sshd, fake, model) = try setUp1P()
        let s = try await add(model, sshd)
        try await model.removeServer(s.id, removeRemoteKey: true)
        XCTAssertEqual(fake.items.first?.archived, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.paths.keyURL(s.keyFileName).path + ".pub"))
        XCTAssertEqual(sshd.authorizedKeyLines.count, 1)
    }

    func testDeniedApprovalLeavesNothingBehind() async throws {
        let (box, sshd, fake, model) = try setUp1P(deny: true)
        do {
            _ = try await add(model, sshd)
            XCTFail("should fail")
        } catch let e as DeckError {
            XCTAssertTrue(e.localizedDescription.contains("Onay verilmedi"), e.localizedDescription)
        }
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertTrue(fake.items.isEmpty)
        let local = try FileManager.default.contentsOfDirectory(atPath: box.paths.keysDir.path).filter { !$0.hasPrefix(sshd.bootstrapKeyName) }
        XCTAssertTrue(local.isEmpty)
    }

    func testMixedStoresRenderCorrectly() async throws {
        let (box, sshd, fake, model) = try setUp1P()
        _ = try await add(model, sshd, alias: "op1")
        let draft = ServerDraft(alias: "kc1", host: "127.0.0.1", port: sshd.port, user: NSUserName(), keyStore: .keychain)
        let (d, hk) = try await model.scanHostKeys(for: draft)
        _ = try await model.addServer(draft: d, password: "unused", hostKeys: hk)

        let cfg = try String(contentsOf: box.paths.includeFile, encoding: .utf8)
        let op1 = cfg.components(separatedBy: "Host op1")[1].components(separatedBy: "Host ")[0]
        let kc1 = cfg.components(separatedBy: "Host kc1")[1].components(separatedBy: "Host ")[0]
        XCTAssertTrue(op1.contains("IdentityAgent \"\(fake.socket)\""))
        XCTAssertTrue(kc1.contains("IdentityAgent SSH_AUTH_SOCK"))
        XCTAssertTrue(kc1.contains("UseKeychain yes"))
        let r1 = try await sshAlias(box, "op1"); XCTAssertTrue(r1.succeeded, r1.stderr)
        let r2 = try await sshAlias(box, "kc1"); XCTAssertTrue(r2.succeeded, r2.stderr)
    }
}
