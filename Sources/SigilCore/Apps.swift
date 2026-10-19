import Foundation
import Security

// MARK: - Recipes

public enum AppCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case essentials, monitoring, containers, databases, apps, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .essentials: return "Temel"
        case .monitoring: return "İzleme"
        case .containers: return "Container yönetimi"
        case .databases: return "Veritabanı"
        case .apps: return "Uygulamalar"
        case .custom: return "Kendi tariflerim"
        }
    }
}

/// How an installed app is reached.
public enum AppAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Listens on the server's 127.0.0.1 only; Sigil brings it to this Mac through a tunnel.
    case tunnel
    /// Behind Caddy on a domain, with an automatic Let's Encrypt certificate (and a password when the app has none).
    case domain
    /// Published on the server's public address.
    case publicPort
    /// Listens on the server's address; ufw lets in only the listed addresses. Only for host-networked recipes:
    /// a port Docker publishes bypasses ufw.
    case allowList

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .tunnel: return "Yalnızca tünelle"
        case .domain: return "Alan adı + HTTPS"
        case .publicPort: return "Herkese açık port"
        case .allowList: return "Belirli adreslere açık"
        }
    }

    /// Listens on every address rather than 127.0.0.1.
    public var listensOutside: Bool { self == .publicPort || self == .allowList }
}

/// A value the user types before the install, filled into the recipe as `{{NAME}}`.
public struct AppInput: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A Docker image tag such as `latest` or `v1.9.0`.
        case imageTag
    }

    public var name: String
    public var label: String
    public var defaultValue: String
    public var kind: Kind
    public var help: String?
    public var id: String { name }

    public init(name: String, label: String, defaultValue: String, kind: Kind, help: String? = nil) {
        self.name = name
        self.label = label
        self.defaultValue = defaultValue
        self.kind = kind
        self.help = help
    }

    /// The trimmed value (the default when empty), or an error that names the field.
    public func validate(_ raw: String) throws -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        let value = v.isEmpty ? defaultValue : v
        switch kind {
        case .imageTag:
            guard Validation.matches(value, #"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$"#) else {
                throw DeckError.invalid("\(label): “\(value)” geçerli bir imaj etiketi değil (ör. latest, v1.9.0).")
            }
        }
        return value
    }
}

/// One installable thing: a docker compose project plus what Sigil needs to know to set it up and show how to reach it.
///
/// Placeholders Sigil fills before writing the files: `{{BIND}}` (`127.0.0.1:` unless public), `{{PORT}}` (host port),
/// `{{ADDR}}` (listen address for a host-networked service: `127.0.0.1`, empty when it listens outside),
/// `{{URL}}` (address you open), `{{HTTPS}}` (`true`/`false`), `{{DOMAIN}}`, `{{SERVER}}` (alias), `{{TZ}}`,
/// and each of the recipe's `inputs` by name.
/// Generated secrets go into `.env` and are referenced as `${NAME}` in the compose file.
public struct AppRecipe: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: AppCategory
    public var summary: String
    public var symbol: String
    public var website: String?
    public var compose: String
    /// Extra files next to the compose file (relative path → content). Files that end up holding a secret are 0600.
    public var files: [String: String]
    /// Host port of the web UI or service; nil when there is nothing to connect to.
    public var port: Int?
    /// The port speaks HTTP (opened in the browser) rather than a raw protocol such as PostgreSQL.
    public var http: Bool
    /// The app has its own login. Without one, a domain gets a Caddy password and a public port is not offered.
    public var ownLogin: Bool
    /// The first visitor creates the admin account: open it right away when it is reachable from outside.
    public var firstVisitSetup: Bool
    public var access: [AppAccess]
    /// Values asked in the install screen (nil in recipes saved before inputs existed).
    public var inputs: [AppInput]?
    /// Environment variables Sigil generates (random, 24 characters) and writes to `.env`.
    public var secrets: [String]
    /// Connection lines shown after the install; `{{NAME}}` is a secret, `{{ADDRESS}}` host:port from this Mac.
    public var info: [String]
    public var notes: String?
    /// Shell run on the server after start (in the app folder; `$D` is docker, secrets are set as variables).
    public var postInstall: String?
    public var minMemoryMB: Int
    public var isCustom: Bool

    public init(id: String, name: String, category: AppCategory, summary: String, symbol: String, website: String? = nil,
                compose: String, files: [String: String] = [:], port: Int?, http: Bool = true, ownLogin: Bool,
                firstVisitSetup: Bool = false, access: [AppAccess]? = nil, inputs: [AppInput] = [], secrets: [String] = [],
                info: [String] = [], notes: String? = nil, postInstall: String? = nil, minMemoryMB: Int = 256, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.symbol = symbol
        self.website = website
        self.compose = compose
        self.files = files
        self.port = port
        self.http = http
        self.ownLogin = ownLogin
        self.firstVisitSetup = firstVisitSetup
        self.access = access ?? AppRecipe.defaultAccess(port: port, http: http, ownLogin: ownLogin)
        self.inputs = inputs.isEmpty ? nil : inputs
        self.secrets = secrets
        self.info = info
        self.notes = notes
        self.postInstall = postInstall
        self.minMemoryMB = minMemoryMB
        self.isCustom = isCustom
    }

    static func defaultAccess(port: Int?, http: Bool, ownLogin: Bool) -> [AppAccess] {
        guard port != nil else { return [.tunnel] }
        if !http { return [.tunnel, .publicPort] }
        return ownLogin ? [.tunnel, .domain, .publicPort] : [.tunnel, .domain]
    }

    /// Secrets the install generates for `access` (a Caddy password for a domain in front of an app without a login).
    public func secretNames(for access: AppAccess) -> [String] {
        secrets + (access == .domain && !ownLogin ? [AppScript.proxyPasswordName] : [])
    }

    public var isDockerEngine: Bool { id == AppCatalog.dockerID }

    /// A user's own recipe, checked and normalised.
    public static func custom(name: String, compose: String, port: Int?, http: Bool, ownLogin: Bool,
                              secrets: String, summary: String = "", id: String? = nil) throws -> AppRecipe {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40 else { throw DeckError.invalid("Tarife bir ad ver (en fazla 40 karakter).") }
        let slug = id ?? "custom-" + AppScript.slug(n)
        guard slug.count > 7, AppScript.isValidID(slug) else { throw DeckError.invalid("Ad en az bir harf ya da rakam içermeli.") }
        let c = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.contains("services:") else { throw DeckError.invalid("Bu bir docker compose dosyasına benzemiyor (services: yok).") }
        guard c.utf8.count <= 64 * 1024 else { throw DeckError.invalid("Compose dosyası çok büyük.") }
        if let port, !(1...65535).contains(port) { throw DeckError.invalid("Port 1–65535 arasında olmalı.") }
        let names = secrets.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map(String.init)
        for s in names where !AppScript.isValidSecretName(s) {
            throw DeckError.invalid("“\(s)” geçerli bir değişken adı değil (BÜYÜK_HARF, rakam ve _).")
        }
        var unique: [String] = []
        for s in names where !unique.contains(s) { unique.append(s) }
        return AppRecipe(id: slug, name: n, category: .custom, summary: summary.isEmpty ? "Kendi docker compose tarifin." : summary,
                         symbol: "shippingbox", compose: c + "\n", port: port, http: http, ownLogin: ownLogin,
                         secrets: unique,
                         info: unique.map { "\($0): {{\($0)}}" }, isCustom: true)
    }
}

// MARK: - What is on the server

/// Written to `<app folder>/sigil.json` by the install; the server is the source of truth for what is installed.
public struct AppManifest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var port: Int?
    public var access: AppAccess
    public var domain: String?
    public var http: Bool
    public var installedAt: Date
    public var dir: String
    public var custom: Bool
    /// The addresses ufw lets in, for `.allowList`.
    public var allowFrom: [String]?

    public init(id: String, name: String, symbol: String, port: Int?, access: AppAccess, domain: String?, http: Bool,
                installedAt: Date = Date(), dir: String, custom: Bool, allowFrom: [String]? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.port = port
        self.access = access
        self.domain = domain
        self.http = http
        self.installedAt = installedAt
        self.dir = dir
        self.custom = custom
        self.allowFrom = allowFrom
    }
}

public struct InstalledApp: Codable, Hashable, Identifiable, Sendable {
    public var manifest: AppManifest
    public var running: Int
    public var total: Int
    public var id: String { manifest.id }
    public var isRunning: Bool { total > 0 && running == total }
    public var isStopped: Bool { running == 0 }
}

/// Result of the read-only look at the server before an install.
public struct AppHostState: Sendable, Equatable {
    /// root or password-less sudo.
    public var admin = false
    /// ok | sudo | nouser | missing
    public var docker = "missing"
    /// plugin | legacy | missing
    public var compose = "missing"
    public var os = ""
    public var arch = ""
    public var memoryTotalMB = 0
    public var memoryAvailableMB = 0
    public var diskFreeMB = 0
    public var listening: Set<Int> = []
    public var ufwActive = false
    public var apps: [InstalledApp] = []

    public init() {}

    public var dockerReady: Bool { (docker == "ok" || docker == "sudo") && compose != "missing" }

    /// `preferred`, or the next port that nothing on the server listens on (nor another Sigil app uses).
    public func freePort(near preferred: Int) -> Int {
        let taken = listening.union(apps.compactMap(\.manifest.port))
        var p = preferred
        while taken.contains(p) && p < 65535 { p += 1 }
        return p
    }
}

public enum AppAction: String, Sendable { case start, stop, restart, update, logs }

/// What an install did, for the result screen.
public struct AppInstallReport: Sendable {
    public var manifest: AppManifest
    /// The app did not answer in time; it is installed, but check its logs.
    public var warnings: [String]
}

/// Everything the user needs to reach an installed app.
public struct AppConnection: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        /// Holds a generated password: shown masked until asked.
        public var isSecret: Bool
        public var id: String { label + value }
    }
    public var url: String?
    public var address: String?
    public var lines: [Line]
}

// MARK: - Credentials kept on this Mac

/// Generated app passwords, kept so the connection details can be shown again later.
public protocol AppSecretStore: Sendable {
    func save(_ values: [String: String], account: String)
    func load(account: String) -> [String: String]?
    func delete(account: String)
}

public struct KeychainAppSecrets: AppSecretStore {
    static let service = "com.nakres.sigil.app-credentials"
    public init() {}

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func save(_ values: [String: String], account: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Sigil uygulama bilgileri (\(account))"
        SecItemAdd(add as CFDictionary, nil)
    }

    public func load(account: String) -> [String: String]? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: d)
    }

    public func delete(account: String) { SecItemDelete(base(account) as CFDictionary) }
}

final class MemoryAppSecrets: AppSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    func save(_ v: [String: String], account: String) { lock.lock(); values[account] = v; lock.unlock() }
    func load(account: String) -> [String: String]? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func delete(account: String) { lock.lock(); values[account] = nil; lock.unlock() }
}

struct RecipeStore: Sendable {
    let paths: DeckPaths
    var file: URL { paths.supportDir.appendingPathComponent("recipes.json") }

    func load() -> [AppRecipe] {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([AppRecipe].self, from: data) else { return [] }
        return list.filter { $0.isCustom && AppScript.isValidID($0.id) }
    }

    func save(_ list: [AppRecipe]) throws {
        try paths.ensureDirectories()
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(list).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - Scripts

/// Shell scripts for installing and managing apps. Every script is sent on stdin (`sh -s`), so generated secrets
/// never appear in a command line on either machine. Apps live in /opt/sigil/apps/<id> (or ~/sigil-apps/<id>
/// without root), each a compose project named `sigil-<id>`.
public enum AppScript {
    static let proxyPasswordName = "PROXY_PASSWORD"

    static func isValidID(_ s: String) -> Bool { Validation.matches(s, #"^[a-z0-9][a-z0-9-]{0,47}$"#) }
    static func isValidSecretName(_ s: String) -> Bool { Validation.matches(s, #"^[A-Z][A-Z0-9_]{0,63}$"#) }

    /// Addresses for `.allowList`, typed comma/space separated: each checked, canonical, no duplicates, at least one.
    public static func allowedAddresses(_ raw: [String]) throws -> [String] {
        var out: [String] = []
        for part in raw.flatMap({ $0.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }) }) {
            let a = try AllowList.validate(String(part))
            guard AllowList.parse(a)?.prefix != 0 else { throw DeckError.invalid("“\(a)” herkesi kapsar; belirli bir adres ya da ağ yaz.") }
            if !out.contains(a) { out.append(a) }
        }
        guard !out.isEmpty else { throw DeckError.invalid("Erişebilecek en az bir IP adresi yaz.") }
        guard out.count <= 20 else { throw DeckError.invalid("En fazla 20 adres yazılabilir.") }
        return out
    }
    static func isValidFilePath(_ s: String) -> Bool {
        Validation.matches(s, #"^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$"#) && !s.contains("..")
    }

    static func slug(_ s: String) -> String {
        let turkish: [Character: String] = ["ı": "i", "İ": "i", "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g", "ç": "c", "Ç": "c",
                                            "ö": "o", "Ö": "o", "ü": "u", "Ü": "u"]
        let plain = s.map { turkish[$0] ?? String($0) }.joined()
        let folded = plain.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII { out.unicodeScalars.append(ch) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
    }

    public static func validateDomain(_ raw: String) throws -> String {
        let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard d.count <= 253, Validation.matches(d, #"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#) else {
            throw DeckError.invalid("Geçerli bir alan adı yaz (ör. grafana.ornek.com).")
        }
        return d
    }

    /// Random letters and digits from the system's secure generator.
    public static func secret(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var out = ""
        while out.count < length {
            var bytes = [UInt8](repeating: 0, count: 64)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { continue }
            for b in bytes where Int(b) < 256 - 256 % alphabet.count && out.count < length { out.append(alphabet[Int(b) % alphabet.count]) }
        }
        return out
    }

    /// Replaces the known `{{KEY}}` placeholders only, so other `{{…}}` (Grafana legends, Go templates) survive.
    static func fill(_ text: String, _ vars: [String: String]) -> String {
        vars.reduce(text) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
    }

    /// Picks a heredoc delimiter that appears nowhere in `content`.
    static func heredoc(_ content: String) -> (String, String) {
        var tag = "SIGIL_EOF_" + String(UUID().uuidString.prefix(8))
        while content.contains(tag) { tag += "X" }
        return (tag, content.hasSuffix("\n") ? content : content + "\n")
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Sets S (sudo), BASE, D (docker) and C (compose). Exits with a RESULT line when Docker cannot be used.
    static let header = #"""
    S=""; ADMIN=0
    if [ "$(id -u)" -eq 0 ]; then ADMIN=1; elif sudo -n true 2>/dev/null; then S="sudo -n"; ADMIN=1; fi
    if [ "$ADMIN" = 1 ]; then BASE=/opt/sigil/apps; else BASE="$HOME/sigil-apps"; fi
    D=""
    # A non-root admin keeps the apps in /opt/sigil/apps as root (.env is 0600), so compose must read them as root too,
    # even when the user is in the docker group.
    if [ -n "$S" ] && $S docker info >/dev/null 2>&1; then D="$S docker"; elif docker info >/dev/null 2>&1; then D=docker; fi
    [ -n "$D" ] || { echo "RESULT nodocker"; exit 0; }
    if $D compose version >/dev/null 2>&1; then C="$D compose"
    elif command -v docker-compose >/dev/null 2>&1; then C="${D%docker}docker-compose"
    else echo "RESULT nocompose"; exit 0; fi
    run() { OUT=$("$@" 2>&1); RC=$?; printf '%s\n' "$OUT" | tail -n 25; return $RC; }

    """#

    static func appVars(_ id: String) -> String {
        "APP=\(id); DIR=\"$BASE/$APP\"; P=sigil-$APP\n"
    }

    /// Read-only look at the server: admin rights, Docker, resources, listening ports, firewall and Sigil's apps.
    static let probe = #"""
    S=""; ADMIN=0
    if [ "$(id -u)" -eq 0 ]; then ADMIN=1; elif sudo -n true 2>/dev/null; then S="sudo -n"; ADMIN=1; fi
    echo "admin=$ADMIN"
    [ -r /etc/os-release ] && . /etc/os-release && echo "os=$ID $ID_LIKE"
    echo "arch=$(uname -m)"
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "mem=%d %d\n", t/1024, a/1024}' /proc/meminfo 2>/dev/null
    df -Pm / 2>/dev/null | awk 'NR==2{print "disk="$4}'
    D=""
    if docker info >/dev/null 2>&1; then D=docker; echo "docker=ok"
    elif [ -n "$S" ] && $S docker info >/dev/null 2>&1; then D="$S docker"; echo "docker=sudo"
    elif command -v docker >/dev/null 2>&1; then echo "docker=nouser"
    else echo "docker=missing"; fi
    if [ -n "$D" ]; then
      if $D compose version >/dev/null 2>&1; then echo "compose=plugin"
      elif command -v docker-compose >/dev/null 2>&1; then echo "compose=legacy"
      else echo "compose=missing"; fi
    fi
    (ss -Htln 2>/dev/null || netstat -tln 2>/dev/null | tail -n +3) | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' ' | sed 's/^/ports=/'; echo
    if [ "$ADMIN" = 1 ] && command -v ufw >/dev/null 2>&1 && $S ufw status 2>/dev/null | grep -qi 'Status: active'; then echo "ufw=active"; else echo "ufw=off"; fi
    for f in /opt/sigil/apps/*/sigil.json "$HOME"/sigil-apps/*/sigil.json; do
      [ -r "$f" ] && printf 'app=%s\n' "$(tr -d '\n' < "$f")"
    done
    if [ -n "$D" ]; then
      $D ps -a --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}} {{.State}}' 2>/dev/null | grep '^sigil-' | sed 's/^/ctr=/'
    fi
    exit 0
    """#

    public static func parse(probe text: String) -> AppHostState {
        var s = AppHostState()
        var manifests: [AppManifest] = []
        var counts: [String: (Int, Int)] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "admin": s.admin = value == "1"
            case "os": s.os = value
            case "arch": s.arch = value
            case "mem":
                let p = value.split(separator: " ").compactMap { Int($0) }
                if p.count == 2 { s.memoryTotalMB = p[0]; s.memoryAvailableMB = p[1] }
            case "disk": s.diskFreeMB = Int(value) ?? 0
            case "docker": s.docker = value
            case "compose": s.compose = value
            case "ports": s.listening = Set(value.split(separator: " ").compactMap { Int($0) })
            case "ufw": s.ufwActive = value == "active"
            case "app":
                if let m = try? decoder.decode(AppManifest.self, from: Data(value.utf8)), isValidID(m.id) { manifests.append(m) }
            case "ctr":
                let p = value.split(separator: " ")
                guard p.count == 2 else { continue }
                let project = String(p[0].dropFirst("sigil-".count))
                var c = counts[project] ?? (0, 0)
                c.1 += 1
                if p[1] == "running" { c.0 += 1 }
                counts[project] = c
            default: continue
            }
        }
        s.apps = manifests.sorted { $0.name < $1.name }.map { m in
            InstalledApp(manifest: m, running: counts[m.id]?.0 ?? 0, total: counts[m.id]?.1 ?? 0)
        }
        return s
    }

    // MARK: Install steps

    struct Plan: Sendable {
        var recipe: AppRecipe
        var access: AppAccess
        var port: Int?
        var domain: String?
        var secrets: [String: String]
        /// Placeholder values (BIND, PORT, URL…).
        var vars: [String: String]
    }

    /// Writes the compose file, `.env`, extra files; creates the shared `sigil` network. Refuses to overwrite an app.
    static func write(_ plan: Plan) -> String {
        var s = header + appVars(plan.recipe.id)
        s += #"[ -e "$DIR/sigil.json" ] && { echo "RESULT exists"; exit 0; }"# + "\n"
        s += #"$S mkdir -p "$DIR" || { echo "RESULT nowrite"; exit 0; }"# + "\n"
        s += file("docker-compose.yml", fill(plan.recipe.compose, plan.vars), secret: false)
        let env = plan.secrets.keys.sorted().map { "\($0)=\(plan.secrets[$0]!)" }.joined(separator: "\n")
        s += file(".env", env, secret: true)
        for path in plan.recipe.files.keys.sorted() where isValidFilePath(path) {
            let content = fill(plan.recipe.files[path]!, plan.vars.merging(plan.secrets) { a, _ in a })
            s += file(path, content, secret: plan.secrets.values.contains { content.contains($0) })
        }
        s += #"$D network inspect sigil >/dev/null 2>&1 || $D network create sigil >/dev/null"# + "\n"
        s += "echo \"RESULT written\"\n"
        return s
    }

    private static func file(_ path: String, _ content: String, secret: Bool) -> String {
        let (tag, body) = heredoc(content)
        let target = "\"$DIR/\(path)\""
        var s = path.contains("/") ? "$S mkdir -p \"$(dirname \(target))\"\n" : ""
        // A one-line secret (a password file) is written without a trailing newline.
        if secret, !content.contains("\n"), path != ".env" {
            return s + "(umask 077; printf '%s' \(q(content)) | $S tee \(target) >/dev/null)\n$S chmod 600 \(target)\n"
        }
        s += secret ? "(umask 077; $S tee \(target) >/dev/null <<'\(tag)'\n\(body)\(tag)\n)\n$S chmod 600 \(target)\n"
                    : "$S tee \(target) >/dev/null <<'\(tag)'\n\(body)\(tag)\n$S chmod 644 \(target)\n"
        return s
    }

    static func pull(_ id: String) -> String {
        header + appVars(id) + #"cd "$DIR" || { echo "RESULT missing"; exit 0; }; run $C -p "$P" pull --ignore-buildable 2>/dev/null || run $C -p "$P" pull; echo "RESULT rc=$?""# + "\n"
    }

    static func up(_ id: String) -> String {
        header + appVars(id) + #"cd "$DIR" || { echo "RESULT missing"; exit 0; }; run $C -p "$P" up -d --remove-orphans; echo "RESULT rc=$?""# + "\n"
    }

    /// Waits up to `seconds` for the containers to run and, for a web app, for the port to answer HTTP.
    static func wait(_ id: String, port: Int?, http: Bool, seconds: Int = 90) -> String {
        var s = header + appVars(id) + #"cd "$DIR" || { echo "RESULT missing"; exit 0; }"# + "\n"
        let check: String
        if let port, http {
            check = """
            if command -v curl >/dev/null 2>&1; then curl -s -o /dev/null -m 3 http://127.0.0.1:\(port)/ && ok=1
            elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null -T 3 http://127.0.0.1:\(port)/; rc=$?; [ $rc -eq 0 ] || [ $rc -eq 8 ] && ok=1
            else ok=1; fi
            """
        } else {
            check = "ok=1"
        }
        s += """
        i=0
        while [ $i -lt \(seconds / 3) ]; do
          ok=0
          if [ -z "$($D ps -a --filter label=com.docker.compose.project=$P --format '{{.State}}' | grep -v running)" ]; then
            \(check)
          fi
          [ "$ok" = 1 ] && { echo "RESULT ready"; exit 0; }
          i=$((i+1)); sleep 3
        done
        $C -p "$P" ps 2>&1 | tail -n 10
        $C -p "$P" logs --tail 20 2>&1 | tail -n 20
        echo "RESULT timeout"

        """
        return s
    }

    static func postInstall(_ plan: Plan) -> String? {
        guard let body = plan.recipe.postInstall else { return nil }
        var s = header + appVars(plan.recipe.id) + #"cd "$DIR" || { echo "RESULT missing"; exit 0; }"# + "\n"
        for name in plan.secrets.keys.sorted() { s += "\(name)=\(q(plan.secrets[name]!))\n" }
        s += "( \n" + fill(body, plan.vars) + "\n) 2>&1 | tail -n 20\necho \"RESULT done\"\n"
        return s
    }

    static let caddyCompose = """
    services:
      caddy:
        image: caddy:2
        container_name: sigil-caddy
        restart: unless-stopped
        network_mode: host
        volumes:
          - ./Caddyfile:/etc/caddy/Caddyfile:ro
          - ./sites:/etc/caddy/sites:ro
          - caddy_data:/data
          - caddy_config:/config
    volumes:
      caddy_data:
      caddy_config:
    """

    /// Puts the app behind Caddy on `domain` (starting Caddy on 80/443 the first time). Without the app's own
    /// login, Caddy asks for the generated password; the hash is made inside the Caddy container from stdin.
    static func publish(_ id: String, domain: String, port: Int, password: String?) -> String {
        var s = header + appVars(id)
        let manifest = AppManifest(id: "caddy", name: "Caddy (HTTPS)", symbol: "lock.rectangle.stack", port: nil, access: .domain,
                                   domain: nil, http: true, dir: "", custom: false)
        s += """
        CD="$BASE/caddy"
        if ! $D inspect sigil-caddy >/dev/null 2>&1; then
          if (ss -Htln 2>/dev/null || netstat -tln 2>/dev/null) | awk '{print $4}' | grep -Eq ':(80|443)$'; then echo "RESULT webports"; exit 0; fi
          $S mkdir -p "$CD/sites"

        """
        s += fileAt("$CD/docker-compose.yml", caddyCompose) + fileAt("$CD/Caddyfile", "import /etc/caddy/sites/*.caddy\n")
        s += """
        M=$(cat <<'SIGIL_MANIFEST'
        \(manifestJSON(manifest, dir: "$CD"))
        SIGIL_MANIFEST
        )
        printf '%s\\n' "$M" | sed "s#__DIR__#$CD#" | $S tee "$CD/sigil.json" >/dev/null
        (cd "$CD" && run $C -p sigil-caddy up -d) || { echo "RESULT caddyfail"; exit 0; }
        sleep 2
        fi

        """
        if let password {
            s += "PW=\(q(password))\n"
            s += #"H=$(printf '%s\n' "$PW" | $D exec -i sigil-caddy caddy hash-password 2>/dev/null | tail -n 1)"# + "\n"
            s += #"[ -n "$H" ] || { echo "RESULT hashfail"; exit 0; }"# + "\n"
            s += "SITE=$(cat <<SIGIL_SITE\n\(domain) {\n\tbasic_auth {\n\t\tsigil $H\n\t}\n\treverse_proxy 127.0.0.1:\(port)\n}\nSIGIL_SITE\n)\n"
        } else {
            s += "SITE=$(cat <<'SIGIL_SITE'\n\(domain) {\n\treverse_proxy 127.0.0.1:\(port)\n}\nSIGIL_SITE\n)\n"
        }
        s += """
        printf '%s\\n' "$SITE" | $S tee "$BASE/caddy/sites/$APP.caddy" >/dev/null
        run $D exec sigil-caddy caddy reload --config /etc/caddy/Caddyfile || { echo "RESULT reloadfail"; exit 0; }
        if [ "$ADMIN" = 1 ] && command -v ufw >/dev/null 2>&1 && $S ufw status 2>/dev/null | grep -qi 'Status: active'; then
          $S ufw allow 80/tcp comment 'sigil-app:caddy' >/dev/null; $S ufw allow 443/tcp comment 'sigil-app:caddy' >/dev/null
        fi
        echo "RESULT published"

        """
        return s
    }

    private static func fileAt(_ path: String, _ content: String) -> String {
        let (tag, body) = heredoc(content)
        return "$S tee \"\(path)\" >/dev/null <<'\(tag)'\n\(body)\(tag)\n"
    }

    /// Opens a public port in an active ufw (Docker's own rules publish it anyway; this keeps ufw honest).
    static func openPort(_ id: String, port: Int) -> String {
        header + appVars(id) + """
        if [ "$ADMIN" = 1 ] && command -v ufw >/dev/null 2>&1 && $S ufw status 2>/dev/null | grep -qi 'Status: active'; then
          $S ufw allow \(port)/tcp comment "sigil-app:$APP" >/dev/null
        fi
        echo "RESULT opened"

        """
    }

    /// Lets only `addresses` reach `port` through an active ufw; run before the app starts listening. Removing the
    /// app deletes the rules by their comment.
    static func allowFrom(_ id: String, port: Int, addresses: [String]) -> String {
        let rules = addresses.map {
            "$S ufw allow from \(q($0)) to any port \(port) proto tcp comment \"sigil-app:$APP\" >/dev/null || { echo \"RESULT ufwfail\"; exit 0; }"
        }
        return header + appVars(id) + """
        [ "$ADMIN" = 1 ] || { echo "RESULT noroot"; exit 0; }
        command -v ufw >/dev/null 2>&1 && $S ufw status 2>/dev/null | grep -qi 'Status: active' || { echo "RESULT noufw"; exit 0; }
        \(rules.joined(separator: "\n"))
        echo "RESULT allowed"

        """
    }

    static func manifestJSON(_ m: AppManifest, dir: String) -> String {
        var m = m
        m.dir = "__DIR__"
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return String(decoding: (try? e.encode(m)) ?? Data(), as: UTF8.self)
    }

    /// Last step: the manifest marks the app as installed.
    static func finish(_ m: AppManifest) -> String {
        header + appVars(m.id) + """
        M=$(cat <<'SIGIL_MANIFEST'
        \(manifestJSON(m, dir: ""))
        SIGIL_MANIFEST
        )
        printf '%s\\n' "$M" | sed "s#__DIR__#$DIR#" | $S tee "$DIR/sigil.json" >/dev/null && $S chmod 644 "$DIR/sigil.json"
        echo "RESULT finished"

        """
    }

    static func action(_ id: String, _ action: AppAction) -> String {
        let body: String
        switch action {
        case .start: body = #"run $C -p "$P" start"#
        case .stop: body = #"run $C -p "$P" stop"#
        case .restart: body = #"run $C -p "$P" restart"#
        case .update: body = #"run $C -p "$P" pull && run $C -p "$P" up -d --remove-orphans"#
        case .logs: body = #"$C -p "$P" logs --tail 300 --timestamps 2>&1 | tail -n 600; true"#
        }
        return header + appVars(id) + #"cd "$DIR" || { echo "RESULT missing"; exit 0; }"# + "\n" + body + "\necho \"RESULT rc=$?\"\n"
    }

    /// Stops the app and moves its folder aside. Data volumes and files are kept, nothing is deleted.
    static func remove(_ id: String) -> String {
        header + appVars(id) + #"""
        [ -d "$DIR" ] || { echo "RESULT missing"; exit 0; }
        if [ "$APP" = caddy ] && [ -n "$(ls "$DIR/sites" 2>/dev/null)" ]; then echo "RESULT inuse"; exit 0; fi
        (cd "$DIR" && run $C -p "$P" down --remove-orphans) || { echo "RESULT downfail"; exit 0; }
        if [ -f "$BASE/caddy/sites/$APP.caddy" ]; then
          $S rm -f "$BASE/caddy/sites/$APP.caddy"
          $D exec sigil-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1
        fi
        if [ "$ADMIN" = 1 ] && command -v ufw >/dev/null 2>&1; then
          n=0
          while [ $n -lt 10 ]; do
            num=$($S ufw status numbered 2>/dev/null | grep "# sigil-app:$APP\$" | head -n 1 | sed 's/^\[ *\([0-9]*\)\].*/\1/')
            [ -n "$num" ] || break
            $S ufw --force delete "$num" >/dev/null; n=$((n+1))
          done
        fi
        KEPT="$BASE/.removed/$APP-$(date +%Y%m%d-%H%M%S)"
        $S mkdir -p "$BASE/.removed" && $S mv "$DIR" "$KEPT" && $S rm -f "$KEPT/sigil.json"
        echo "RESULT removed $KEPT"

        """#
    }

    /// Installs Docker (official get.docker.com script; apk on Alpine) and the compose plugin, adds the user to the
    /// docker group. Needs root or password-less sudo.
    static let installDocker = #"""
    S=""
    if [ "$(id -u)" -ne 0 ]; then if sudo -n true 2>/dev/null; then S="sudo -n"; else echo "RESULT noadmin"; exit 0; fi; fi
    [ -r /etc/os-release ] && . /etc/os-release
    run() { OUT=$("$@" 2>&1); RC=$?; printf '%s\n' "$OUT" | tail -n 25; return $RC; }
    if ! command -v docker >/dev/null 2>&1; then
      case "$ID $ID_LIKE" in
        *alpine*) run $S apk add --no-cache docker docker-cli-compose && $S rc-update add docker default >/dev/null && run $S service docker start ;;
        *)
          F=$(mktemp)
          if command -v curl >/dev/null 2>&1; then curl -fsSL https://get.docker.com -o "$F"
          elif command -v wget >/dev/null 2>&1; then wget -qO "$F" https://get.docker.com
          else echo "RESULT nodownloader"; exit 0; fi
          run $S sh "$F"; rm -f "$F" ;;
      esac
    fi
    $S systemctl enable --now docker >/dev/null 2>&1 || true
    if ! $S docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        run $S env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-plugin \
          || { $S apt-get update -q >/dev/null 2>&1; run $S env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-v2 \
          || run $S env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-plugin; }
      elif command -v dnf >/dev/null 2>&1; then run $S dnf install -y docker-compose-plugin
      elif command -v apk >/dev/null 2>&1; then run $S apk add --no-cache docker-cli-compose
      fi
    fi
    [ "$(id -u)" -ne 0 ] && $S usermod -aG docker "$(id -un)" 2>/dev/null
    if $S docker info >/dev/null 2>&1 && $S docker compose version >/dev/null 2>&1; then echo "RESULT ok"
    elif $S docker info >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then echo "RESULT ok"
    else echo "RESULT failed"; fi
    """#

    static func result(_ out: String) -> String {
        out.split(whereSeparator: \.isNewline).last { $0.hasPrefix("RESULT ") }.map { String($0.dropFirst(7)) } ?? ""
    }

    /// The output above the RESULT line, for error messages.
    static func details(_ out: String) -> String {
        out.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("RESULT ") }.suffix(12).joined(separator: "\n")
    }

    static func failure(_ result: String, _ out: String) -> DeckError {
        switch result.split(separator: " ").first.map(String.init) ?? "" {
        case "nodocker": return .invalid("Bu sunucuda Docker yok ya da bu kullanıcı kullanamıyor.")
        case "nocompose": return .invalid("Docker var ama docker compose yok.")
        case "exists": return .invalid("Bu uygulama bu sunucuda zaten kurulu.")
        case "nowrite": return .invalid("Uygulama klasörü oluşturulamadı.")
        case "webports": return .invalid("80 ya da 443 portunu başka bir program (nginx, apache…) kullanıyor; Caddy başlatılamaz. Alan adı yerine tünel ya da port seç.")
        case "caddyfail": return .ssh("Caddy başlatılamadı:\n" + details(out))
        case "hashfail": return .ssh("Caddy şifresi üretilemedi.")
        case "reloadfail": return .ssh("Caddy yeni ayarı kabul etmedi:\n" + details(out))
        case "missing": return .invalid("Uygulama klasörü sunucuda bulunamadı.")
        case "inuse": return .invalid("Caddy hâlâ alan adıyla yayınlanan uygulamalara hizmet veriyor; önce onları kaldır.")
        case "downfail": return .ssh("Uygulama durdurulamadı:\n" + details(out))
        case "noadmin": return .invalid("Docker kurmak için root ya da şifresiz sudo gerekiyor.")
        case "nodownloader": return .invalid("Sunucuda curl ya da wget yok.")
        case "noroot": return .invalid("Güvenlik duvarı kuralı için root ya da şifresiz sudo gerekiyor.")
        case "noufw": return .invalid("Güvenlik duvarı (ufw) açık değil; port herkese açık kalırdı. Önce sunucu ekranındaki SSH izin listesi kartından güvenlik duvarını aç.")
        case "ufwfail": return .ssh("Güvenlik duvarı kuralı eklenemedi:\n" + details(out))
        default: return .ssh(details(out).isEmpty ? "Sunucu beklenen yanıtı vermedi." : details(out))
        }
    }
}

// MARK: - Workflows

extension DeckModel {
    /// All recipes: the built-in catalogue plus the user's own.
    public var allRecipes: [AppRecipe] { AppCatalog.builtIn + customRecipes }

    public func recipe(_ id: String) -> AppRecipe? { allRecipes.first { $0.id == id } }

    public func saveRecipe(_ recipe: AppRecipe) throws {
        guard recipe.isCustom, AppScript.isValidID(recipe.id) else { throw DeckError.invalid("Geçersiz tarif.") }
        if AppCatalog.builtIn.contains(where: { $0.id == recipe.id }) { throw DeckError.invalid("Bu ad hazır bir tarifle çakışıyor.") }
        var list = customRecipes
        if let i = list.firstIndex(where: { $0.id == recipe.id }) { list[i] = recipe } else { list.append(recipe) }
        try RecipeStore(paths: paths).save(list)
        customRecipes = list
    }

    public func deleteRecipe(_ id: String) throws {
        let list = customRecipes.filter { $0.id != id }
        try RecipeStore(paths: paths).save(list)
        customRecipes = list
    }

    func loadRecipes() { customRecipes = RecipeStore(paths: paths).load() }

    private func appScript(_ id: UUID, _ script: String, timeout: TimeInterval = 120) async throws -> String {
        guard let s = server(id) else { throw DeckError.notFound }
        let r = try await runShared(id, "sh -s", stdin: script, timeout: timeout)
        if r.exitCode == 255 { throw remote.failure(r, auth(s.store, s.keyFileName)) }
        if r.timedOut { throw DeckError.ssh("Sunucu \(Int(timeout)) saniye içinde bitiremedi.") }
        return r.stdout
    }

    /// Reads the server (read-only) and refreshes the list of installed apps.
    public func appHost(_ id: UUID) async throws -> AppHostState {
        let state = AppScript.parse(probe: try await appScript(id, AppScript.probe, timeout: 60))
        update(id) { $0.apps = state.apps }
        return state
    }

    /// Installs Docker and docker compose.
    public func installDocker(_ id: UUID, progress: @MainActor (String) -> Void = { _ in }) async throws {
        try await withBusy(id, "Docker kuruluyor") {
            progress("Docker kuruluyor (birkaç dakika sürebilir)")
            let out = try await appScript(id, AppScript.installDocker, timeout: 1200)
            guard AppScript.result(out) == "ok" else { throw AppScript.failure(AppScript.result(out), out) }
            log(id, .info, "Docker ve docker compose kuruldu.")
        }
    }

    /// Installs `recipe` with the given access. Generated passwords go to the server's `.env` and this Mac's Keychain.
    public func installApp(_ id: UUID, _ recipe: AppRecipe, access: AppAccess, port: Int?, domain: String? = nil,
                           inputs: [String: String] = [:], allowFrom: [String] = [],
                           progress: @MainActor (String) -> Void = { _ in }) async throws -> AppInstallReport {
        guard let s = server(id) else { throw DeckError.notFound }
        guard recipe.access.contains(access) else { throw DeckError.invalid("Bu uygulama bu erişim şekliyle kurulamaz.") }
        guard AppScript.isValidID(recipe.id), !recipe.isDockerEngine else { throw DeckError.invalid("Geçersiz tarif.") }
        let port = recipe.port == nil ? nil : port
        if let port, !(1...65535).contains(port) { throw DeckError.invalid("Port 1–65535 arasında olmalı.") }
        let domain = access == .domain ? try AppScript.validateDomain(domain ?? "") : nil
        guard access != .domain || (port != nil && recipe.http) else { throw DeckError.invalid("Alan adıyla yalnızca web uygulamaları yayınlanır.") }
        let inputValues = try (recipe.inputs ?? []).map { ($0.name, try $0.validate(inputs[$0.name] ?? "")) }
        let allowed = access == .allowList ? try AppScript.allowedAddresses(allowFrom) : []
        guard access != .allowList || port != nil else { throw DeckError.invalid("Bu uygulamanın açılacak bir portu yok.") }

        return try await withBusy(id, "\(recipe.name) kuruluyor") {
            var secrets: [String: String] = [:]
            for name in recipe.secretNames(for: access) { secrets[name] = AppScript.secret() }

            var tunnel: TunnelProfile?
            if access == .tunnel, let port {
                tunnel = TunnelProfile(name: recipe.name, localPort: freeLocalPort(near: port), remoteHost: "127.0.0.1", remotePort: port)
            }
            let url: String
            switch access {
            case .tunnel: url = "http://localhost:\(tunnel?.localPort ?? port ?? 0)"
            case .domain: url = "https://\(domain!)"
            case .publicPort, .allowList: url = "http://\(s.host.contains(":") ? "[\(s.host)]" : s.host):\(port ?? 0)"
            }
            var vars = [
                "BIND": access.listensOutside ? "" : "127.0.0.1:", "ADDR": access.listensOutside ? "" : "127.0.0.1",
                "PORT": port.map(String.init) ?? "",
                "URL": url, "HTTPS": access == .domain ? "true" : "false", "DOMAIN": domain ?? "",
                "SERVER": s.alias, "TZ": TimeZone.current.identifier,
            ]
            for (name, value) in inputValues where vars[name] == nil { vars[name] = value }
            let plan = AppScript.Plan(recipe: recipe, access: access, port: port, domain: domain, secrets: secrets, vars: vars)
            func step(_ script: String, timeout: TimeInterval = 180, expect: String) async throws -> String {
                let out = try await appScript(id, script, timeout: timeout)
                let r = AppScript.result(out)
                guard r.hasPrefix(expect) else { throw AppScript.failure(r, out) }
                return out
            }

            if access == .allowList, let port {
                // Before anything listens: without an active ufw the port would be open to everyone.
                progress("Güvenlik duvarı yalnızca \(allowed.joined(separator: ", ")) için açılıyor")
                _ = try await step(AppScript.allowFrom(recipe.id, port: port, addresses: allowed), expect: "allowed")
            }
            progress("Dosyalar hazırlanıyor")
            _ = try await step(AppScript.write(plan), expect: "written")
            if !secrets.isEmpty { appSecrets.save(secrets, account: Self.appAccount(id, recipe.id)) }
            progress("İmajlar indiriliyor (ilk kurulumda birkaç dakika sürebilir)")
            _ = try await step(AppScript.pull(recipe.id), timeout: 1500, expect: "rc=0")
            progress("Başlatılıyor")
            _ = try await step(AppScript.up(recipe.id), timeout: 300, expect: "rc=0")
            var warnings: [String] = []
            progress("Yanıt vermesi bekleniyor")
            let waited = try await appScript(id, AppScript.wait(recipe.id, port: port, http: recipe.http), timeout: 150)
            if AppScript.result(waited) != "ready" {
                warnings.append("Uygulama 90 saniyede yanıt vermedi; hâlâ açılıyor olabilir. Günlüklere bak:\n" + AppScript.details(waited))
            }
            if let script = AppScript.postInstall(plan) {
                progress("Ilk ayarlar yapılıyor")
                _ = try await appScript(id, script, timeout: 180)
            }
            if access == .domain, let domain, let port {
                progress("\(domain) için HTTPS ayarlanıyor")
                _ = try await step(AppScript.publish(recipe.id, domain: domain, port: port, password: secrets[AppScript.proxyPasswordName]),
                                   timeout: 300, expect: "published")
            }
            if access == .publicPort, let port {
                _ = try await step(AppScript.openPort(recipe.id, port: port), expect: "opened")
            }
            let manifest = AppManifest(id: recipe.id, name: recipe.name, symbol: recipe.symbol, port: port, access: access,
                                       domain: domain, http: recipe.http, dir: "", custom: recipe.isCustom,
                                       allowFrom: allowed.isEmpty ? nil : allowed)
            _ = try await step(AppScript.finish(manifest), expect: "finished")
            if let tunnel {
                update(id) {
                    var list = $0.tunnels ?? []
                    list.removeAll { $0.remotePort == tunnel.remotePort && ["127.0.0.1", "localhost"].contains($0.remoteHost) }
                    list.append(tunnel)
                    $0.tunnels = list
                }
            }
            update(id) {
                var apps = ($0.apps ?? []).filter { $0.id != recipe.id }
                apps.append(InstalledApp(manifest: manifest, running: 1, total: 1))
                $0.apps = apps.sorted { $0.manifest.name < $1.manifest.name }
            }
            log(id, .info, "Uygulama kuruldu: \(recipe.name) (\(access.title)\(domain.map { ", \($0)" } ?? ""))")
            return AppInstallReport(manifest: manifest, warnings: warnings)
        }
    }

    public func appAction(_ id: UUID, _ app: InstalledApp, _ action: AppAction) async throws -> String {
        guard AppScript.isValidID(app.id) else { throw DeckError.invalid("Geçersiz uygulama.") }
        let run = { [self] in try await appScript(id, AppScript.action(app.id, action), timeout: action == .update ? 1500 : 180) }
        let out = action == .logs ? try await run() : try await withBusy(id, "\(app.manifest.name): \(Self.actionTitle(action))", run)
        let r = AppScript.result(out)
        guard r.hasPrefix("rc=") else { throw AppScript.failure(r, out) }
        if action == .logs { return out.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("RESULT ") }.joined(separator: "\n") }
        guard r == "rc=0" else { throw DeckError.ssh(AppScript.details(out)) }
        log(id, .info, "\(app.manifest.name): \(Self.actionTitle(action))")
        _ = try? await appHost(id)
        return out
    }

    static func actionTitle(_ a: AppAction) -> String {
        switch a {
        case .start: return "başlatıldı"
        case .stop: return "durduruldu"
        case .restart: return "yeniden başlatıldı"
        case .update: return "güncellendi"
        case .logs: return "günlükler"
        }
    }

    /// Stops the app and moves its folder aside; returns where its files were kept. Volumes stay.
    public func removeApp(_ id: UUID, _ app: InstalledApp) async throws -> String {
        guard AppScript.isValidID(app.id) else { throw DeckError.invalid("Geçersiz uygulama.") }
        return try await withBusy(id, "\(app.manifest.name) kaldırılıyor") {
            let out = try await appScript(id, AppScript.remove(app.id), timeout: 240)
            let r = AppScript.result(out)
            guard r.hasPrefix("removed") else { throw AppScript.failure(r, out) }
            let kept = String(r.dropFirst("removed ".count))
            if let port = app.manifest.port, app.manifest.access == .tunnel {
                let ids = (server(id)?.tunnels ?? []).filter { $0.remotePort == port && $0.remoteHost == "127.0.0.1" }.map(\.id)
                for t in ids { deleteTunnel(id, t) }
            }
            appSecrets.delete(account: Self.appAccount(id, app.id))
            update(id) { $0.apps?.removeAll { $0.id == app.id } }
            log(id, .warning, "Uygulama kaldırıldı: \(app.manifest.name). Dosyaları \(kept) içinde, verileri Docker volume’larında duruyor.")
            return kept
        }
    }

    static func appAccount(_ server: UUID, _ app: String) -> String { "\(server.uuidString)/\(app)" }

    /// The tunnel Sigil made for an app reached through one.
    public func appTunnel(_ id: UUID, _ app: InstalledApp) -> TunnelProfile? {
        guard app.manifest.access == .tunnel, let port = app.manifest.port else { return nil }
        return server(id)?.tunnels?.first { $0.remotePort == port && ["127.0.0.1", "localhost"].contains($0.remoteHost) }
    }

    /// Address, URL and credentials for an installed app (passwords from this Mac's Keychain).
    public func appConnection(_ id: UUID, _ app: InstalledApp) -> AppConnection {
        guard let s = server(id) else { return AppConnection(url: nil, address: nil, lines: []) }
        let m = app.manifest
        let host = s.host.contains(":") ? "[\(s.host)]" : s.host
        var address: String?
        switch m.access {
        case .tunnel: address = m.port.map { _ in "localhost:\(appTunnel(id, app)?.localPort ?? m.port!)" }
        case .domain: address = m.domain
        case .publicPort, .allowList: address = m.port.map { "\(host):\($0)" }
        }
        var url: String?
        if m.http, let address { url = m.access == .domain ? "https://\(address)" : "http://\(address)" }
        let secrets = appSecrets.load(account: Self.appAccount(id, m.id)) ?? [:]
        var vars = secrets
        vars["ADDRESS"] = address ?? ""
        vars["URL"] = url ?? ""
        var lines: [AppConnection.Line] = []
        for line in recipe(m.id)?.info ?? [] {
            let filled = AppScript.fill(line, vars)
            if filled.contains("{{") { continue }   // a secret this Mac no longer has
            let secret = secrets.values.contains { filled.contains($0) }
            if let colon = filled.range(of: ": ") {
                lines.append(.init(label: String(filled[..<colon.lowerBound]), value: String(filled[colon.upperBound...]), isSecret: secret))
            } else { lines.append(.init(label: "", value: filled, isSecret: secret)) }
        }
        if let pw = secrets[AppScript.proxyPasswordName] {
            lines.append(.init(label: "Kullanıcı (Caddy)", value: "sigil", isSecret: false))
            lines.append(.init(label: "Şifre (Caddy)", value: pw, isSecret: true))
        }
        return AppConnection(url: url, address: address, lines: lines)
    }

    /// Opens the way to the app (its tunnel, when it has one) and returns the URL to show.
    public func prepareApp(_ id: UUID, _ app: InstalledApp) async throws -> String? {
        if let t = appTunnel(id, app), activeTunnels[t.id] == nil { try await startTunnel(id, t.id) }
        else if app.manifest.access == .tunnel, appTunnel(id, app) == nil, let port = app.manifest.port {
            let t = TunnelProfile(name: app.manifest.name, localPort: freeLocalPort(near: port), remoteHost: "127.0.0.1", remotePort: port)
            update(id) { $0.tunnels = ($0.tunnels ?? []) + [t] }
            try await startTunnel(id, t.id)
        }
        return appConnection(id, app).url
    }

    /// A port on this Mac not used by a saved tunnel nor by anything listening.
    func freeLocalPort(near port: Int) -> Int {
        let used = Set(servers.flatMap { ($0.tunnels ?? []).map(\.localPort) })
        let candidates = (port >= 1024 ? [port] : []) + Array(18000...18999)
        return candidates.first { !used.contains($0) && !RemoteService.isListening(port: $0) } ?? 18999
    }
}
