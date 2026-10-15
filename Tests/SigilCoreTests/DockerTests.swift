import XCTest
@testable import SigilCore

final class DockerTests: XCTestCase {
    func testParsesPsAndStatsAndGroupsByProject() {
        let out = """
        {"ID":"aaaaaaaaaaaa1111","Image":"nginx:1.27","Labels":"com.docker.compose.project=shop,com.docker.compose.service=web","Names":"shop-web-1","Ports":"0.0.0.0:80->80/tcp","State":"running","Status":"Up 2 hours"}
        {"ID":"bbbbbbbbbbbb2222","Image":"redis:7","Labels":"","Names":"cache","Ports":"","State":"exited","Status":"Exited (0) 3 days ago"}
        --stats--
        {"CPUPerc":"0.12%","MemUsage":"12.5MiB / 1.9GiB","Name":"shop-web-1"}
        """
        let c = DockerScript.parse(out)
        XCTAssertEqual(c.map(\.name), ["shop-web-1", "cache"])
        XCTAssertEqual(c[0].project, "shop")
        XCTAssertEqual(c[0].id, "aaaaaaaaaaaa")
        XCTAssertTrue(c[0].isRunning)
        XCTAssertEqual(c[0].cpu, "0.12%")
        XCTAssertNil(c[1].project)
        XCTAssertFalse(c[1].isRunning)
    }

    func testNamesAreValidatedAndScriptsAreShell() async throws {
        XCTAssertThrowsError(try DockerScript.checkName("web; rm -rf /"))
        XCTAssertThrowsError(try DockerScript.checkName("-rm"))
        XCTAssertEqual(try DockerScript.checkName("shop-web-1"), "shop-web-1")
        for s in [DockerScript.list, DockerScript.action("restart", "shop-web-1"), DockerScript.logs("cache")] {
            let r = try await Shell.run("/bin/sh", ["-n", "-c", s])
            XCTAssertTrue(r.succeeded, "\(r.stderr)\n\(s)")
        }
    }
}
