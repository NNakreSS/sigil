import XCTest
@testable import SigilCore

@MainActor
final class TunnelTests: XCTestCase {
    func testForwardReachesTheServerSideAndStops() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        let (d, keys) = try await model.scanHostKeys(for: ServerDraft(alias: "tun", host: "127.0.0.1", port: sshd.port, user: NSUserName()))
        let s = try await model.addServer(draft: d, password: "x", hostKeys: keys)

        // Forward a local port to the sshd itself (as seen from the server): reading it should give an SSH banner.
        let local = Int.random(in: 61000...63000)
        let t = TunnelProfile(name: "sshd loop", localPort: local, remoteHost: "127.0.0.1", remotePort: sshd.port)
        try model.saveTunnel(s.id, t)
        try await model.startTunnel(s.id, t.id)
        XCTAssertNotNil(model.activeTunnels[t.id])

        let banner = try await Shell.run("/usr/bin/nc", ["-w", "2", "127.0.0.1", String(local)], stdin: "", timeout: 10)
        XCTAssertTrue(banner.stdout.hasPrefix("SSH-2.0"), "got: \(banner.stdout)")

        model.stopTunnel(t.id)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(model.activeTunnels[t.id])
        XCTAssertFalse(RemoteService.isListening(port: local))
    }

    func testValidationAndPortClash() throws {
        XCTAssertThrowsError(try TunnelProfile(name: "x", localPort: 80, remotePort: 80).validated(), "privileged local port")
        XCTAssertThrowsError(try TunnelProfile(name: "", localPort: 5000, remotePort: 80).validated())
        XCTAssertThrowsError(try TunnelProfile(name: "x", localPort: 5000, remoteHost: "-oProxyCommand=x", remotePort: 80).validated())
    }
}
