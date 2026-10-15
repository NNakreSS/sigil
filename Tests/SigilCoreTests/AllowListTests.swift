import XCTest
@testable import SigilCore

final class AllowListTests: XCTestCase {
    func testValidatesAddressesAndNetworks() throws {
        XCTAssertEqual(try AllowList.validate(" 203.0.113.7 "), "203.0.113.7")
        XCTAssertEqual(try AllowList.validate("198.51.100.0/24"), "198.51.100.0/24")
        XCTAssertEqual(try AllowList.validate("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(try AllowList.validate("2001:db8::/32"), "2001:db8::/32")
        for bad in ["", "300.1.1.1", "1.2.3", "1.2.3.4/33", "1.2.3.4; rm -rf /", "example.com", "1.2.3.4/x", "::/129", "01.2.3.4.5"] {
            XCTAssertThrowsError(try AllowList.validate(bad), bad)
        }
    }

    func testContainment() {
        XCTAssertTrue(AllowList.contains("203.0.113.7", "203.0.113.7"))
        XCTAssertFalse(AllowList.contains("203.0.113.7", "203.0.113.8"))
        XCTAssertTrue(AllowList.contains("198.51.100.0/24", "198.51.100.200"))
        XCTAssertFalse(AllowList.contains("198.51.100.0/24", "198.51.101.1"))
        XCTAssertTrue(AllowList.contains("10.0.0.0/8", "10.200.3.4"))
        XCTAssertTrue(AllowList.contains("0.0.0.0/0", "8.8.8.8"))
        XCTAssertTrue(AllowList.contains("2001:db8::/32", "2001:db8:1::5"))
        XCTAssertFalse(AllowList.contains("2001:db8::/32", "2001:db9::5"))
        XCTAssertFalse(AllowList.contains("203.0.113.0/24", "2001:db8::1"), "IPv4 network never contains IPv6")
    }

    func testReadsTheFirewallState() {
        let probe = """
        client=203.0.113.7
        admin=1
        os=ubuntu debian
        port=22
        ufw=active
        rule|Status: active
        rule|
        rule|To                         Action      From
        rule|--                         ------      ----
        rule|22/tcp                     ALLOW       203.0.113.7                # sigil-allow:Ev
        rule|22/tcp                     ALLOW       198.51.100.0/24            # sigil-allow:Ofis
        rule|80/tcp                     ALLOW       Anywhere
        rule|22/tcp                     ALLOW       2001:db8::1                # sigil-allow:Ev IPv6
        rule|80/tcp (v6)                ALLOW       Anywhere (v6)
        ports=22 80 443
        """
        let s = AllowList.parse(probe: probe)
        XCTAssertEqual(s.clientAddress, "203.0.113.7")
        XCTAssertEqual(s.allowed.map(\.address), ["203.0.113.7", "198.51.100.0/24", "2001:db8::1"])
        XCTAssertEqual(s.allowed.first?.label, "Ev")
        XCTAssertFalse(s.openToAll)
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.otherPorts, [80, 443])

        let open = AllowList.parse(probe: "port=22\nufw=active\nrule|22/tcp   ALLOW   Anywhere\nrule|OpenSSH   ALLOW   Anywhere\n")
        XCTAssertTrue(open.openToAll)
        XCTAssertFalse(open.isOn)
        XCTAssertTrue(AllowList.parse(probe: "port=22\nufw=inactive\n").openToAll, "no active firewall: open to all")
    }

    func testLabelsAreSafeComments() {
        XCTAssertEqual(AllowList.cleanLabel("Ev İnterneti 'x'; rm"), "Ev Interneti x rm")
        XCTAssertEqual(AllowList.cleanLabel("   "), "adres")
    }

    // MARK: Scripts, run locally with stand-ins

    private func sandbox() throws -> URL {
        let d = URL(fileURLWithPath: "/tmp/sg-allow-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A ufw that logs its arguments and says it is inactive.
    private func env(_ dir: URL, window: Int = 3) throws -> AllowList.Environment {
        let fake = dir.appendingPathComponent("ufw")
        try "#!/bin/sh\necho \"$@\" >> '\(dir.path)/ufw.log'\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let rules = dir.appendingPathComponent("user.rules")
        try "OLD RULES\n".write(to: rules, atomically: true, encoding: .utf8)
        var e = AllowList.Environment()
        e.sudoPrefix = ""
        e.ufw = fake.path
        e.rules = [rules.path]
        e.stateDir = dir.path
        e.confirmWindow = window
        e.install = "true"
        return e
    }

    private func run(_ script: String) async throws -> ShellResult {
        try await Shell.run("/bin/sh", ["-s"], stdin: script, timeout: 30)
    }

    private var state: AllowListState {
        var s = AllowListState()
        s.sshPort = 2222
        s.otherPorts = [80, 443]
        return s
    }

    func testAppliesRulesAndKeepsThemWhenConfirmed() async throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try env(dir)
        let token = "abcdef0123456789abcdef"
        let list = [AllowedAddress(address: "203.0.113.7", label: "Ev"), AllowedAddress(address: "198.51.100.0/24", label: "Ofis")]
        let r = try await run(AllowList.apply(list, state: state, token: token, env: e))
        XCTAssertTrue(r.stdout.contains("RESULT applied"), r.stdout + r.stderr)
        let c = try await run(HardeningScript.confirm(token: token, env: { var h = HardeningScript.Environment(); h.stateDir = dir.path; return h }()))
        XCTAssertTrue(c.stdout.contains("RESULT confirmed"))
        try await Task.sleep(nanoseconds: 4_500_000_000)

        let log = try String(contentsOf: dir.appendingPathComponent("ufw.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("allow from 203.0.113.7 to any port 2222 proto tcp comment sigil-allow:Ev"), log)
        XCTAssertTrue(log.contains("allow from 198.51.100.0/24 to any port 2222 proto tcp comment sigil-allow:Ofis"))
        XCTAssertTrue(log.contains("delete allow 2222/tcp"), "closed to everyone else")
        XCTAssertTrue(log.contains("allow 80/tcp") && log.contains("allow 443/tcp"), "web stays reachable when the firewall goes on")
        XCTAssertTrue(log.contains("--force enable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sigil-confirm-\(token).rolledback").path))
    }

    func testUnconfirmedRulesAreRolledBack() async throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try env(dir)
        let token = "1111222233334444aaaa"
        let r = try await run(AllowList.apply([AllowedAddress(address: "203.0.113.7", label: "Ev")], state: state, token: token, env: e))
        XCTAssertTrue(r.stdout.contains("RESULT applied"))
        try "NEW RULES\n".write(toFile: e.rules[0], atomically: true, encoding: .utf8)   // what ufw would have written

        try await Task.sleep(nanoseconds: 5_000_000_000)   // no confirmation
        XCTAssertEqual(try String(contentsOfFile: e.rules[0], encoding: .utf8), "OLD RULES\n", "previous rules restored")
        let log = try String(contentsOf: dir.appendingPathComponent("ufw.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("reload"))
        XCTAssertTrue(log.contains("--force disable"), "the firewall was off before, so it is off again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sigil-confirm-\(token).rolledback").path))
    }

    func testScriptsAreValidShell() async throws {
        for script in [AllowList.probe, AllowList.disable(state: state),
                       AllowList.apply([AllowedAddress(address: "2001:db8::/32", label: "v6")], state: state, token: "abcdef0123456789abcdef")] {
            let r = try await Shell.run("/bin/sh", ["-n", "-c", script])
            XCTAssertTrue(r.succeeded, "\(r.stderr)\n\(script)")
        }
    }

    /// Real ufw inside the Docker test server (scripts/test-server): `SIGIL_DOCKER=1 swift test --filter AllowListTests`.
    /// Backs up the firewall rules first and restores them at the end.
    func testRealUFWInTheDockerTestServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_DOCKER"] == "1", "opt-in")
        func exec(_ script: String) async throws -> ShellResult {
            try await Shell.run("/usr/local/bin/docker", ["exec", "-i", "sigil-test-server", "sh", "-s"], stdin: script, timeout: 120)
        }
        _ = try await exec("mkdir -p /root/.sigil-test-bk && cp -p /etc/ufw/user.rules /etc/ufw/user6.rules /root/.sigil-test-bk/")
        defer {
            Task { _ = try? await exec("cp -p /root/.sigil-test-bk/user.rules /root/.sigil-test-bk/user6.rules /etc/ufw/ && ufw reload >/dev/null && rm -rf /root/.sigil-test-bk") }
        }
        let before = AllowList.parse(probe: try await exec(AllowList.probe).stdout)
        XCTAssertEqual(before.ufw, "active")

        let token = "dockertest0123456789ab"
        let list = [AllowedAddress(address: "172.17.0.1", label: "Bu Mac"), AllowedAddress(address: "203.0.113.0/24", label: "Ofis ağı")]
        var env = AllowList.Environment()
        env.confirmWindow = 30
        let applied = try await exec(AllowList.apply(list, state: before, token: token, env: env))
        XCTAssertTrue(applied.stdout.contains("RESULT applied"), applied.stdout + applied.stderr)
        _ = try await exec(HardeningScript.confirm(token: token))

        let on = AllowList.parse(probe: try await exec(AllowList.probe).stdout)
        print("ufw after apply:", on.allowed, "openToAll:", on.openToAll)
        XCTAssertEqual(Set(on.allowed.map(\.address)), ["172.17.0.1", "203.0.113.0/24"])
        XCTAssertEqual(on.allowed.first { $0.address == "203.0.113.0/24" }?.label, "Ofis agi")
        XCTAssertFalse(on.openToAll, "SSH no longer open to anyone")
        XCTAssertTrue(on.isOn)
        let reach = try await Shell.run("/usr/bin/ssh-keyscan", ["-T", "5", "-p", "2222", "127.0.0.1"], timeout: 15)
        XCTAssertTrue(reach.stdout.contains("ssh-"), "this Mac (172.17.0.1 to the container) still reaches SSH")

        let off = try await exec(AllowList.disable(state: on))
        XCTAssertTrue(off.stdout.contains("RESULT opened"))
        let after = AllowList.parse(probe: try await exec(AllowList.probe).stdout)
        XCTAssertTrue(after.allowed.isEmpty)
        XCTAssertTrue(after.openToAll)
    }
}
