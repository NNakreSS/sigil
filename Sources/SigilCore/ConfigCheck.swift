import Foundation

/// The server's own validator for a config file, run after saving it (`nginx -t`, `sshd -t`…).
public enum ConfigCheck: String, Sendable {
    case nginx, sshd, compose, caddy, systemd

    public static func forFile(_ path: String, language: CodeLanguage) -> ConfigCheck? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if language == .nginx { return .nginx }
        if name == "sshd_config" || path.hasPrefix("/etc/ssh/sshd_config.d/") { return .sshd }
        if language == .yaml, name.range(of: #"^(docker-)?compose(\.[\w-]+)?\.ya?ml$"#, options: .regularExpression) != nil { return .compose }
        if language == .caddyfile { return .caddy }
        if language == .systemd { return .systemd }
        return nil
    }

    public var title: String {
        switch self {
        case .nginx: return "nginx -t"
        case .sshd: return "sshd -t"
        case .compose: return "docker compose config"
        case .caddy: return "caddy validate"
        case .systemd: return "systemd-analyze verify"
        }
    }

    /// What a failed check means for what is running.
    public var failureAdvice: String {
        switch self {
        case .nginx, .caddy: return "Servisi yeniden yükleme; önce düzelt ya da geri al. Çalışan servis eski yapılandırmayla devam ediyor."
        case .sshd: return "sshd’yi yeniden başlatma, yoksa bağlantı kurulamayabilir; önce düzelt ya da geri al."
        case .compose: return "Çalışan container’lar etkilenmedi; “docker compose up” yapmadan önce düzelt ya da geri al."
        case .systemd: return "Servisi yeniden başlatmadan önce düzelt ya da geri al."
        }
    }

    /// The service can be told to pick up the new config (nginx and Caddy reload without dropping connections).
    public var reloadTitle: String? {
        switch self {
        case .nginx: return "nginx’i yeniden yükle"
        case .caddy: return "Caddy’yi yeniden yükle"
        default: return nil
        }
    }

    private static let sudo = #"R=""; [ "$(id -u)" -eq 0 ] || { sudo -n true 2>/dev/null && R="sudo -n"; }"#

    /// Exit 3: the tool is not there (or needs a password); anything else is the validator's own result.
    var script: String {
        let body: String
        switch self {
        case .nginx:
            body = #"command -v nginx >/dev/null 2>&1 || [ -x /usr/sbin/nginx ] || exit 3; PATH="$PATH:/usr/sbin"; $R nginx -t 2>&1"#
        case .sshd:
            body = #"""
            PATH="$PATH:/usr/sbin"; command -v sshd >/dev/null 2>&1 || exit 3
            case "$P" in /etc/ssh/sshd_config.d/*) $R sshd -t 2>&1 ;; *) $R sshd -t -f "$P" 2>&1 ;; esac
            """#
        case .compose:
            body = #"""
            cd "$(dirname "$P")" || exit 3
            if docker compose version >/dev/null 2>&1; then C="docker compose"
            elif command -v docker-compose >/dev/null 2>&1; then C="docker-compose"
            else exit 3; fi
            # Structure only: ${VAR} and ${VAR:?…} come from .env or other files at deploy time, not from this one.
            OUT=$($C -f "$P" config -q --no-interpolate 2>&1); rc=$?
            case "$OUT" in *"unknown flag"*|*"no such option"*) OUT=$($C -f "$P" config -q 2>&1); rc=$? ;; esac
            printf '%s\n' "$OUT"
            case "$OUT" in *"required variable"*|*"error while interpolating"*|*"is not set"*) exit 3 ;; esac
            exit $rc
            """#
        case .caddy:
            body = #"""
            if command -v caddy >/dev/null 2>&1; then $R caddy validate --config "$P" --adapter caddyfile 2>&1
            elif docker inspect sigil-caddy >/dev/null 2>&1 || $R docker inspect sigil-caddy >/dev/null 2>&1; then
              D=docker; docker info >/dev/null 2>&1 || D="$R docker"; $D exec sigil-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1
            else exit 3; fi
            """#
        case .systemd:
            body = #"command -v systemd-analyze >/dev/null 2>&1 || exit 3; systemd-analyze verify "$P" 2>&1"#
        }
        return "read -r P\n" + Self.sudo + "\n" + body + "\n"
    }

    var reloadScript: String? {
        switch self {
        case .nginx:
            return Self.sudo + "\n" + #"PATH="$PATH:/usr/sbin"; $R systemctl reload nginx 2>&1 || $R nginx -s reload 2>&1"# + "\n"
        case .caddy:
            return Self.sudo + "\n" + #"""
            if systemctl is-active --quiet caddy 2>/dev/null; then $R systemctl reload caddy 2>&1
            else D=docker; docker info >/dev/null 2>&1 || D="$R docker"; $D exec sigil-caddy caddy reload --config /etc/caddy/Caddyfile 2>&1; fi
            """# + "\n"
        default: return nil
        }
    }

    /// Lines of the checked file the validator complained about.
    static func diagnostics(_ output: String, path: String) -> [Diagnostic] {
        let name = NSRegularExpression.escapedPattern(for: (path as NSString).lastPathComponent)
        let patterns = [name + #":(\d+)"#, name + #" line (\d+)"#, #"\bline (\d+)"#]
        var out: [Diagnostic] = []
        for raw in output.split(whereSeparator: \.isNewline).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for p in patterns {
                guard let r = line.range(of: p, options: .regularExpression) else { continue }
                let digits = line[r].split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
                if let n = digits {
                    out.append(Diagnostic(line: n, message: line, severity: line.lowercased().contains("warn") ? .warning : .error))
                }
                break
            }
        }
        return out
    }
}

public struct ConfigCheckResult: Sendable, Equatable {
    public let check: ConfigCheck
    /// nil: the validator could not run here (not installed, or needs a sudo password).
    public let passed: Bool?
    public let output: String
    public let diagnostics: [Diagnostic]
}

extension DeckModel {
    public func runConfigCheck(_ id: UUID, _ check: ConfigCheck, path: String) async throws -> ConfigCheckResult {
        let r = try await runShared(id, FileScript.command(check.script), stdin: try FileScript.checkPath(path) + "\n", timeout: 60)
        if r.exitCode == 255 && r.stdout.isEmpty { throw DeckError.ssh(SSHErrorText.friendly(r.stderr, exitCode: r.exitCode, timedOut: r.timedOut)) }
        let output = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.exitCode == 3 || output.contains("a password is required") {
            return ConfigCheckResult(check: check, passed: nil, output: output, diagnostics: [])
        }
        return ConfigCheckResult(check: check, passed: r.exitCode == 0, output: output,
                                 diagnostics: r.exitCode == 0 ? [] : ConfigCheck.diagnostics(output, path: path))
    }

    public func reloadService(_ id: UUID, _ check: ConfigCheck) async throws -> String {
        guard let script = check.reloadScript else { throw DeckError.invalid("Bu servis yeniden yüklenemez.") }
        let r = try await runShared(id, FileScript.command(script), timeout: 60)
        guard r.exitCode == 0 else {
            throw DeckError.ssh((r.stdout + r.stderr).trimmed.isEmpty ? "Yeniden yüklenemedi." : (r.stdout + r.stderr).trimmed)
        }
        log(id, .info, check == .nginx ? "nginx yeniden yüklendi." : "Caddy yeniden yüklendi.")
        return (r.stdout + r.stderr).trimmed
    }
}
