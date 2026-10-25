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
        var vars = ["BIND": access.listensOutside ? "" : "127.0.0.1:", "ADDR": access.listensOutside ? "" : "127.0.0.1",
                    "PORT": recipe.port.map(String.init) ?? "",
                    "URL": "http://localhost:1", "HTTPS": "false", "DOMAIN": "", "SERVER": "web", "TZ": "UTC"]
        for input in recipe.inputs ?? [] { vars[input.name] = input.defaultValue }
        return AppScript.Plan(recipe: recipe, access: access, port: recipe.port, domain: access == .domain ? "app.example.com" : nil,
                              secrets: secrets, vars: vars)
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
            try await syntax(AppScript.allowFrom(recipe.id, port: 1234, addresses: ["203.0.113.7", "2001:db8::/32"]))
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
            if r.port != nil {
                let hostNet = r.compose.contains("network_mode: host")
                XCTAssertTrue(hostNet ? r.compose.contains("{{ADDR}}") && r.compose.contains("{{PORT}}") : r.compose.contains("\"{{BIND}}{{PORT}}:"),
                              "\(r.id) publishes its port through BIND (on the host network: listens on ADDR)")
            }
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
            // Docker-published ports bypass ufw, so only a host-networked app can be limited to addresses.
            if r.access.contains(.allowList) { XCTAssertTrue(r.compose.contains("network_mode: host"), "\(r.id): allowList needs the host network") }
            for input in r.inputs ?? [] {
                XCTAssertTrue(AppScript.isValidSecretName(input.name), "\(r.id): \(input.name)")
                XCTAssertFalse(["BIND", "ADDR", "PORT", "URL", "HTTPS", "DOMAIN", "SERVER", "TZ"].contains(input.name) || r.secrets.contains(input.name),
                               "\(r.id): \(input.name) shadows another value")
                XCTAssertTrue(r.compose.contains("{{\(input.name)}}") || r.files.values.contains { $0.contains("{{\(input.name)}}") },
                              "\(r.id): \(input.name) unused")
                XCTAssertNoThrow(try input.validate(""), "\(r.id): the default of \(input.name) is valid")
            }
            for path in r.files.keys { XCTAssertTrue(AppScript.isValidFilePath(path), path) }
        }
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(AppCatalog.serverDashboard.utf8)), "dashboard is valid JSON")
    }

    func testAllowedAddressesAndInputs() throws {
        XCTAssertEqual(try AppScript.allowedAddresses(["212.64.211.29, 198.51.100.0/24 212.64.211.29", ""]), ["212.64.211.29", "198.51.100.0/24"])
        XCTAssertThrowsError(try AppScript.allowedAddresses([" "]), "at least one")
        XCTAssertThrowsError(try AppScript.allowedAddresses(["0.0.0.0/0"]), "everyone is not an allow list")
        XCTAssertThrowsError(try AppScript.allowedAddresses(["::/0"]))
        XCTAssertThrowsError(try AppScript.allowedAddresses(["1.2.3.4; rm -rf /"]))
        let script = AppScript.allowFrom("node-exporter", port: 9100, addresses: ["212.64.211.29"])
        XCTAssertTrue(script.contains("ufw allow from '212.64.211.29' to any port 9100 proto tcp comment \"sigil-app:$APP\""), script)
        XCTAssertTrue(script.contains("RESULT noufw"), "never opens a port without an active firewall")

        let tag = AppInput(name: "VERSION", label: "Sürüm", defaultValue: "latest", kind: .imageTag)
        XCTAssertEqual(try tag.validate("  "), "latest")
        XCTAssertEqual(try tag.validate(" v1.9.0 "), "v1.9.0")
        for bad in ["v1 ; reboot", "../x", "-x", "a:b", "$(id)"] { XCTAssertThrowsError(try tag.validate(bad), bad) }
    }

    func testOldRecipesWithoutInputsStillLoad() throws {
        let r = try AppRecipe.custom(name: "Eski", compose: "services:\n  web:\n    image: nginx\n", port: nil, http: true, ownLogin: true, secrets: "")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json["inputs"] = nil
        let back = try JSONDecoder().decode(AppRecipe.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.inputs)
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

    /// A Node Exporter that also registers itself with a monitoring service: the variables become inputs.
    func testCustomRecipeVariablesBecomeInputs() async throws {
        let compose = """
        services:
          node-exporter:
            image: prom/node-exporter:{{VERSION}}
            container_name: sigil-node-exporter-own
            network_mode: host
            command: ["--web.listen-address={{ADDR}}:{{PORT}}"]
            environment:
              TOKEN: ${API_TOKEN}
              LEGEND: "{{mountpoint}} {{.State}}"
        """
        let post = """
        RESP=$(curl -sS -m 30 -w '\\n%{http_code}' -X POST "http://{{MONITOR_IP}}:{{REGISTER_PORT}}/register" \\
          --data-urlencode "name={{NODE_NAME}}" -d "port={{PORT}}" -H "X-Token: $API_TOKEN" || printf '\\n000')
        echo "$RESP"
        """
        let kept = AppInput(name: "VERSION", label: "Sürüm", defaultValue: "v1.9.0", kind: .imageTag)
        let r = try AppRecipe.custom(name: "Node Exporter + kayıt", compose: compose, port: 9100, http: false, ownLogin: false,
                                     secrets: "API_TOKEN", postInstall: post, inputs: [kept])
        XCTAssertEqual(r.inputs?.map(\.name), ["VERSION", "MONITOR_IP", "REGISTER_PORT", "NODE_NAME"],
                       "Sigil's own values, secrets and foreign {{…}} are not asked")
        XCTAssertEqual(r.inputs?.first, kept, "what the user set is kept")
        XCTAssertEqual(r.inputs?.map(\.kind), [.imageTag, .address, .port, .name])
        XCTAssertEqual(r.inputs?[1].label, "Monitor IP")
        XCTAssertEqual(r.access, [.tunnel, .publicPort, .allowList], "host network: can be limited to addresses")
        XCTAssertNotNil(r.postInstall)

        var p = plan(r, .allowList)
        p.vars["MONITOR_IP"] = "212.64.211.29"; p.vars["REGISTER_PORT"] = "9099"; p.vars["NODE_NAME"] = "web-01"
        let script = try XCTUnwrap(AppScript.postInstall(p))
        try await syntax(script)
        XCTAssertTrue(script.contains(#""http://212.64.211.29:9099/register""#), script)
        XCTAssertTrue(script.contains("name=web-01"), script)
        XCTAssertTrue(script.contains("API_TOKEN='"), "secrets are shell variables")

        let out = try await Shell.run("/bin/sh", ["-s"], stdin: AppScript.postInstall(
            AppScript.Plan(recipe: try AppRecipe.custom(name: "x", compose: "services:", port: nil, http: false, ownLogin: true, secrets: "",
                                                        postInstall: "echo merhaba {{WHO}}; exit 3"),
                           access: .tunnel, port: nil, domain: nil, secrets: [:], vars: ["WHO": "dunya"]))!
            .replacingOccurrences(of: AppScript.admin, with: "").replacingOccurrences(of: AppScript.docker, with: "")
            .replacingOccurrences(of: #"cd "$DIR" || { echo "RESULT missing"; exit 0; }"#, with: "")
        )
        XCTAssertEqual(AppScript.result(out.stdout), "done rc=3", out.stdout)
        XCTAssertEqual(AppScript.details(out.stdout), "merhaba dunya")

        XCTAssertThrowsError(try AppRecipe.custom(name: "x", compose: "services:", port: nil, http: true, ownLogin: true, secrets: "",
                                                  postInstall: "{{HOST_IP}}",
                                                  inputs: [AppInput(name: "HOST_IP", label: "IP", defaultValue: "1.2.3.4; reboot", kind: .address)]),
                             "a default must be valid")
        XCTAssertEqual(try AppRecipe.custom(name: "x", compose: "services:\n  a:\n    ports: [\"{{BIND}}{{PORT}}:80\"]", port: 80, http: true,
                                            ownLogin: true, secrets: "").inputs, nil, "nothing to ask")
    }

    /// An app installed with admin rights, managed while sudo is locked, needs sudo: it is not "missing".
    func testAppIsFoundWhereItWasInstalled() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-base-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), user = dir.appendingPathComponent("user")
        func where_(admin: Bool) async throws -> String {
            let base = admin ? root : user
            let s = "ADMIN=\(admin ? 1 : 0); ROOT_BASE='\(root.path)'; USER_BASE='\(user.path)'; BASE='\(base.path)'\n"
                + AppScript.appVars("demo") + "echo \"DIR=$DIR\"\n"
            return try await Shell.run("/bin/sh", ["-s"], stdin: s).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fm = FileManager.default
        var got = try await where_(admin: false)
        XCTAssertEqual(got, "DIR=\(user.path)/demo", "a new install without admin rights")

        try fm.createDirectory(at: root.appendingPathComponent("demo"), withIntermediateDirectories: true)
        got = try await where_(admin: false)
        XCTAssertEqual(AppScript.result(got), "needsudo", got)
        XCTAssertTrue(AppScript.failure("needsudo", got).needsSudo)
        got = try await where_(admin: true)
        XCTAssertEqual(got, "DIR=\(root.path)/demo")

        try fm.removeItem(at: root.appendingPathComponent("demo"))
        try fm.createDirectory(at: user.appendingPathComponent("demo"), withIntermediateDirectories: true)
        try "{}".write(to: user.appendingPathComponent("demo/sigil.json"), atomically: true, encoding: .utf8)
        got = try await where_(admin: true)
        XCTAssertEqual(got, "DIR=\(user.path)/demo", "installed before sudo was given: still managed where it is")

        // Admin rights and the app's place are settled before Docker is looked at.
        let script = AppScript.remove("demo")
        let at = { (part: String) in script.range(of: part)!.lowerBound }
        XCTAssertLessThan(at("RESULT needsudo"), at("RESULT nodocker"))
    }

    /// A file behind a folder the user can't enter needs root; a file that isn't there is missing.
    func testFileAccessNeedsRootOrIsMissing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-access-\(UUID().uuidString)")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "gizli\n".write(to: locked.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        try "açık\n".write(to: dir.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        // This Mac's sudo must not answer: the server's would only with a password Sigil was given.
        func run(_ script: String, _ path: String) async throws -> ShellResult {
            try await Shell.run("/bin/sh", ["-c", "sudo() { return 1; }; " + script], stdin: path + "\n")
        }
        for script in [FileScript.editRead, FileScript.read] {
            var r = try await run(script, locked.appendingPathComponent("a.conf").path)
            XCTAssertEqual(r.exitCode, 7, "needs root, not missing")
            r = try await run(script, dir.appendingPathComponent("nope.conf").path)
            XCTAssertEqual(r.exitCode, 4)
            r = try await run(script, dir.appendingPathComponent("b.conf").path)
            XCTAssertEqual(r.exitCode, 0)
            XCTAssertTrue(r.stdout.hasSuffix("açık\n"), r.stdout)
        }
        let w = try await run(FileScript.write, locked.appendingPathComponent("a.conf").path + "\n1 1 1\nx")
        XCTAssertEqual(w.exitCode, 7)
        let list = try await Shell.run("/bin/sh", ["-c", FileScript.list], stdin: locked.path + "\n")
        XCTAssertEqual(list.exitCode, 7, "a folder that can't be entered is not missing")
    }

    func testInputKinds() throws {
        func input(_ kind: AppInput.Kind, _ d: String = "") -> AppInput { AppInput(name: "X", label: "X", defaultValue: d, kind: kind) }
        XCTAssertThrowsError(try input(.text).validate(" "), "required when there is no default")
        XCTAssertEqual(try input(.text).validate("Ana sunucu, İstanbul"), "Ana sunucu, İstanbul")
        XCTAssertEqual(try input(.address).validate("212.64.211.29"), "212.64.211.29")
        XCTAssertEqual(try input(.address).validate("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(try input(.port, "9099").validate(""), "9099")
        XCTAssertEqual(try input(.name).validate("Web-01"), "web-01")
        for (kind, bad) in [(AppInput.Kind.text, "a\"b"), (.text, "$(id)"), (.text, "a;b"), (.text, "`x`"), (.text, "a\\b"), (.text, "it's"),
                            (.address, "1.2.3.4 x"), (.address, "-x"), (.port, "0"), (.port, "70000"), (.port, "80a"),
                            (.name, "web_01"), (.name, "-web")] {
            XCTAssertThrowsError(try input(kind).validate(bad), "\(kind): \(bad)")
        }
        XCTAssertEqual(AppInput.Kind.guess("MONITOR_IP"), .address)
        XCTAssertEqual(AppInput.Kind.guess("DB_HOST"), .address)
        XCTAssertEqual(AppInput.Kind.guess("API_PORT"), .port)
        XCTAssertEqual(AppInput.Kind.guess("IMAGE_TAG"), .imageTag)
        XCTAssertEqual(AppInput.Kind.guess("NODE_NAME"), .name)
        XCTAssertEqual(AppInput.Kind.guess("GREETING"), .text)

        // A kind added by a newer Sigil still loads (as text).
        let json = #"{"name":"X","label":"X","defaultValue":"","kind":"fromTheFuture"}"#
        XCTAssertEqual(try JSONDecoder().decode(AppInput.self, from: Data(json.utf8)).kind, .text)
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

    /// Node Exporter behind ufw in the Docker test server (its ufw is on): `SIGIL_DOCKER=1 swift test --filter AppsTests`.
    func testAllowListInstallInTheDockerTestServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_DOCKER"] == "1", "opt-in")
        func exec(_ script: String, timeout: TimeInterval = 600) async throws -> String {
            let r = try await Shell.run("/usr/local/bin/docker", ["exec", "-i", "sigil-test-server", "sh", "-s"], stdin: script, timeout: timeout)
            return r.stdout + r.stderr
        }
        let id = "node-exporter", from = "203.0.113.7"
        let recipe = AppCatalog.builtIn.first { $0.id == id }!
        var state = AppScript.parse(probe: try await exec(AppScript.probe))
        try XCTSkipUnless(state.dockerReady && state.ufwActive, "needs Docker and an active ufw")
        if state.apps.contains(where: { $0.id == id }) { _ = try await exec(AppScript.remove(id)) }
        let port = state.freePort(near: recipe.port!)
        var p = plan(recipe, .allowList)
        p.port = port
        p.vars["PORT"] = String(port)
        p.vars["VERSION"] = "v1.9.0"

        let r1 = try await exec(AppScript.allowFrom(id, port: port, addresses: [from]))
        XCTAssertEqual(AppScript.result(r1), "allowed")
        let rules = try await exec("ufw status")
        XCTAssertTrue(rules.contains("\(port)/tcp") && rules.contains(from) && rules.contains("sigil-app:\(id)"), rules)
        let r2 = try await exec(AppScript.write(p))
        XCTAssertEqual(AppScript.result(r2), "written")
        let pulled = try await exec(AppScript.pull(id), timeout: 900)
        XCTAssertEqual(AppScript.result(pulled), "rc=0", pulled)
        let r3 = try await exec(AppScript.up(id))
        XCTAssertEqual(AppScript.result(r3), "rc=0")
        let waited = try await exec(AppScript.wait(id, port: port, http: recipe.http))
        XCTAssertEqual(AppScript.result(waited), "ready", waited)
        let m = AppManifest(id: id, name: recipe.name, symbol: recipe.symbol, port: port, access: .allowList, domain: nil, http: recipe.http,
                            dir: "", custom: false, allowFrom: [from])
        let r4 = try await exec(AppScript.finish(m))
        XCTAssertEqual(AppScript.result(r4), "finished")

        let metrics = try await exec("sleep 2; curl -s http://127.0.0.1:\(port)/metrics | grep -E '^node_exporter_build_info|^node_network_receive_bytes_total'")
        XCTAssertTrue(metrics.contains("version=\"1.9.0\""), "the version input picks the image: \(metrics)")
        XCTAssertTrue(metrics.contains("node_network_receive_bytes_total"), metrics)
        let listening = try await exec("ss -Htln | awk '{print $4}'")
        XCTAssertTrue(listening.contains("*:\(port)") || listening.contains("0.0.0.0:\(port)") || listening.contains("[::]:\(port)"),
                      "listens outside, ufw decides: \(listening)")
        state = AppScript.parse(probe: try await exec(AppScript.probe))
        XCTAssertEqual(state.apps.first { $0.id == id }?.manifest.allowFrom, [from])

        let r5 = try await exec(AppScript.remove(id))
        XCTAssertTrue(AppScript.result(r5).hasPrefix("removed"))
        let after = try await exec("ufw status")
        XCTAssertFalse(after.contains("sigil-app:\(id)"), "removing the app deletes its rules: \(after)")
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
