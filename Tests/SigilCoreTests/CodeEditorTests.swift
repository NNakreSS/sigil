import XCTest
@testable import SigilCore

final class CodeEditorTests: XCTestCase {
    func testDetectsLanguages() {
        let cases: [(String, String, CodeLanguage)] = [
            ("/opt/app/.env", "", .env), ("/opt/app/.env.production", "", .env), ("/srv/x/prod.env", "", .env),
            ("/opt/sigil/apps/grafana/docker-compose.yml", "", .yaml), ("/etc/netplan/50-cloud.yaml", "", .yaml),
            ("/etc/nginx/nginx.conf", "", .nginx), ("/etc/nginx/sites-available/default", "", .nginx),
            ("/etc/ssh/sshd_config", "", .conf), ("/etc/fail2ban/jail.local", "", .conf), ("/etc/mysql/my.cnf", "", .conf),
            ("/etc/systemd/system/app.service", "", .systemd), ("/srv/Dockerfile", "", .dockerfile), ("/etc/caddy/Caddyfile", "", .caddyfile),
            ("/root/deploy", "#!/usr/bin/env bash", .shell), ("/root/.bashrc", "", .shell), ("/usr/local/bin/tool", "#!/usr/bin/python3", .python),
            ("/srv/app/index.ts", "", .javascript), ("/var/www/index.php", "", .php), ("/var/log/syslog", "", .log),
            ("/var/log/nginx/access.log.1", "", .log), ("/srv/package.json", "", .json), ("/srv/README.md", "", .markdown), ("/notes", "", .plain),
        ]
        for (path, first, expected) in cases {
            XCTAssertEqual(CodeLanguage.detect(path: path, firstLine: first), expected, path)
        }
    }

    private func kinds(_ text: String, _ lang: CodeLanguage) -> [String: TokenKind] {
        let ns = text as NSString
        var out: [String: TokenKind] = [:]
        for t in Highlighter.tokens(text, language: lang) { out[ns.substring(with: t.range)] = t.kind }
        return out
    }

    func testHighlightsWithoutConfusingStringsAndComments() {
        let env = kinds("# yorum\nDB_URL=\"postgres://a#b@x\"\nexport PORT=8080\nGREETING=\"hi $USER\"\n", .env)
        XCTAssertEqual(env["# yorum"], .comment)
        XCTAssertEqual(env["\"postgres://a#b@x\""], .string, "# inside a string is not a comment")
        XCTAssertEqual(env["DB_URL"], .key)
        XCTAssertEqual(env["PORT"], .key)
        XCTAssertEqual(env["8080"], .number)
        XCTAssertEqual(env["$USER"], .variable, "variables are coloured inside double quotes")

        let yaml = kinds("services:\n  web:\n    image: \"nginx:1.27\"  # sabit\n    restart: always\n    enabled: true\n", .yaml)
        XCTAssertEqual(yaml["services"], .key)
        XCTAssertEqual(yaml["image"], .key)
        XCTAssertEqual(yaml["\"nginx:1.27\""], .string)
        XCTAssertEqual(yaml["# sabit"], .comment)
        XCTAssertEqual(yaml["true"], .constant)

        let json = kinds(#"{"name": "sigil", "n": 3, "ok": false}"#, .json)
        XCTAssertEqual(json["\"name\""], .key)
        XCTAssertEqual(json["\"sigil\""], .string)
        XCTAssertEqual(json["false"], .constant)

        let sh = kinds("if [ -f \"$HOME/x\" ]; then echo 'a # b'; fi # end\n", .shell)
        XCTAssertEqual(sh["if"], .keyword)
        XCTAssertEqual(sh["'a # b'"], .string)
        XCTAssertEqual(sh["# end"], .comment)
        XCTAssertEqual(sh["$HOME"], .variable)

        let nginx = kinds("server {\n    listen 443 ssl;\n    root \"/var/www\";\n    return 301 https://$host$request_uri;\n}\n", .nginx)
        XCTAssertEqual(nginx["listen"], .keyword)
        XCTAssertEqual(nginx["$host"], .variable)

        let log = kinds("2026-10-18 12:00:01 ERROR db failed from 10.0.0.5\n", .log)
        XCTAssertEqual(log["ERROR"], .error)
        XCTAssertEqual(log["10.0.0.5"], .key)
    }

    func testEnvLint() {
        let d = CodeLint.check("""
        # ok
        A=1
        B = 2
        C=hello world
        D="unterminated
        A=again
        not a pair
        export E='x'
        """, language: .env)
        let byLine = Dictionary(grouping: d, by: \.line)
        XCTAssertNil(byLine[2])
        XCTAssertEqual(byLine[3]?.first?.severity, .error)
        XCTAssertEqual(byLine[4]?.first?.severity, .warning)
        XCTAssertEqual(byLine[5]?.first?.message, "Kapanmamış tırnak.")
        XCTAssertTrue(byLine[6]?.first?.message.contains("ikinci kez") ?? false)
        XCTAssertNotNil(byLine[7])
        XCTAssertNil(byLine[8])
    }

    func testYamlLint() {
        let d = CodeLint.check("services:\n  web:\n    image:nginx\n\tports: []\n  web:\n    command: \"x\n  db:\n    image: postgres\nvolumes:\n  data:\n", language: .yaml)
        let lines = Set(d.map(\.line))
        XCTAssertTrue(lines.contains(3), "missing space after colon")
        XCTAssertTrue(lines.contains(4), "tab indentation")
        XCTAssertTrue(lines.contains(5), "duplicate key at the same level")
        XCTAssertTrue(lines.contains(6), "unterminated quote")
        XCTAssertFalse(lines.contains(8), "image under a different parent is fine")
        XCTAssertTrue(CodeLint.check("ports:\n  - \"80:80\"\n  - 443:443\nurl: http://x\n", language: .yaml).isEmpty)
        // A list item with a colon is a plain string (compose security_opt).
        XCTAssertTrue(CodeLint.check("security_opt:\n  - no-new-privileges:true\n  - label:disable\n", language: .yaml).isEmpty)
    }

    func testJsonLint() {
        XCTAssertTrue(CodeLint.check(#"{"a": [1, 2]}"#, language: .json).isEmpty)
        let d = CodeLint.check("{\n  \"a\": 1,\n  \"b\": \n}\n", language: .json)
        XCTAssertEqual(d.count, 1)
        XCTAssertGreaterThanOrEqual(d[0].line, 3)
    }

    func testShellLint() async {
        let ok = await CodeLint.shell("#!/bin/sh\nif [ -f x ]; then\n  echo hi\nfi\n")
        XCTAssertTrue(ok.isEmpty)
        let bad = await CodeLint.shell("#!/bin/bash\nif [ -f x ]; then\n  echo hi\n\necho done\n")
        XCTAssertFalse(bad.isEmpty)
        let fi = await CodeLint.shell("echo a\nfi\n")
        XCTAssertEqual(fi.first?.line, 2)
    }

    func testConfigCheckChoiceAndParsing() async throws {
        XCTAssertEqual(ConfigCheck.forFile("/etc/nginx/sites-enabled/default", language: .nginx), .nginx)
        XCTAssertEqual(ConfigCheck.forFile("/etc/ssh/sshd_config", language: .conf), .sshd)
        XCTAssertEqual(ConfigCheck.forFile("/etc/ssh/sshd_config.d/10-x.conf", language: .conf), .sshd)
        XCTAssertEqual(ConfigCheck.forFile("/opt/x/docker-compose.yml", language: .yaml), .compose)
        XCTAssertEqual(ConfigCheck.forFile("/opt/x/compose.prod.yaml", language: .yaml), .compose)
        XCTAssertNil(ConfigCheck.forFile("/etc/netplan/a.yaml", language: .yaml))

        let nginx = ConfigCheck.diagnostics("nginx: [emerg] unknown directive \"lisen\" in /etc/nginx/sites-enabled/default:12\nnginx: configuration file /etc/nginx/nginx.conf test failed", path: "/etc/nginx/sites-enabled/default")
        XCTAssertEqual(nginx.map(\.line), [12])
        let sshd = ConfigCheck.diagnostics("/etc/ssh/sshd_config line 5: Bad configuration option: Foo", path: "/etc/ssh/sshd_config")
        XCTAssertEqual(sshd.map(\.line), [5])

        for c in [ConfigCheck.nginx, .sshd, .compose, .caddy, .systemd] {
            let r = try await Shell.run("/bin/sh", ["-n"], stdin: c.script)
            XCTAssertEqual(r.exitCode, 0, "\(c): \(r.stderr)")
            if let reload = c.reloadScript {
                let rr = try await Shell.run("/bin/sh", ["-n"], stdin: reload)
                XCTAssertEqual(rr.exitCode, 0, rr.stderr)
            }
        }
    }

    /// The validators against the Docker test server: `SIGIL_DOCKER=1 swift test --filter CodeEditorTests`.
    func testValidatorsInTheDockerTestServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIGIL_DOCKER"] == "1", "opt-in")
        func run(_ check: ConfigCheck, _ path: String) async throws -> ShellResult {
            try await Shell.run("/usr/local/bin/docker", ["exec", "-i", "sigil-test-server", "sh", "-c", check.script], stdin: path + "\n")
        }
        let nginxOK = try await run(.nginx, "/etc/nginx/sites-enabled/default")
        XCTAssertEqual(nginxOK.exitCode, 0, nginxOK.stdout)
        let sshdOK = try await run(.sshd, "/etc/ssh/sshd_config")
        XCTAssertEqual(sshdOK.exitCode, 0, sshdOK.stdout)
        _ = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "sh", "-c", "printf 'server {\\n  lisen 81;\\n}\\n' > /etc/nginx/sites-enabled/sigil-lint-test"])
        let bad = try await run(.nginx, "/etc/nginx/sites-enabled/sigil-lint-test")
        _ = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "rm", "-f", "/etc/nginx/sites-enabled/sigil-lint-test"])
        XCTAssertNotEqual(bad.exitCode, 0)
        XCTAssertEqual(ConfigCheck.diagnostics(bad.stdout, path: "/etc/nginx/sites-enabled/sigil-lint-test").first?.line, 2)

        // A compose overlay that needs a variable from .env is fine on its own; a real schema error is not.
        let setup = #"""
        mkdir -p /tmp/sigil-compose
        cat > /tmp/sigil-compose/compose.hook.yml <<'EOF'
        services:
          hook:
            image: node:22-alpine
            environment:
              S: ${S:?set S in .env}
            security_opt:
              - no-new-privileges:true
        EOF
        cat > /tmp/sigil-compose/compose.bad.yml <<'EOF'
        services:
          web:
            image: x
            ports: 80
        EOF
        """#
        _ = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "sh", "-c", setup])
        let overlay = try await run(.compose, "/tmp/sigil-compose/compose.hook.yml")
        let broken = try await run(.compose, "/tmp/sigil-compose/compose.bad.yml")
        _ = try await Shell.run("/usr/local/bin/docker", ["exec", "sigil-test-server", "rm", "-rf", "/tmp/sigil-compose"])
        XCTAssertEqual(overlay.exitCode, 0, overlay.stdout)
        XCTAssertEqual(broken.exitCode, 1, broken.stdout)
        XCTAssertTrue(broken.stdout.contains("ports"))
    }
}
