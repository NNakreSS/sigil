import XCTest
@testable import SigilCore

/// Runs the generated hardening scripts locally with harmless stand-ins for sudo/sshd/ufw, to prove the
/// dead-man switch: confirmed changes stay, unconfirmed ones are rolled back, invalid sshd config is never applied.
final class HardeningScriptTests: XCTestCase {
    private func env(_ dir: URL, sshdValid: Bool = true, window: Int = 3) -> HardeningScript.Environment {
        var e = HardeningScript.Environment()
        e.sudoPrefix = ""
        e.dropInPath = dir.appendingPathComponent("00-sigil-hardening.conf").path
        e.sshdTest = sshdValid ? "true" : "false"
        e.sshdReload = "true"
        e.ufw = "true"
        e.stateDir = dir.path
        e.confirmWindow = window
        return e
    }

    private func run(_ script: String) async throws -> ShellResult {
        try await Shell.run("/bin/sh", ["-s"], stdin: script, timeout: 30)
    }

    private var plan: HardeningPlan {
        var p = HardeningPlan()
        p.disablePasswordLogin = true
        p.restrictRootLogin = true
        return p
    }

    private func sandbox() throws -> URL {
        let d = URL(fileURLWithPath: "/tmp/sg-hard-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testConfirmedChangeStays() async throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = env(dir)
        var state = HardeningState(); state.isRoot = true
        let token = "abcdef0123456789abcdef"
        let r = try await run(HardeningScript.apply(plan, state: state, token: token, env: e))
        XCTAssertTrue(r.stdout.contains("RESULT applied"), r.stdout + r.stderr)

        let c = try await run(HardeningScript.confirm(token: token, env: e))
        XCTAssertTrue(c.stdout.contains("RESULT confirmed"))
        try await Task.sleep(nanoseconds: 4_500_000_000)

        let dropIn = try String(contentsOfFile: e.dropInPath, encoding: .utf8)
        XCTAssertTrue(dropIn.contains("PasswordAuthentication no"))
        XCTAssertTrue(dropIn.contains("PermitRootLogin prohibit-password"), "root keeps key login when Sigil logs in as root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sigil-confirm-\(token).rolledback").path))
    }

    func testUnconfirmedChangeIsRolledBack() async throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = env(dir)
        var state = HardeningState(); state.isRoot = false
        let token = "1111222233334444aaaa"
        let r = try await run(HardeningScript.apply(plan, state: state, token: token, env: e))
        XCTAssertTrue(r.stdout.contains("RESULT applied"))
        XCTAssertTrue(try String(contentsOfFile: e.dropInPath, encoding: .utf8).contains("PermitRootLogin no"))

        try await Task.sleep(nanoseconds: 5_000_000_000)   // no confirmation
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.dropInPath), "drop-in removed by the watchdog")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sigil-confirm-\(token).rolledback").path))
    }

    func testRollbackRestoresAPreviousDropIn() async throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = env(dir)
        try "PasswordAuthentication yes\n# user's own\n".write(toFile: e.dropInPath, atomically: true, encoding: .utf8)
        let token = "5555666677778888bbbb"
        _ = try await run(HardeningScript.apply(plan, state: HardeningState(), token: token, env: e))
        try await Task.sleep(nanoseconds: 5_000_000_000)
        XCTAssertEqual(try String(contentsOfFile: e.dropInPath, encoding: .utf8), "PasswordAuthentication yes\n# user's own\n")
    }

    func testInvalidSSHDConfigIsNeverApplied() async throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = env(dir, sshdValid: false)
        let r = try await run(HardeningScript.apply(plan, state: HardeningState(), token: "9999aaaabbbbccccdddd", env: e))
        XCTAssertTrue(r.stdout.contains("RESULT sshd_invalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.dropInPath))
    }

    func testProbeParsing() {
        let s = HardeningScript.parseProbe("""
        user=root
        root=1
        admin=1
        os=ubuntu
        include=1
        passwordauthentication=yes
        kbdinteractiveauthentication=no
        permitrootlogin=yes
        port=22
        ufw=inactive
        f2b=missing
        uu=active
        ports=22 80 443
        """)
        XCTAssertTrue(s.isRoot && s.canAdminister && s.isDebianLike && s.sshdIncludesDropIns)
        XCTAssertTrue(s.passwordLoginOpen)
        XCTAssertTrue(s.rootPasswordLoginOpen)
        XCTAssertEqual(s.listeningPorts, [22, 80, 443])
        XCTAssertEqual(s.ufw, "inactive")
    }
}
