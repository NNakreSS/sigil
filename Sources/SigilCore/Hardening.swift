import Foundation

/// What the server currently allows (read-only probe).
public struct HardeningState: Codable, Hashable, Sendable {
    public var user: String = ""
    public var isRoot = false
    /// Root or passwordless sudo: needed for any change.
    public var canAdminister = false
    public var osID: String?
    /// sshd_config pulls in /etc/ssh/sshd_config.d/*.conf (needed for our drop-in).
    public var sshdIncludesDropIns = false
    public var passwordAuthentication: Bool?
    public var keyboardInteractive: Bool?
    public var permitRootLogin: String?
    public var ufw: String = "missing"            // active | inactive | missing
    public var fail2ban: String = "missing"       // active | inactive | missing
    public var unattendedUpgrades: String = "missing"
    public var listeningPorts: [Int] = []
    public var sshPort = 22

    public init() {}

    public var isDebianLike: Bool { ["ubuntu", "debian"].contains(osID ?? "") }
    public var passwordLoginOpen: Bool { passwordAuthentication != false || keyboardInteractive == true }
    public var rootPasswordLoginOpen: Bool { ["yes"].contains(permitRootLogin ?? "yes") }
}

/// The changes the user picked.
public struct HardeningPlan: Hashable, Sendable {
    public var disablePasswordLogin = false
    public var restrictRootLogin = false
    public var enableFirewall = false
    public var firewallPorts: [Int] = []
    public var installFail2ban = false
    public var enableUnattendedUpgrades = false

    public init() {}

    public var touchesAccess: Bool { disablePasswordLogin || restrictRootLogin || enableFirewall }
    public var isEmpty: Bool { !(touchesAccess || installFail2ban || enableUnattendedUpgrades) }
}

/// Builds the scripts. Everything that can lock the user out is applied together with a detached watchdog that
/// restores the previous state unless a *new* connection proves access still works within `confirmWindow` seconds.
public enum HardeningScript {
    public static let dropIn = "/etc/ssh/sshd_config.d/00-sigil-hardening.conf"

    /// Commands/paths that tests replace to run the logic locally.
    public struct Environment: Sendable {
        public var sudoPrefix: String? = nil              // nil = auto (sudo -n unless root)
        public var dropInPath = HardeningScript.dropIn
        public var sshdTest = "sshd -t"
        public var sshdReload = "systemctl reload ssh 2>/dev/null || systemctl reload sshd"
        public var ufw = "ufw"
        public var stateDir = "/tmp"
        public var confirmWindow = 45
        public init() {}
    }

    static let probe = #"""
    SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
    echo "user=$(id -un)"
    echo "root=$([ "$(id -u)" -eq 0 ] && echo 1 || echo 0)"
    if [ -z "$SUDO" ] || sudo -n true 2>/dev/null; then echo "admin=1"; else echo "admin=0"; fi
    [ -r /etc/os-release ] && . /etc/os-release && echo "os=$ID"
    grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null && echo "include=1" || echo "include=0"
    $SUDO sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|port) ' | sed 's/ /=/'
    if command -v ufw >/dev/null 2>&1; then $SUDO ufw status 2>/dev/null | grep -qi 'Status: active' && echo "ufw=active" || echo "ufw=inactive"; else echo "ufw=missing"; fi
    if command -v fail2ban-client >/dev/null 2>&1; then systemctl is-active --quiet fail2ban && echo "f2b=active" || echo "f2b=inactive"; else echo "f2b=missing"; fi
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then systemctl is-active --quiet unattended-upgrades && echo "uu=active" || echo "uu=inactive"; else echo "uu=missing"; fi
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' | sed 's/.*://' | sort -un | tr '\n' ' ' | sed 's/^/ports=/'; echo
    exit 0
    """#

    public static func parseProbe(_ text: String) -> HardeningState {
        var s = HardeningState()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].lowercased(), v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch k {
            case "user": s.user = v
            case "root": s.isRoot = v == "1"
            case "admin": s.canAdminister = v == "1"
            case "os": s.osID = v.lowercased()
            case "include": s.sshdIncludesDropIns = v == "1"
            case "passwordauthentication": s.passwordAuthentication = v.lowercased() == "yes"
            case "kbdinteractiveauthentication": s.keyboardInteractive = v.lowercased() == "yes"
            case "permitrootlogin": s.permitRootLogin = v.lowercased()
            case "port": s.sshPort = Int(v) ?? 22
            case "ufw": s.ufw = v
            case "f2b": s.fail2ban = v
            case "uu": s.unattendedUpgrades = v
            case "ports": s.listeningPorts = v.split(separator: " ").compactMap { Int($0) }.filter { (1...65535).contains($0) }
            default: break
            }
        }
        return s
    }

    /// The access-changing step: sshd drop-in and/or firewall, then the watchdog. Prints `RESULT …`.
    static func apply(_ plan: HardeningPlan, state: HardeningState, token: String, env: Environment = Environment()) -> String {
        precondition(token.range(of: #"^[a-z0-9]{16,64}$"#, options: .regularExpression) != nil)
        var sshdLines: [String] = ["# Managed by Sigil. Remove this file to undo."]
        if plan.disablePasswordLogin {
            sshdLines += ["PasswordAuthentication no", "KbdInteractiveAuthentication no"]
        }
        if plan.restrictRootLogin {
            // Never lock out the account Sigil itself logs in with.
            sshdLines.append(state.isRoot ? "PermitRootLogin prohibit-password" : "PermitRootLogin no")
        }
        let wantSSHD = plan.disablePasswordLogin || plan.restrictRootLogin
        let ports = Array(Set(plan.firewallPorts + [state.sshPort])).filter { (1...65535).contains($0) }.sorted()
        let sudo = env.sudoPrefix.map { "SUDO=\"\($0)\"" } ?? #"SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n""#

        return """
        set -u
        \(sudo)
        DROPIN='\(env.dropInPath)'
        TOKEN='\(env.stateDir)/sigil-confirm-\(token)'
        WATCH='\(env.stateDir)/sigil-watchdog-\(token).sh'
        HAD_DROPIN=0; [ -f "$DROPIN" ] && HAD_DROPIN=1
        UFW_WAS=inactive
        \(plan.enableFirewall ? "$SUDO \(env.ufw) status 2>/dev/null | grep -qi 'Status: active' && UFW_WAS=active" : ":")

        if [ \(wantSSHD ? 1 : 0) -eq 1 ]; then
          [ "$HAD_DROPIN" -eq 1 ] && $SUDO cp -p "$DROPIN" "$DROPIN.sigil-prev"
          printf '%s\\n' \(sshdLines.map { "'\($0)'" }.joined(separator: " ")) | $SUDO tee "$DROPIN" >/dev/null
          if ! $SUDO \(env.sshdTest) >/dev/null 2>&1; then
            if [ "$HAD_DROPIN" -eq 1 ]; then $SUDO mv "$DROPIN.sigil-prev" "$DROPIN"; else $SUDO rm -f "$DROPIN"; fi
            echo "RESULT sshd_invalid"; exit 2
          fi
          $SUDO sh -c '\(env.sshdReload)' >/dev/null 2>&1
        fi

        if [ \(plan.enableFirewall ? 1 : 0) -eq 1 ]; then
          for p in \(ports.map(String.init).joined(separator: " ")); do $SUDO \(env.ufw) allow "$p/tcp" >/dev/null 2>&1; done
          $SUDO \(env.ufw) --force enable >/dev/null 2>&1
        fi

        # Watchdog: detached, survives this connection dropping. Undo everything unless $TOKEN appears in time.
        cat > "$WATCH.tmp" <<SIGILEOF
        trap '' HUP
        i=0
        while [ \\$i -lt \(env.confirmWindow) ]; do
          if [ -f "$TOKEN" ]; then rm -f "$TOKEN" "$DROPIN.sigil-prev" "$WATCH"; exit 0; fi
          sleep 1; i=\\$((i+1))
        done
        if [ \(wantSSHD ? 1 : 0) -eq 1 ]; then
          if [ "$HAD_DROPIN" -eq 1 ]; then mv "$DROPIN.sigil-prev" "$DROPIN"; else rm -f "$DROPIN"; fi
          sh -c '\(env.sshdReload)' >/dev/null 2>&1
        fi
        if [ \(plan.enableFirewall ? 1 : 0) -eq 1 ] && [ "$UFW_WAS" = inactive ]; then \(env.ufw) --force disable >/dev/null 2>&1; fi
        echo rolledback > "$TOKEN.rolledback"
        rm -f "$WATCH"
        SIGILEOF
        $SUDO mv "$WATCH.tmp" "$WATCH" 2>/dev/null || mv "$WATCH.tmp" "$WATCH"
        $SUDO nohup sh "$WATCH" >/dev/null 2>&1 &
        echo "RESULT applied"
        exit 0
        """
    }

    /// Run over a *new* connection: proves the new settings still let Sigil in, which disarms the watchdog.
    static func confirm(token: String, env: Environment = Environment()) -> String {
        "touch '\(env.stateDir)/sigil-confirm-\(token)' && echo RESULT confirmed"
    }

    /// Low-risk extras (no access impact), Debian/Ubuntu.
    static func extras(_ plan: HardeningPlan) -> String {
        var lines = [#"SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n""#, "export DEBIAN_FRONTEND=noninteractive", "ok=1"]
        if plan.installFail2ban {
            lines.append("$SUDO apt-get install -y -q fail2ban >/dev/null 2>&1 && $SUDO systemctl enable --now fail2ban >/dev/null 2>&1 || ok=0")
        }
        if plan.enableUnattendedUpgrades {
            lines.append("$SUDO apt-get install -y -q unattended-upgrades >/dev/null 2>&1 && $SUDO systemctl enable --now unattended-upgrades >/dev/null 2>&1 || ok=0")
        }
        lines.append(#"[ $ok -eq 1 ] && echo "RESULT extras_ok" || echo "RESULT extras_failed""#)
        return lines.joined(separator: "\n")
    }
}

extension RemoteService {
    public func hardeningState(target: RemoteTarget, auth: RemoteAuth) async throws -> HardeningState {
        let r = try await execute(target, auth, "sh -s", stdin: HardeningScript.probe)
        guard r.succeeded else { throw failure(r, auth) }
        return HardeningScript.parseProbe(r.stdout)
    }

    func runScript(target: RemoteTarget, auth: RemoteAuth, _ script: String) async throws -> String {
        let r = try await execute(target, auth, "sh -s", stdin: script)
        if r.exitCode == 255 || r.timedOut { throw failure(r, auth) }
        return r.stdout
    }
}
