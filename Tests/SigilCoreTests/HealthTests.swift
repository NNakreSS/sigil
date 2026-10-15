import XCTest
@testable import SigilCore

final class HealthParseTests: XCTestCase {
    func testParsesUbuntuLikeOutput() {
        let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        let out = """
        os=Ubuntu 24.04.5 LTS
        uptime=527400.12
        load=0.07 0.05 0.01
        cpus=1
        mem=984064 630784
        disk=30842304 4614144
        updates=33 13
        reboot=1
        failed=2
        failedunit=fwupd.service|Firmware update daemon
        failedunit=broken.service|
        rebootpkg=libc6
        rebootpkg=apparmor
        secpkg=libarchive13t64
        secpkg=linux-image-generic
        cert=example.com|Jan  6 14:10:17 2027 GMT
        cert=old.example|Oct 20 00:00:00 2026 GMT
        """
        let h = HealthScript.parse(out, now: now)
        XCTAssertEqual(h.os, "Ubuntu 24.04.5 LTS")
        XCTAssertEqual(h.load, [0.07, 0.05, 0.01])
        XCTAssertEqual(h.cpus, 1)
        XCTAssertEqual(h.updates, 33)
        XCTAssertEqual(h.securityUpdates, 13)
        XCTAssertEqual(h.rebootRequired, true)
        XCTAssertEqual(h.failedUnits, 2)
        XCTAssertEqual(h.failedUnitList, [.init(name: "fwupd.service", description: "Firmware update daemon"),
                                          .init(name: "broken.service", description: "")])
        XCTAssertEqual(h.rebootPackages, ["libc6", "apparmor"])
        XCTAssertEqual(h.securityPackages, ["libarchive13t64", "linux-image-generic"])
        XCTAssertEqual(h.certificates.count, 2)
        XCTAssertEqual(h.daysLeft(h.certificates[0], now: now), 84)
        XCTAssertEqual(Int((h.diskUsage! * 100).rounded()), 15)
        XCTAssertEqual(Int((h.memoryUsage! * 100).rounded()), 36)
        let problems = h.problems(now: now)
        XCTAssertTrue(problems.contains("Yeniden başlatma gerekiyor"))
        XCTAssertTrue(problems.contains("13 güvenlik güncellemesi bekliyor"))
        XCTAssertTrue(problems.contains("Çalışmayan servis: fwupd.service, broken.service"))
        XCTAssertTrue(problems.contains { $0.hasPrefix("old.example sertifikası 5 gün") })
        XCTAssertFalse(problems.contains { $0.hasPrefix("Disk") })
    }

    func testToleratesMissingTools() {
        let h = HealthScript.parse("os=Darwin 25.6.0\ndisk=100 95\nreboot=0\n")
        XCTAssertNil(h.load)
        XCTAssertNil(h.memoryUsage)
        XCTAssertEqual(h.problems(), ["Disk %95 dolu"])
    }
}

@MainActor
final class HealthFlowTests: XCTestCase {
    func testCollectsOverSSHAndNotifiesOncePerProblem() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let (d, keys) = try await model.scanHostKeys(for: ServerDraft(alias: "health", host: "127.0.0.1", port: sshd.port, user: NSUserName()))
        let s = try await model.addServer(draft: d, password: "x", hostKeys: keys)

        let h = try await model.collectHealth(s.id)
        XCTAssertNotNil(h?.os, "the script ran remotely")
        XCTAssertNotNil(h?.diskUsage, "df works everywhere")
        _ = try await model.collectHealth(s.id)
        XCTAssertEqual(model.server(s.id)?.healthHistory?.count, 2)
    }
}
