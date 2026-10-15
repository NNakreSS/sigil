import XCTest
@testable import SigilCore

final class AssistantTests: XCTestCase {
    func testFindsTheProgramsOfEachStage() {
        XCTAssertEqual(CommandCheck.programs(in: "sudo ss -tlnp | grep :80"), ["ss", "grep"])
        XCTAssertEqual(CommandCheck.programs(in: "journalctl -u nginx --since '1 hour ago' 2>&1 | grep -E 'error|crit'"), ["journalctl", "grep"])
        XCTAssertEqual(CommandCheck.programs(in: "DEBIAN_FRONTEND=noninteractive sudo apt-get -y upgrade"), ["apt-get"])
        XCTAssertEqual(CommandCheck.programs(in: "getent passwd | awk -F: '$3>=1000 {print $1}'"), ["getent", "awk"])
    }

    func testWarnsAboutInventedProgramsAndBrokenSyntax() async {
        let w1 = await CommandCheck.warnings(for: "nginx-access-log -t 1h", profile: nil)
        XCTAssertTrue(w1.contains { $0.contains("nginx-access-log") })
        let w2 = await CommandCheck.warnings(for: "ls -la | grep 'x", profile: nil)
        XCTAssertTrue(w2.contains { $0.contains("sözdizimi") })
        let ok = await CommandCheck.warnings(for: "sudo du -xh --max-depth=1 / | sort -rh | head -10", profile: nil)
        XCTAssertEqual(ok, [])
        let blank = await CommandCheck.warnings(for: "docker logs -f <container>", profile: ServerProfile(family: .debian, tools: ["docker"]))
        XCTAssertTrue(blank.contains { $0.contains("doldurman") })
    }

    func testGivesTheModelTheClosestLibraryCommands() {
        let ctx = AssistantContext(os: "Ubuntu 24.04.5 LTS", profile: ServerProfile(family: .debian, tools: ["nginx", "docker", "apt"]))
        let ex = AssistantPrompt.examples(for: "nginx hatalarını göster", context: ctx)
        XCTAssertTrue(ex.contains { $0.template.contains("/var/log/nginx/error.log") })
        let prompt = AssistantPrompt.suggestPrompt("80 portunu kim kullanıyor", context: ctx)
        XCTAssertTrue(prompt.contains("Ubuntu 24.04.5 LTS"))
        XCTAssertTrue(prompt.contains("ss -tlnp | grep :<port>"))
        XCTAssertFalse(prompt.contains("{{"), "blanks are shown as <name>")
    }

    func testParsesClaudesJSONAnswer() throws {
        let body = #"{"content":[{"type":"text","text":"Tamam:\n{\"command\": \"sudo ss -tlnp | grep :80\", \"explanation\": \"80 portunu dinleyen işlemi gösterir.\", \"changes_system\": false}"}]}"#
        let a = try ClaudeAssistant.parse(Data(body.utf8))
        XCTAssertEqual(a.command, "sudo ss -tlnp | grep :80")
        XCTAssertFalse(a.changesSystem)
        XCTAssertThrowsError(try ClaudeAssistant.parse(Data(#"{"content":[{"text":"no json"}]}"#.utf8)))
    }

    /// Runs Apple's on-device model for real (no network): `SIGIL_FM=1 swift test --filter AssistantTests`.
    func testOnDeviceModelSuggestsSomethingCheckable() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_FM"] == "1", "opt-in")
        try XCTSkipUnless(AssistantProvider.onDeviceAvailable, "Apple Intelligence off")
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let ctx = AssistantContext(os: "Ubuntu 24.04.5 LTS", profile: ServerProfile(family: .debian, tools: ["nginx", "apt"]))
            let a = try await OnDeviceAssistant().suggest("80 portunu hangi işlem kullanıyor", context: ctx)
            print("on-device:", a.command, "|", a.explanation, "|", a.warnings)
            XCTAssertFalse(a.command.isEmpty)
            XCTAssertFalse(a.explanation.isEmpty)
        }
        #endif
    }
}
