import XCTest
@testable import SigilCore

final class MaintenanceTests: XCTestCase {
    func testParsesAptListAndPutsSecurityFirst() {
        let out = """
        curl/noble-updates 8.5.0-2ubuntu10.7 amd64 [upgradable from: 8.5.0-2ubuntu10.6]
        libarchive13t64/noble-security 3.7.2-2ubuntu0.9 amd64 [upgradable from: 3.7.2-2ubuntu0.8]
        linux-generic/noble-updates,noble-security 6.8.0-146.146 amd64 [upgradable from: 6.8.0-79.79]
        garbage line
        """
        let p = MaintenanceScript.parseUpgradable(out)
        XCTAssertEqual(p.map(\.name), ["libarchive13t64", "linux-generic", "curl"])
        XCTAssertEqual(p.map(\.security), [true, true, false])
        XCTAssertEqual(p.first?.version, "3.7.2-2ubuntu0.9")
    }

    /// The scripts are only ever run on servers (never here: the reboot one would restart this Mac if it had
    /// password-less sudo), so at least make sure /bin/sh accepts them.
    func testScriptsAreValidShell() async throws {
        for script in [MaintenanceScript.preview, MaintenanceScript.reboot, MaintenanceScript.updateCommand] {
            let r = try await Shell.run("/bin/sh", ["-n", "-c", script])
            XCTAssertTrue(r.succeeded, "\(r.stderr)\n\(script)")
        }
    }

    func testUpdateCommandEndsInALoginShellAndNeverPrompts() {
        let c = MaintenanceScript.updateCommand
        XCTAssertTrue(c.contains("DEBIAN_FRONTEND=noninteractive"))
        XCTAssertTrue(c.contains("--force-confold"), "keep the server's own config files")
        XCTAssertTrue(c.contains("--with-new-pkgs"), "kernel updates need new packages")
        XCTAssertTrue(c.hasSuffix(#"exec "${SHELL:-/bin/sh}" -l"#))
        XCTAssertFalse(c.contains("'"), "passed as one ssh argument; no single quotes")
    }
}
