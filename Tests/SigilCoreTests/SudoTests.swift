import XCTest
@testable import SigilCore

final class SudoTests: XCTestCase {
    private let pw = "s3cret 'quoted' $HOME `x`"

    private func syntax(_ args: [String], stdin: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await Shell.run("/bin/sh", args, stdin: stdin)
        XCTAssertEqual(r.exitCode, 0, r.stderr, file: file, line: line)
    }

    func testScriptOnStdinGetsThePasswordOnStdinOnly() async throws {
        let r = try XCTUnwrap(SudoScript.apply(password: pw, command: "sh -s", stdin: AppScript.probe))
        XCTAssertEqual(r.command, "sh -s", "nothing secret on the command line")
        XCTAssertTrue(r.stdin.hasPrefix("SIGIL_PW=\(AppScript.q(pw))\n"))
        XCTAssertTrue(r.stdin.hasSuffix(AppScript.probe))
        try await syntax(["-n"], stdin: r.stdin)
    }

    func testCommandLineScriptsReadThePasswordFirst() async throws {
        for command in [FileScript.command(FileScript.editRead), RemoteService.wrap(FileScript.read)] {
            let r = try XCTUnwrap(SudoScript.apply(password: pw, command: command, stdin: "/etc/shadow\n"))
            XCTAssertFalse(r.command.contains("s3cret"), "never on the command line")
            XCTAssertEqual(r.stdin, pw + "\n/etc/shadow\n", "password, then the script's own input")
            XCTAssertTrue(r.command.hasPrefix("sh -c 'IFS= read -r SIGIL_PW || exit 1; if "))
            // What the login shell runs: sh -c '<script>', checked with sh -n.
            try await syntax(["-c", "sh -n" + String(r.command.dropFirst(2))])
        }
    }

    func testOtherCommandsAreLeftAlone() {
        XCTAssertNil(SudoScript.apply(password: pw, command: "uptime", stdin: nil))
        XCTAssertNil(SudoScript.apply(password: "two\nlines", command: "sh -s", stdin: ""), "a line break would end the password early")
        XCTAssertFalse(SudoScript.isValid(""))
        XCTAssertFalse(SudoScript.lines.joined().contains("'"), "the preamble goes inside sh -c '…' unchanged")
    }

    func testPreambleVerdicts() {
        XCTAssertEqual(SudoScript.failure("SIGIL_SUDO=badpassword\n"), .wrongPassword)
        XCTAssertEqual(SudoScript.failure("noise\nSIGIL_SUDO=denied\n"), .notAllowed)
        XCTAssertNil(SudoScript.failure("admin=1\n"))
        XCTAssertEqual(DeckError.sudo(.wrongPassword).errorDescription, SudoFailure.wrongPassword.message)
    }

    /// Runs the preamble with a stand-in `sudo` (first in PATH) that checks the password the way sudo would: through
    /// SUDO_ASKPASS, and counts the attempts.
    func testPreambleWithAFakeSudo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-sudo-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin"), home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = """
        #!/bin/sh
        echo try >> "\(dir.path)/tries"
        [ "$1" = -A ] || { echo "sudo: a password is required" >&2; exit 1; }
        shift; [ "$1" = -k ] && shift
        for i in 1 2 3; do p=$("$SUDO_ASKPASS") || { echo "sudo: no password" >&2; exit 1; }; [ "$p" = "right pass" ] && break
          echo bad >> "\(dir.path)/bad"; [ $i = 3 ] && { echo "sudo: 3 incorrect password attempts" >&2; exit 1; }; done
        "$@"
        """
        try fake.write(to: bin.appendingPathComponent("sudo"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("sudo").path)
        let env = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": home.path]
        let body = #"S="sudo -n"; if sudo -n true 2>/dev/null; then echo admin=1; fi; $S echo ran; x=$($S echo sub); echo "$x""#

        let good = try XCTUnwrap(SudoScript.apply(password: "right pass", command: "sh -s", stdin: body))
        let r1 = try await Shell.run("/bin/sh", ["-s"], environment: env, stdin: good.stdin)
        XCTAssertEqual(r1.stdout, "admin=1\nran\nsub\n", r1.stderr)

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("bad"))
        let bad = try XCTUnwrap(SudoScript.apply(password: "wrong", command: "sh -s", stdin: body))
        let r2 = try await Shell.run("/bin/sh", ["-s"], environment: env, stdin: bad.stdin)
        XCTAssertEqual(SudoScript.failure(r2.stdout), .wrongPassword, r2.stdout + r2.stderr)
        XCTAssertFalse(r2.stdout.contains("ran"), "stops before the script")
        let attempts = (try? String(contentsOf: dir.appendingPathComponent("bad"), encoding: .utf8)) ?? ""
        XCTAssertEqual(attempts.split(separator: "\n").count, 1, "one failed attempt, never three")
    }

    @MainActor
    func testRefusedPasswordIsForgotten() throws {
        let box = try Sandbox()
        let s = Server(alias: "web", host: "203.0.113.7", port: 22, user: "deploy", keyFileName: "k",
                       publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIabc", keyFingerprint: "SHA256:x")
        try ServerStore(paths: box.paths).save([s])
        let model = DeckModel(paths: box.paths, hardened: false)
        model.load()
        model.sudoPasswords[s.id] = "old"
        model.sudoStore.save("old", account: s.id.uuidString)
        let t = model.target(for: s)
        XCTAssertEqual(t.sudoPassword, "old", "every connection to the server carries it")
        model.sudoRefused(t, .wrongPassword)
        XCTAssertFalse(model.isSudoUnlocked(s.id))
        XCTAssertFalse(model.hasSavedSudo(s.id), "a wrong password is never tried again")
        XCTAssertNil(model.target(for: s).sudoPassword)
    }

    /// Over real ssh into the Docker test server, as `sigiltest` (sudo with a password) and `sigilplain` (no sudo):
    /// `SIGIL_DOCKER=1 swift test --filter SudoTests`.
    func testRealSudoWithPasswordInTheDockerTestServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_DOCKER"] == "1", "opt-in")
        _ = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "sh", "-c", """
            id sigiltest >/dev/null 2>&1 || { useradd -m -s /bin/bash -G sudo sigiltest && echo sigiltest:Test-sudo-123 | chpasswd; }
            id sigilplain >/dev/null 2>&1 || { useradd -m -s /bin/bash sigilplain && echo sigilplain:Plain-123 | chpasswd; }
            faillock --user sigiltest --reset 2>/dev/null; true
            """])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-sudo-e2e-\(UUID().uuidString)")
        let paths = DeckPaths(sshDir: dir.appendingPathComponent("ssh"), supportDir: dir.appendingPathComponent("support"))
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scan = try await Shell.run("/usr/bin/ssh-keyscan", ["-p", "2222", "127.0.0.1"])
        try scan.stdout.write(to: paths.knownHosts, atomically: true, encoding: .utf8)
        // A throw-away key for both users (the test server may have password logins switched off).
        _ = try await Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", paths.keyURL("sudo-e2e").path])
        let pub = try String(contentsOf: paths.keyURL("sudo-e2e").appendingPathExtension("pub"), encoding: .utf8)
        for u in ["sigiltest", "sigilplain"] {
            _ = try await Shell.run("/usr/local/bin/docker", ["exec", "-i", "sigil-test-server", "sh", "-c",
                "install -d -m 700 -o \(u) -g \(u) /home/\(u)/.ssh && cat > /home/\(u)/.ssh/authorized_keys && chown \(u): /home/\(u)/.ssh/authorized_keys"],
                stdin: pub)
        }
        let remote = RemoteService(paths: paths, useKeychain: false)
        let user = RemoteTarget(host: "127.0.0.1", port: 2222, user: "sigiltest")
        let login = RemoteAuth.key(fileName: "sudo-e2e")

        let plain = AppScript.parse(probe: try await remote.execute(user, login, "sh -s", stdin: AppScript.probe).stdout)
        XCTAssertFalse(plain.admin, "without the password Sigil may not administer")

        var t = user
        t.sudoPassword = "Test-sudo-123"
        let probe = try await remote.execute(t, login, "sh -s", stdin: AppScript.probe)
        XCTAssertTrue(AppScript.parse(probe: probe.stdout).admin, probe.stdout + probe.stderr)
        XCTAssertTrue(AppScript.parse(probe: probe.stdout).ufwActive, "reads the firewall as root")

        let shadow = try await remote.execute(t, login, FileScript.command(FileScript.editRead), stdin: "/etc/shadow\n")
        XCTAssertTrue(shadow.stdout.contains("\nroot:"), "a root-only file through sh -c: \(shadow.stdout.prefix(80)) \(shadow.stderr)")

        let rule = try await remote.execute(t, login, "sh -s", stdin: AppScript.allowFrom("sudo-test", port: 9199, addresses: ["203.0.113.9"]))
        XCTAssertEqual(AppScript.result(rule.stdout), "allowed", rule.stdout + rule.stderr)
        let rules = try await remote.execute(t, login, "sh -s", stdin: "sudo -n ufw status\n")
        XCTAssertTrue(rules.stdout.contains("sigil-app:sudo-test"), rules.stdout)
        _ = try await remote.execute(t, login, "sh -s", stdin: "sudo -n ufw delete allow from 203.0.113.9 to any port 9199 proto tcp\n")

        let refused = expectation(description: "reported")
        remote.sudoFailures.set { target, f in
            if target.sudoPassword == "wrong-one", f == .wrongPassword { refused.fulfill() }
        }
        var wrong = user
        wrong.sudoPassword = "wrong-one"
        do {
            _ = try await remote.execute(wrong, login, "sh -s", stdin: "echo should-not-run\n")
            XCTFail("a wrong password must stop the script")
        } catch let e as DeckError { XCTAssertEqual(e, .sudo(.wrongPassword)) }
        await fulfillment(of: [refused], timeout: 5)
        let log = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "sh", "-c",
                                                                "journalctl -q _COMM=sudo --since '-1 min' | grep 'sigiltest :' | tail -n 1"])
        XCTAssertTrue(log.stdout.contains("1 incorrect password attempt"), "one attempt only: \(log.stdout)")
        XCTAssertFalse(log.stdout.contains("wrong-one"), "the password is not logged")

        // The reported case: in the docker group as well, installing an app (files written as root, .env 0600).
        _ = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "usermod", "-aG", "docker", "sigiltest"])
        let id = "node-exporter"
        let recipe = AppCatalog.builtIn.first { $0.id == id }!
        func run(_ script: String, timeout: TimeInterval = 600) async throws -> String {
            let r = try await remote.execute(t, login, "sh -s", stdin: script, timeout: timeout)
            return r.stdout + r.stderr
        }
        _ = try await run(AppScript.remove(id))
        let plan = AppScript.Plan(recipe: recipe, access: .allowList, port: 9198, domain: nil, secrets: [:],
                                  vars: ["BIND": "", "ADDR": "", "PORT": "9198", "VERSION": "v1.9.0"])
        let allowed = try await run(AppScript.allowFrom(id, port: 9198, addresses: ["203.0.113.9"]))
        XCTAssertEqual(AppScript.result(allowed), "allowed", allowed)
        let written = try await run(AppScript.write(plan))
        XCTAssertEqual(AppScript.result(written), "written", written)
        let pulled = try await run(AppScript.pull(id), timeout: 900)
        XCTAssertEqual(AppScript.result(pulled), "rc=0", pulled)
        let up = try await run(AppScript.up(id))
        XCTAssertEqual(AppScript.result(up), "rc=0", up)
        let waited = try await run(AppScript.wait(id, port: 9198, http: recipe.http))
        XCTAssertEqual(AppScript.result(waited), "ready", waited)
        let metrics = try await run("sleep 2; curl -s http://127.0.0.1:9198/metrics | grep -c '^node_network_receive_bytes_total'")
        XCTAssertGreaterThan(Int(metrics.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 0, metrics)
        let removed = try await run(AppScript.remove(id))
        XCTAssertTrue(AppScript.result(removed).hasPrefix("removed"), removed)
        let after = try await run("sudo -n ufw status")
        XCTAssertFalse(after.contains("sigil-app:\(id)"), "removing deletes the rule")

        var other = RemoteTarget(host: "127.0.0.1", port: 2222, user: "sigilplain")
        other.sudoPassword = "Plain-123"
        do {
            _ = try await remote.execute(other, login, "sh -s", stdin: "echo should-not-run\n")
            XCTFail("a user without sudo")
        } catch let e as DeckError { XCTAssertEqual(e, .sudo(.notAllowed)) }
    }
}
