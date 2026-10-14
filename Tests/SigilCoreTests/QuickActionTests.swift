import XCTest
@testable import SigilCore

@MainActor
final class QuickActionTests: XCTestCase {
    func testRunsOnSeveralServersAndPersistsActions() async throws {
        let box = try Sandbox()
        let sshd = try LocalSSHD(sandbox: box)
        let model = DeckModel(paths: box.paths, hardened: false, authorizedKeysPath: sshd.authorizedKeys.path)
        model.initialAuthOverride = .key(fileName: sshd.bootstrapKeyName)
        model.load()
        XCTAssertEqual(model.actions.count, QuickAction.defaults.count, "defaults on first run")

        var ids: [UUID] = []
        for alias in ["one", "two"] {
            let (d, k) = try await model.scanHostKeys(for: ServerDraft(alias: alias, host: "127.0.0.1", port: sshd.port, user: NSUserName()))
            ids.append(try await model.addServer(draft: d, password: "x", hostKeys: k).id)
        }

        let action = QuickAction(name: "Merhaba", command: "echo sigil-$((20+22)); echo err >&2; exit 3")
        try model.saveAction(action)
        var streamed = 0
        let results = await model.run(action, on: ids) { _ in streamed += 1 }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(streamed, 2)
        XCTAssertTrue(results.allSatisfy { $0.output.contains("sigil-42") && $0.errorOutput.contains("err") && $0.exitCode == 3 })

        let reloaded = DeckModel(paths: box.paths, hardened: false)
        reloaded.load()
        XCTAssertTrue(reloaded.actions.contains { $0.name == "Merhaba" })
        XCTAssertThrowsError(try model.saveAction(QuickAction(name: "", command: "x")))
    }
}
