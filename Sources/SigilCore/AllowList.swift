import Foundation

/// One address (or network) allowed to reach the server's SSH port.
public struct AllowedAddress: Codable, Hashable, Identifiable, Sendable {
    public var id: String { address }
    /// IPv4/IPv6 address or CIDR network, e.g. 203.0.113.7 or 198.51.100.0/24.
    public var address: String
    public var label: String

    public init(address: String, label: String) {
        self.address = address
        self.label = label
    }
}

/// What the server's firewall says about SSH access right now.
public struct AllowListState: Sendable, Equatable {
    /// The address the server sees for Sigil's own connection (from $SSH_CLIENT): the one that must stay allowed.
    public var clientAddress: String?
    public var sshPort = 22
    /// active | inactive | missing
    public var ufw = "missing"
    public var isDebianLike = false
    public var canAdminister = false
    /// Rules Sigil put there (comment `sigil-allow:<label>`).
    public var allowed: [AllowedAddress] = []
    /// SSH is still open to anyone (a plain `allow <port>` / OpenSSH rule, or no active firewall).
    public var openToAll = true
    /// Other public TCP ports listening, kept open when the firewall is switched on.
    public var otherPorts: [Int] = []

    public init() {}

    public var isOn: Bool { ufw == "active" && !allowed.isEmpty && !openToAll }
}

public enum AllowList {
    public static let commentPrefix = "sigil-allow:"

    // MARK: Addresses

    /// Accepts IPv4/IPv6 with an optional prefix length; returns the canonical text.
    public static func validate(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard parse(s) != nil else {
            throw DeckError.invalid("“\(raw)” geçerli bir IP adresi ya da ağ (ör. 203.0.113.7, 198.51.100.0/24) değil.")
        }
        return s
    }

    /// Address bytes and prefix length, or nil.
    static func parse(_ s: String) -> (bytes: [UInt8], prefix: Int)? {
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        guard let ip = parts.first, !ip.isEmpty, ip.count <= 45 else { return nil }
        var bytes: [UInt8]
        if ip.contains(":") {
            var a6 = in6_addr()
            guard inet_pton(AF_INET6, ip, &a6) == 1 else { return nil }
            bytes = withUnsafeBytes(of: a6) { Array($0) }
        } else {
            let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }) else { return nil }
            let values = octets.compactMap { Int($0) }
            guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
            bytes = values.map(UInt8.init)
        }
        let maxPrefix = bytes.count * 8
        var prefix = maxPrefix
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...maxPrefix).contains(p), parts[1].allSatisfy(\.isNumber) else { return nil }
            prefix = p
        }
        return (bytes, prefix)
    }

    /// Whether `address` falls inside `network` (an address or CIDR).
    public static func contains(_ network: String, _ address: String) -> Bool {
        guard let n = parse(network), let a = parse(address), n.bytes.count == a.bytes.count else { return false }
        var bits = n.prefix
        for i in 0..<n.bytes.count where bits > 0 {
            let take = min(8, bits)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - take))
            if n.bytes[i] & mask != a.bytes[i] & mask { return false }
            bits -= take
        }
        return true
    }

    /// Letters, digits, space, dot, dash and underscore; Turkish letters are folded so ufw comments stay ASCII.
    static func cleanLabel(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR")).replacingOccurrences(of: "ı", with: "i")
        let kept = folded.filter { $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0)) }
        let t = kept.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "adres" : String(t.prefix(40))
    }

    // MARK: Scripts

    /// Commands and paths that tests replace.
    public struct Environment: Sendable {
        public var sudoPrefix: String? = nil
        public var ufw = "ufw"
        public var rules = ["/etc/ufw/user.rules", "/etc/ufw/user6.rules"]
        public var stateDir = "/tmp"
        public var confirmWindow = 45
        public var install = "DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw"
        public init() {}
    }

    static let probe = #"""
    SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
    echo "client=${SSH_CLIENT%% *}"
    if [ -z "$SUDO" ] || sudo -n true 2>/dev/null; then echo "admin=1"; else echo "admin=0"; fi
    [ -r /etc/os-release ] && . /etc/os-release && echo "os=$ID $ID_LIKE"
    $SUDO sshd -T 2>/dev/null | grep -i '^port ' | head -1 | sed 's/ /=/'
    if command -v ufw >/dev/null 2>&1; then
      if $SUDO ufw status 2>/dev/null | grep -qi 'Status: active'; then echo "ufw=active"; else echo "ufw=inactive"; fi
      $SUDO ufw status 2>/dev/null | sed 's/^/rule|/'
    else echo "ufw=missing"; fi
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' | sed 's/.*://' | sort -un | tr '\n' ' ' | sed 's/^/ports=/'; echo
    exit 0
    """#

    public static func parse(probe text: String) -> AllowListState {
        var s = AllowListState()
        var ruleLines: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("rule|") { ruleLines.append(String(line.dropFirst(5))); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].lowercased(), v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch k {
            case "client": s.clientAddress = (try? validate(v))
            case "admin": s.canAdminister = v == "1"
            case "os": s.isDebianLike = v.lowercased().contains("debian") || v.lowercased().contains("ubuntu")
            case "port": s.sshPort = Int(v) ?? 22
            case "ufw": s.ufw = v
            case "ports": s.otherPorts = v.split(separator: " ").compactMap { Int($0) }.filter { (1...65535).contains($0) }
            default: break
            }
        }
        s.otherPorts.removeAll { $0 == s.sshPort }
        let (allowed, open) = parseRules(ruleLines, port: s.sshPort)
        s.allowed = allowed
        s.openToAll = s.ufw != "active" || open
        return s
    }

    /// `ufw status` rows: Sigil's own `from` rules for the SSH port, and whether a rule still opens it to anyone.
    static func parseRules(_ lines: [String], port: Int) -> (allowed: [AllowedAddress], openToAll: Bool) {
        var allowed: [AllowedAddress] = []
        var open = false
        for line in lines {
            let parts = line.components(separatedBy: "#")
            let body = parts[0]
            let comment = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let cols = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let ai = cols.firstIndex(where: { $0 == "ALLOW" }), ai > 0 else { continue }
            let to = cols[..<ai].joined(separator: " ")
            let from = cols.dropFirst(ai + 1).first { $0 != "IN" } ?? ""
            let forSSH = to.hasPrefix("\(port)/tcp") || to == "\(port)" || to.hasPrefix("\(port) ") || to.hasPrefix("OpenSSH")
            guard forSSH else { continue }
            if from.hasPrefix("Anywhere") {
                open = true
            } else if comment.hasPrefix(commentPrefix), let addr = try? validate(from),
                      !allowed.contains(where: { $0.address == addr }) {
                allowed.append(AllowedAddress(address: addr, label: String(comment.dropFirst(commentPrefix.count))))
            }
        }
        return (allowed, open)
    }

    /// Replaces Sigil's allow rules with `addresses`, closes the SSH port to everyone else, and keeps the other
    /// listening ports open if the firewall was off. A detached watchdog restores the previous rules unless a *new*
    /// connection confirms within the window. Prints `RESULT …`.
    static func apply(_ addresses: [AllowedAddress], state: AllowListState, token: String, env: Environment = Environment()) -> String {
        precondition(token.range(of: #"^[a-z0-9]{16,64}$"#, options: .regularExpression) != nil)
        precondition(!addresses.isEmpty)
        let sudo = env.sudoPrefix.map { "SUDO=\"\($0)\"" } ?? #"SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n""#
        let port = state.sshPort
        let adds = addresses.map {
            "$SUDO \(env.ufw) allow from \($0.address) to any port \(port) proto tcp comment '\(commentPrefix)\(cleanLabel($0.label))' >/dev/null"
        }
        let others = state.otherPorts.filter { $0 != port }.map(String.init).joined(separator: " ")
        return """
        set -u
        \(sudo)
        TOKEN='\(env.stateDir)/sigil-confirm-\(token)'
        WATCH='\(env.stateDir)/sigil-watchdog-\(token).sh'
        BK='\(env.stateDir)/sigil-ufw-\(token)'
        if ! command -v \(env.ufw.split(separator: " ").first ?? "ufw") >/dev/null 2>&1; then $SUDO sh -c '\(env.install)' >/dev/null 2>&1 || { echo "RESULT no_ufw"; exit 3; }; fi
        UFW_WAS=inactive
        $SUDO \(env.ufw) status 2>/dev/null | grep -qi 'Status: active' && UFW_WAS=active
        $SUDO mkdir -p "$BK"
        for f in \(env.rules.map { "'\($0)'" }.joined(separator: " ")); do [ -f "$f" ] && $SUDO cp -p "$f" "$BK/$(basename "$f")"; done

        # Sigil's previous rules out (highest number first, so the numbering does not shift underneath).
        for n in $($SUDO \(env.ufw) status numbered 2>/dev/null | grep '\(commentPrefix)' | sed -E 's/^\\[ *([0-9]+)\\].*/\\1/' | sort -rn); do
          $SUDO \(env.ufw) --force delete "$n" >/dev/null 2>&1
        done
        \(adds.joined(separator: "\n"))
        # Close the port to everyone else.
        $SUDO \(env.ufw) delete allow \(port)/tcp >/dev/null 2>&1
        $SUDO \(env.ufw) delete allow \(port) >/dev/null 2>&1
        $SUDO \(env.ufw) delete allow OpenSSH >/dev/null 2>&1
        if [ "$UFW_WAS" = inactive ]; then
          for p in \(others); do $SUDO \(env.ufw) allow "$p/tcp" >/dev/null 2>&1; done
          $SUDO \(env.ufw) --force enable >/dev/null 2>&1
        fi

        # Watchdog: detached, survives this connection dropping. Restore the old rules unless $TOKEN appears in time.
        cat > "$WATCH.tmp" <<SIGILEOF
        trap '' HUP
        i=0
        while [ \\$i -lt \(env.confirmWindow) ]; do
          if [ -f "$TOKEN" ]; then rm -rf "$TOKEN" "$BK" "$WATCH"; exit 0; fi
          sleep 1; i=\\$((i+1))
        done
        \(env.rules.map { "[ -f \"$BK/\(($0 as NSString).lastPathComponent)\" ] && cp -p \"$BK/\(($0 as NSString).lastPathComponent)\" '\($0)'" }.joined(separator: "\n"))
        \(env.ufw) reload >/dev/null 2>&1
        if [ "$UFW_WAS" = inactive ]; then \(env.ufw) --force disable >/dev/null 2>&1; fi
        echo rolledback > "$TOKEN.rolledback"
        rm -rf "$BK" "$WATCH"
        SIGILEOF
        $SUDO mv "$WATCH.tmp" "$WATCH" 2>/dev/null || mv "$WATCH.tmp" "$WATCH"
        $SUDO nohup sh "$WATCH" >/dev/null 2>&1 &
        echo "RESULT applied"
        exit 0
        """
    }

    /// Opens SSH to everyone again and removes Sigil's rules (only widens access, so no watchdog needed).
    static func disable(state: AllowListState, env: Environment = Environment()) -> String {
        let sudo = env.sudoPrefix.map { "SUDO=\"\($0)\"" } ?? #"SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n""#
        return """
        \(sudo)
        $SUDO \(env.ufw) allow \(state.sshPort)/tcp >/dev/null 2>&1
        for n in $($SUDO \(env.ufw) status numbered 2>/dev/null | grep '\(commentPrefix)' | sed -E 's/^\\[ *([0-9]+)\\].*/\\1/' | sort -rn); do
          $SUDO \(env.ufw) --force delete "$n" >/dev/null 2>&1
        done
        echo "RESULT opened"
        """
    }
}

extension DeckModel {
    public func allowListState(_ id: UUID) async throws -> AllowListState {
        guard let s = server(id) else { throw DeckError.notFound }
        let out = try await remote.runScript(target: sharedTarget(for: s), auth: auth(s.store, s.keyFileName), AllowList.probe)
        let state = AllowList.parse(probe: out)
        update(id) { $0.allowList = state.isOn ? state.allowed : nil }
        return state
    }

    /// Allows SSH only from `addresses`. Refuses a list that would shut out this Mac unless `allowLockingMeOut`.
    /// Applied with a watchdog: a fresh login must confirm within 45 s, or the server restores its old rules.
    public func applyAllowList(_ id: UUID, _ addresses: [AllowedAddress], allowLockingMeOut: Bool = false,
                               progress: @MainActor (String) -> Void = { _ in }) async throws -> HardeningOutcome {
        guard let s = server(id) else { throw DeckError.notFound }
        let list = try addresses.map { AllowedAddress(address: try AllowList.validate($0.address), label: $0.label) }
        guard !list.isEmpty else { throw DeckError.invalid("En az bir adres gerekli.") }
        return try await withBusy(id, "IP izin listesi uygulanıyor") {
            let shared = sharedTarget(for: s), fresh = target(for: s), a = auth(s.store, s.keyFileName)
            progress("Güvenlik duvarı okunuyor")
            let state = AllowList.parse(probe: try await remote.runScript(target: shared, auth: a, AllowList.probe))
            guard state.canAdminister else { throw DeckError.invalid("Bu kullanıcı root değil ve şifresiz sudo yetkisi yok.") }
            guard state.isDebianLike || state.ufw != "missing" else {
                throw DeckError.invalid("IP izin listesi şimdilik ufw ile (Ubuntu/Debian) çalışıyor.")
            }
            if !allowLockingMeOut {
                guard let me = state.clientAddress else {
                    throw DeckError.invalid("Sunucunun bu Mac’i hangi IP’den gördüğü okunamadı; kendini dışarıda bırakmamak için durduruldu.")
                }
                guard list.contains(where: { AllowList.contains($0.address, me) }) else {
                    throw DeckError.invalid("Listede bu Mac’in IP’si (\(me)) yok; uygulasaydın sunucuya giremezdin.")
                }
            }
            let token = (0..<2).map { _ in UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }.joined().prefix(32)
            progress("Kurallar uygulanıyor (45 sn içinde doğrulanmazsa kendiliğinden geri alınır)")
            let out = try await remote.runScript(target: shared, auth: a, AllowList.apply(list, state: state, token: String(token)))
            if out.contains("RESULT no_ufw") { throw DeckError.invalid("ufw kurulamadı.") }
            guard out.contains("RESULT applied") else { throw DeckError.ssh("Sunucu beklenen yanıtı vermedi: \(out.trimmed)") }

            progress("Yeni bağlantıyla erişim doğrulanıyor")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let confirmed = (try? await remote.runScript(target: fresh, auth: a, HardeningScript.confirm(token: String(token))))?
                .contains("RESULT confirmed") ?? false
            if !confirmed {
                progress("Doğrulanamadı; sunucunun geri almasını bekliyorum")
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                let back = (try? await remote.ping(target: fresh, auth: a)) != nil
                let message = back ? "Yeni kurallarla giriş doğrulanamadı; sunucu eski kurallara döndü, erişim yerinde."
                                   : "Doğrulanamadı; sunucu geri alma yaptı ama erişim henüz doğrulanamadı."
                log(id, .error, "IP izin listesi geri alındı: \(message)")
                return .rolledBack(message)
            }
            update(id) { $0.allowList = list }
            log(id, .warning, "SSH yalnızca şu adreslere açık: " + list.map { "\($0.address) (\($0.label))" }.joined(separator: ", "))
            return .applied(HardeningState())
        }
    }

    /// Opens SSH to everyone again.
    public func disableAllowList(_ id: UUID) async throws {
        guard let s = server(id) else { throw DeckError.notFound }
        try await withBusy(id, "IP izin listesi kapatılıyor") {
            let a = auth(s.store, s.keyFileName), shared = sharedTarget(for: s)
            let state = AllowList.parse(probe: try await remote.runScript(target: shared, auth: a, AllowList.probe))
            let out = try await remote.runScript(target: shared, auth: a, AllowList.disable(state: state))
            guard out.contains("RESULT opened") else { throw DeckError.ssh("Sunucu beklenen yanıtı vermedi: \(out.trimmed)") }
            update(id) { $0.allowList = nil }
            log(id, .info, "IP izin listesi kapatıldı; SSH yeniden her yerden erişilebilir.")
        }
    }
}
