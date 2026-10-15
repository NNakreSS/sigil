import XCTest
@testable import SigilCore

final class CommandLibraryTests: XCTestCase {
    func testPlaceholdersFillAndPrefix() {
        let c = CommandTemplate("x", "sudo du -xh --max-depth=1 {{klasör=/}} | head -{{n}} && echo {{klasör}}", .disk)
        XCTAssertEqual(c.parameters, [.init(name: "klasör", defaultValue: "/"), .init(name: "n", defaultValue: nil)])
        XCTAssertEqual(c.filled(["n": "20"]), "sudo du -xh --max-depth=1 / | head -20 && echo /")
        XCTAssertEqual(c.filled(["klasör": "/var", "n": "5"]), "sudo du -xh --max-depth=1 /var | head -5 && echo /var")
        XCTAssertEqual(c.typedPrefix, "sudo du -xh --max-depth=1 ")
        XCTAssertEqual(CommandTemplate("y", "df -h", .disk).typedPrefix, "df -h")
    }

    /// find's own `{}` is not a placeholder.
    func testFindBracesAreLeftAlone() {
        let c = CommandLibrary.all.first { $0.template.contains("-exec ls -lh {} +") }!
        XCTAssertEqual(c.parameters.map(\.name), ["klasör"])
        XCTAssertTrue(c.filled([:]).contains("-exec ls -lh {} +"))
    }

    func testEveryCommandIsValidShellOnceFilled() async throws {
        for c in CommandLibrary.all {
            let values = Dictionary(uniqueKeysWithValues: c.parameters.map { ($0.name, $0.defaultValue ?? "x") })
            let r = try await Shell.run("/bin/sh", ["-n", "-c", c.filled(values)])
            XCTAssertTrue(r.succeeded, "\(c.title): \(c.filled(values))\n\(r.stderr)")
        }
    }

    func testIDsAreUniqueAndTitlesPresent() {
        let ids = CommandLibrary.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate commands in a category")
        XCTAssertTrue(CommandLibrary.all.allSatisfy { !$0.title.isEmpty })
        XCTAssertGreaterThan(CommandLibrary.all.count, 100)
    }

    func testProfileFiltersByToolsAndFamily() {
        let ubuntu = ServerProfile(family: .debian, tools: ["apt", "nginx", "git"])
        let rel = CommandLibrary.relevant(for: ubuntu)
        XCTAssertTrue(rel.contains { $0.template == "sudo nginx -t" })
        XCTAssertFalse(rel.contains { $0.category == .docker }, "no docker on this server")
        XCTAssertFalse(rel.contains { $0.template.hasPrefix("dnf") })
        XCTAssertFalse(rel.contains { $0.template == "getent group wheel" })
        XCTAssertTrue(rel.contains { $0.template == "getent group sudo" })
        XCTAssertEqual(CommandLibrary.relevant(for: nil).count, CommandLibrary.all.count, "unknown server: show all")
    }

    func testSearchRanksCommandPrefixFirst() {
        let hits = CommandLibrary.search("docker ps", in: CommandLibrary.all)
        XCTAssertEqual(hits.first?.template, "docker ps")
        XCTAssertTrue(CommandLibrary.search("güvenlik duvarı", in: CommandLibrary.all).contains { $0.template.contains("ufw status") })
    }

    func testHealthReportsProfile() {
        let h = HealthScript.parse("osid=ubuntu debian\ntool=apt\ntool=nginx\ntool=docker\n")
        let p = ServerProfile(h)
        XCTAssertEqual(p?.family, .debian)
        XCTAssertEqual(p?.tools, ["apt", "nginx", "docker"])
        XCTAssertNil(ServerProfile(HealthScript.parse("os=Darwin\n")), "an older measurement without tools: unknown")
        XCTAssertTrue(HealthScript.source.contains("for t in docker nginx"))
    }
}

final class CommandCompletionTests: XCTestCase {
    func testReadsTheInputAfterThePrompt() {
        XCTAssertEqual(CommandCompletion.typedInput(beforeCursor: "root@sahin:~# docker p", afterCursor: "   "), "docker p")
        XCTAssertEqual(CommandCompletion.typedInput(beforeCursor: "deploy@web:/srv$ sys", afterCursor: ""), "sys")
        XCTAssertNil(CommandCompletion.typedInput(beforeCursor: "root@sahin:~# ", afterCursor: ""), "nothing typed")
        XCTAssertNil(CommandCompletion.typedInput(beforeCursor: "root@sahin:~# doc", afterCursor: "ker ps"), "cursor mid-line")
        XCTAssertNil(CommandCompletion.typedInput(beforeCursor: "Loading... 45%", afterCursor: ""), "not a prompt")
    }

    func testCompletesToTheShortestFittingCommandUpToItsFirstBlank() {
        let c = CommandCompletion.candidates(saved: [QuickAction(name: "Deploy", command: "docker compose up -d --build")],
                                             profile: ServerProfile(family: .debian, tools: ["docker", "apt"]))
        XCTAssertEqual(CommandCompletion.best(for: "docker p", in: c)?.text, "docker ps")
        XCTAssertEqual(CommandCompletion.best(for: "docker compose up", in: c)?.text, "docker compose up -d")
        XCTAssertEqual(CommandCompletion.best(for: "journalctl -u", in: c)?.text, "journalctl -u ", "stops at ‹servis›")
        XCTAssertNil(CommandCompletion.best(for: "d", in: c), "one letter is too little")
        XCTAssertNil(CommandCompletion.best(for: "docker ps", in: c.filter { $0.text == "docker ps" }), "already complete")
        XCTAssertNil(CommandCompletion.best(for: "nginx -t", in: c), "nginx is not on this server")
    }
}
