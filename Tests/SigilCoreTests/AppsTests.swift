import XCTest
@testable import SigilCore

final class AppsTests: XCTestCase {
    private func syntax(_ script: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await Shell.run("/bin/sh", ["-n"], stdin: script)
        XCTAssertEqual(r.exitCode, 0, r.stderr + "\n" + script, file: file, line: line)
    }

    private func plan(_ recipe: AppRecipe, _ access: AppAccess) -> AppScript.Plan {
        var secrets: [String: String] = [:]
        for n in recipe.secretNames(for: access) { secrets[n] = AppScript.secret() }
        return AppScript.Plan(recipe: recipe, access: access, port: recipe.port, domain: access == .domain ? "app.example.com" : nil,
                              secrets: secrets,
                              vars: ["BIND": access == .publicPort ? "" : "127.0.0.1:", "PORT": recipe.port.map(String.init) ?? "",
                                     "URL": "http://localhost:1", "HTTPS": "false", "DOMAIN": "", "SERVER": "web", "TZ": "UTC"])
    }

    func testEveryScriptIsValidShell() async throws {
        try await syntax(AppScript.probe)
        try await syntax(AppScript.installDocker)
        for recipe in AppCatalog.builtIn where !recipe.isDockerEngine {
            for access in recipe.access {
                let p = plan(recipe, access)
                try await syntax(AppScript.write(p))
                if let post = AppScript.postInstall(p) { try await syntax(post) }
            }
            try await syntax(AppScript.wait(recipe.id, port: recipe.port, http: recipe.http))
            for a in [AppAction.start, .stop, .restart, .update, .logs] { try await syntax(AppScript.action(recipe.id, a)) }
            try await syntax(AppScript.remove(recipe.id))
            try await syntax(AppScript.pull(recipe.id))
            try await syntax(AppScript.up(recipe.id))
            try await syntax(AppScript.openPort(recipe.id, port: 1234))
            try await syntax(AppScript.finish(AppManifest(id: recipe.id, name: recipe.name, symbol: "x", port: recipe.port, access: .tunnel,
                                                          domain: nil, http: true, dir: "", custom: false)))
        }
        try await syntax(AppScript.publish("dozzle", domain: "logs.example.com", port: 8090, password: "abc"))
        try await syntax(AppScript.publish("grafana", domain: "g.example.com", port: 3000, password: nil))
    }

    func testCatalogIsConsistent() {
        var ids = Set<String>()
        for r in AppCatalog.builtIn {
            XCTAssertTrue(ids.insert(r.id).inserted, "duplicate \(r.id)")
            XCTAssertTrue(AppScript.isValidID(r.id), r.id)
            XCTAssertFalse(r.access.isEmpty, r.id)
            if r.isDockerEngine { continue }
            XCTAssertTrue(r.compose.contains("services:"), r.id)
            XCTAssertTrue(r.compose.contains("container_name: sigil-"), r.id)
            if r.port != nil { XCTAssertTrue(r.compose.contains("\"{{BIND}}{{PORT}}:"), "\(r.id) publishes its port through BIND") }
            // Every secret is used, and every placeholder in the info lines is known.
            for s in r.secrets {
                XCTAssertTrue(r.compose.contains("${\(s)}") || r.files.values.contains { $0.contains("{{\(s)}}") }
                              || (r.postInstall ?? "").contains("$\(s)"), "\(r.id): \(s) unused")
            }
            for line in r.info {
                let names = line.components(separatedBy: "{{").dropFirst().compactMap { $0.components(separatedBy: "}}").first }
                for n in names { XCTAssertTrue(r.secrets.contains(n) || ["ADDRESS", "URL"].contains(n), "\(r.id): {{\(n)}}") }
            }
            if !r.ownLogin { XCTAssertFalse(r.access.contains(.publicPort), "\(r.id) has no login: never on a public port") }
            for path in r.files.keys { XCTAssertTrue(AppScript.isValidFilePath(path), path) }
        }
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(AppCatalog.serverDashboard.utf8)), "dashboard is valid JSON")
    }

    func testFillKeepsForeignPlaceholders() {
        let out = AppScript.fill(#"- "{{BIND}}{{PORT}}:80" legend {{mountpoint}} {{.State}}"#, ["BIND": "127.0.0.1:", "PORT": "8080"])
        XCTAssertEqual(out, #"- "127.0.0.1:8080:80" legend {{mountpoint}} {{.State}}"#)
    }

    func testWriteKeepsSecretsOffCommandLinesAndPrivate() {
        let r = AppCatalog.builtIn.first { $0.id == "portainer" }!
        let p = plan(r, .tunnel)
        let pw = p.secrets["ADMIN_PASSWORD"]!
        let s = AppScript.write(p)
        XCTAssertTrue(s.contains("ADMIN_PASSWORD=\(pw)"), ".env holds it")
        XCTAssertTrue(s.contains("(umask 077; printf '%s' '\(pw)' | $S tee \"$DIR/admin_password\""), "password file without newline, 0600")
        XCTAssertTrue(s.contains("$S chmod 600 \"$DIR/.env\""))
        XCTAssertTrue(s.contains("\"127.0.0.1:9000:9000\""), "tunnel mode binds to loopback")
        XCTAssertFalse(s.contains("{{"), "no unfilled placeholder")
        let open = AppScript.write(plan(r, .publicPort))
        XCTAssertTrue(open.contains("\"9000:9000\""))
    }

    func testProbeParsing() {
        let text = """
        admin=1
        os=ubuntu debian
        arch=x86_64
        mem=3936 2100
        disk=40213
        docker=ok
        compose=plugin
        ports=22 80 3000 5432
        ufw=active
        app={"access":"tunnel","custom":false,"dir":"/opt/sigil/apps/grafana","http":true,"id":"grafana","installedAt":"2026-10-18T10:00:00Z","name":"Grafana + Prometheus","port":3000,"symbol":"chart.xyaxis.line"}
        app={"access":"tunnel","id":"../evil","name":"x","symbol":"x","http":true,"installedAt":"2026-10-18T10:00:00Z","dir":"","custom":false}
        app=garbage
        ctr=sigil-grafana running
        ctr=sigil-grafana running
        ctr=sigil-grafana exited
        ctr=sigil-other running
        """
        let s = AppScript.parse(probe: text)
        XCTAssertTrue(s.admin)
        XCTAssertTrue(s.dockerReady)
        XCTAssertTrue(s.ufwActive)
        XCTAssertEqual(s.memoryTotalMB, 3936)
        XCTAssertEqual(s.listening, [22, 80, 3000, 5432])
        XCTAssertEqual(s.apps.map(\.id), ["grafana"], "invalid ids and junk are dropped")
        XCTAssertEqual(s.apps.first?.running, 2)
        XCTAssertEqual(s.apps.first?.total, 3)
        XCTAssertFalse(s.apps.first!.isRunning)
        XCTAssertEqual(s.freePort(near: 3000), 3001)
        XCTAssertEqual(s.freePort(near: 5432), 5433)
        XCTAssertEqual(s.freePort(near: 9000), 9000)

        var missing = AppHostState()
        missing.docker = "ok"
        XCTAssertFalse(missing.dockerReady, "compose is needed too")
    }

    func testCustomRecipe() throws {
        let r = try AppRecipe.custom(name: "Benim Uygulamam!", compose: "services:\n  web:\n    image: nginx\n    ports: [\"{{BIND}}{{PORT}}:80\"]\n",
                                     port: 8088, http: true, ownLogin: false, secrets: "DB_PASSWORD, API_KEY DB_PASSWORD")
        XCTAssertEqual(r.id, "custom-benim-uygulamam")
        XCTAssertEqual(r.secrets, ["DB_PASSWORD", "API_KEY"])
        XCTAssertEqual(r.access, [.tunnel, .domain], "no own login: not on a public port")
        XCTAssertEqual(r.secretNames(for: .domain), ["DB_PASSWORD", "API_KEY", "PROXY_PASSWORD"])
        XCTAssertThrowsError(try AppRecipe.custom(name: "x", compose: "hello", port: nil, http: true, ownLogin: true, secrets: ""))
        XCTAssertThrowsError(try AppRecipe.custom(name: "x", compose: "services:", port: nil, http: true, ownLogin: true, secrets: "bad-name"))
        XCTAssertThrowsError(try AppRecipe.custom(name: "!!!", compose: "services:", port: nil, http: true, ownLogin: true, secrets: ""))
        XCTAssertEqual(try AppRecipe.custom(name: "Şık İş", compose: "services:", port: nil, http: true, ownLogin: true, secrets: "").id, "custom-sik-is")
    }

    @MainActor
    func testCustomRecipesPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = DeckPaths(sshDir: dir.appendingPathComponent("ssh"), supportDir: dir.appendingPathComponent("support"))
        let model = DeckModel(paths: paths, hardened: false)
        let r = try AppRecipe.custom(name: "Notlar", compose: "services:\n  a:\n    image: x\n", port: nil, http: true, ownLogin: true, secrets: "")
        try model.saveRecipe(r)
        let again = DeckModel(paths: paths, hardened: false)
        again.load()
        XCTAssertEqual(again.customRecipes.map(\.id), ["custom-notlar"])
        XCTAssertNotNil(again.recipe("custom-notlar"))
        try again.deleteRecipe("custom-notlar")
        XCTAssertTrue(again.customRecipes.isEmpty)
    }

    func testDomainValidation() throws {
        XCTAssertEqual(try AppScript.validateDomain(" https://Grafana.Example.com/ "), "grafana.example.com")
        for bad in ["", "localhost", "a b.com", "x.com; rm -rf /", "-a.com", "a..com", "{x}.com"] {
            XCTAssertThrowsError(try AppScript.validateDomain(bad), bad)
        }
    }

    func testSecretsAreRandomAndPlain() {
        let a = AppScript.secret(), b = AppScript.secret()
        XCTAssertEqual(a.count, 24)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber }, "safe in .env and shell quotes")
    }

    func testResultParsing() {
        XCTAssertEqual(AppScript.result("pulling…\nRESULT rc=0\n"), "rc=0")
        XCTAssertEqual(AppScript.result("RESULT removed /opt/sigil/apps/.removed/dozzle-1"), "removed /opt/sigil/apps/.removed/dozzle-1")
        XCTAssertEqual(AppScript.result("nothing"), "")
    }

    /// Real installs inside the Docker test server (scripts/test-server, Docker in Docker):
    /// `SIGIL_DOCKER=1 swift test --filter AppsTests`. Installs compose if missing, then Dozzle and Redis, then removes them.
    func testRealInstallInTheDockerTestServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_DOCKER"] == "1", "opt-in")
        func exec(_ script: String, timeout: TimeInterval = 600) async throws -> String {
            let r = try await Shell.run("/usr/local/bin/docker", ["exec", "-i", "sigil-test-server", "sh", "-s"], stdin: script, timeout: timeout)
            return r.stdout + r.stderr
        }
        let docker = try await exec(AppScript.installDocker, timeout: 900)
        XCTAssertEqual(AppScript.result(docker), "ok", docker)
        var state = AppScript.parse(probe: try await exec(AppScript.probe))
        XCTAssertTrue(state.dockerReady, "\(state)")

        for id in ["dozzle", "redis"] {
            let recipe = AppCatalog.builtIn.first { $0.id == id }!
            if state.apps.contains(where: { $0.id == id }) { _ = try await exec(AppScript.remove(id)) }
            let port = state.freePort(near: recipe.port!)
            var p = plan(recipe, .tunnel)
            p.port = port
            p.vars["PORT"] = String(port)
            let out1 = try await exec(AppScript.write(p))
            XCTAssertEqual(AppScript.result(out1), "written")
            let pulled = try await exec(AppScript.pull(id), timeout: 900)
            XCTAssertEqual(AppScript.result(pulled), "rc=0", pulled)
            let up = try await exec(AppScript.up(id))
            XCTAssertEqual(AppScript.result(up), "rc=0", up)
            let waited = try await exec(AppScript.wait(id, port: port, http: recipe.http))
            XCTAssertEqual(AppScript.result(waited), "ready", waited)
            let m = AppManifest(id: id, name: recipe.name, symbol: recipe.symbol, port: port, access: .tunnel, domain: nil, http: recipe.http,
                                dir: "", custom: false)
            let out2 = try await exec(AppScript.finish(m))
            XCTAssertEqual(AppScript.result(out2), "finished")
            let out3 = try await exec(AppScript.write(p))
            XCTAssertEqual(AppScript.result(out3), "exists", "never overwrites an installed app")

            state = AppScript.parse(probe: try await exec(AppScript.probe))
            let app = try XCTUnwrap(state.apps.first { $0.id == id })
            XCTAssertTrue(app.isRunning)
            XCTAssertEqual(app.manifest.dir, "/opt/sigil/apps/\(id)")
            let out4 = try await exec("ss -Htln | awk '{print $4}'")
            XCTAssertTrue(out4.contains("127.0.0.1:\(port)"), "bound to loopback only")
            let out5 = try await exec("stat -c %a /opt/sigil/apps/\(id)/.env")
            XCTAssertTrue(out5.hasPrefix("600"))
            if id == "redis" {
                let pw = p.secrets["REDIS_PASSWORD"]!
                let pong = try await exec("docker exec sigil-redis redis-cli -a \(pw) --no-auth-warning ping")
                XCTAssertTrue(pong.contains("PONG"), pong)
            }
            let out6 = try await exec(AppScript.action(id, .restart))
            XCTAssertEqual(AppScript.result(out6), "rc=0")
            let out7 = try await exec(AppScript.action(id, .logs))
            XCTAssertTrue(out7.contains("RESULT rc=0"))

            // nginx holds port 80 in the test server: a domain must be refused before anything changes.
            if id == "dozzle" {
                let out8 = try await exec(AppScript.publish(id, domain: "logs.example.com", port: port, password: "pw"))
                XCTAssertEqual(AppScript.result(out8), "webports")
            }

            let removed = try await exec(AppScript.remove(id))
            XCTAssertTrue(AppScript.result(removed).hasPrefix("removed /opt/sigil/apps/.removed/\(id)-"), removed)
            state = AppScript.parse(probe: try await exec(AppScript.probe))
            XCTAssertFalse(state.apps.contains { $0.id == id })
        }
    }
}
