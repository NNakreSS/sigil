import Foundation

/// A ready-made shell command, explained in plain Turkish, so nobody has to remember flags.
///
/// Templates use `{{name}}` or `{{name=default}}` for the parts the user fills in. Commands are only ever typed at
/// the prompt for the user to read; nothing in the library runs on its own.
public struct CommandTemplate: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case system = "Sistem", disk = "Disk", processes = "Bellek ve işlemler", network = "Ağ"
        case services = "Servisler", logs = "Loglar", packages = "Paketler", users = "Kullanıcılar"
        case files = "Dosyalar", security = "Güvenlik", docker = "Docker", nginx = "Nginx", apache = "Apache"
        case databases = "Veritabanları", node = "Node / PM2", git = "Git", ssl = "SSL", cron = "Zamanlanmış görevler"

        public var symbol: String {
            switch self {
            case .system: return "cpu"
            case .disk: return "internaldrive"
            case .processes: return "memorychip"
            case .network: return "network"
            case .services: return "gearshape.2"
            case .logs: return "doc.text.magnifyingglass"
            case .packages: return "shippingbox"
            case .users: return "person.2"
            case .files: return "folder"
            case .security: return "lock.shield"
            case .docker: return "cube.box"
            case .nginx, .apache: return "globe"
            case .databases: return "cylinder.split.1x2"
            case .node: return "hexagon"
            case .git: return "arrow.triangle.branch"
            case .ssl: return "lock.doc"
            case .cron: return "clock.arrow.circlepath"
            }
        }
    }

    public enum Family: String, Sendable { case debian, rhel }

    public struct Parameter: Hashable, Sendable {
        public let name: String
        public let defaultValue: String?
    }

    public let title: String
    public let template: String
    public let category: Category
    /// The server must have at least one of these commands (empty: any server).
    public let requires: [String]
    public let family: Family?
    /// Changes something on the server (restart, install, delete…), as opposed to only looking.
    public let changesSystem: Bool

    public var id: String { category.rawValue + "|" + template }

    public init(_ title: String, _ template: String, _ category: Category, requires: [String] = [],
                family: Family? = nil, changes: Bool = false) {
        self.title = title
        self.template = template
        self.category = category
        self.requires = requires
        self.family = family
        self.changesSystem = changes
    }

    static let placeholder = try! NSRegularExpression(pattern: #"\{\{([^}=]+)(?:=([^}]*))?\}\}"#)

    /// Placeholders in order of first appearance, each once.
    public var parameters: [Parameter] {
        let ns = template as NSString
        var seen = Set<String>()
        var defaults: [String: String] = [:]
        var order: [String] = []
        for m in Self.placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if seen.insert(name).inserted { order.append(name) }
            if m.range(at: 2).location != NSNotFound, defaults[name] == nil { defaults[name] = ns.substring(with: m.range(at: 2)) }
        }
        return order.map { Parameter(name: $0, defaultValue: defaults[$0]) }
    }

    /// The command with every placeholder replaced (missing values fall back to the default, else stay empty).
    public func filled(_ values: [String: String]) -> String {
        let ns = template as NSString
        // A default given at any occurrence applies to all of them.
        let defaults = Dictionary(parameters.compactMap { p in p.defaultValue.map { (p.name, $0) } }, uniquingKeysWith: { a, _ in a })
        var out = ""
        var cursor = 0
        for m in Self.placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out += values[name].flatMap { $0.isEmpty ? nil : $0 } ?? defaults[name] ?? ""
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }

    /// What Tab completion types: everything up to the first placeholder, so the user continues from there.
    public var typedPrefix: String {
        let ns = template as NSString
        guard let m = Self.placeholder.firstMatch(in: template, range: NSRange(location: 0, length: ns.length)) else {
            return template
        }
        return ns.substring(to: m.range.location)
    }

    /// Fits a server with these tools and OS family (nil profile: unknown, everything fits).
    public func fits(_ profile: ServerProfile?) -> Bool {
        guard let profile else { return true }
        if let family, let serverFamily = profile.family, family != serverFamily { return false }
        return requires.isEmpty || requires.contains { profile.tools.contains($0) }
    }
}

/// What a server runs, learnt from the health probe.
public struct ServerProfile: Hashable, Sendable {
    public var family: CommandTemplate.Family?
    public var tools: Set<String>

    public init(family: CommandTemplate.Family?, tools: Set<String>) {
        self.family = family
        self.tools = tools
    }

    public init?(_ health: ServerHealth?) {
        guard let health, let tools = health.tools else { return nil }
        self.tools = Set(tools)
        let ids = (health.osFamily ?? "").lowercased()
        family = ids.contains("debian") || ids.contains("ubuntu") ? .debian
            : (ids.contains("rhel") || ids.contains("fedora") || ids.contains("centos") ? .rhel : nil)
    }
}

public enum CommandLibrary {
    /// Probed by the health script: `tool=<name>` for each of these that is installed.
    public static let probedTools = [
        "docker", "nginx", "apache2", "httpd", "mysql", "mariadb", "psql", "redis-cli", "pm2", "node", "php", "git",
        "ufw", "firewall-cmd", "fail2ban-client", "certbot", "apt", "dnf", "yum", "htop", "iostat", "dig", "nc",
    ]

    public static func relevant(for profile: ServerProfile?) -> [CommandTemplate] {
        all.filter { $0.fits(profile) }
    }

    /// Ranked matches for a palette query: title and command, then category.
    public static func search(_ query: String, in commands: [CommandTemplate]) -> [CommandTemplate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands }
        func score(_ c: CommandTemplate) -> Int? {
            if c.template.lowercased().hasPrefix(q.lowercased()) { return 0 }
            if c.title.localizedCaseInsensitiveContains(q) { return 1 }
            if c.template.localizedCaseInsensitiveContains(q) { return 2 }
            if c.category.rawValue.localizedCaseInsensitiveContains(q) { return 3 }
            return nil
        }
        return commands.compactMap { c in score(c).map { (c, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    public static let all: [CommandTemplate] = [
        // Sistem
        .init("Sistem özeti", "hostnamectl", .system),
        .init("Açık kalma süresi ve yük", "uptime", .system),
        .init("Çekirdek ve işletim sistemi", "uname -a && cat /etc/os-release", .system),
        .init("CPU bilgisi", "lscpu", .system),
        .init("Saat ve saat dilimi", "timedatectl", .system),
        .init("Şu an bağlı olanlar", "w", .system),
        .init("Son girişler", "last -n 20", .system),
        .init("Yeniden başlatma gerekiyor mu?", #"[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs 2>/dev/null || echo "Gerekmiyor""#, .system, family: .debian),
        .init("Sunucuyu yeniden başlat", "sudo reboot", .system, changes: true),

        // Disk
        .init("Disk kullanımı", "df -h", .disk),
        .init("En büyük klasörler", "sudo du -xh --max-depth=1 {{klasör=/}} 2>/dev/null | sort -rh | head -20", .disk),
        .init("100 MB’tan büyük dosyalar", "sudo find {{klasör=/}} -xdev -type f -size +100M -exec ls -lh {} + 2>/dev/null | sort -k5 -rh | head -20", .disk),
        .init("Klasör boyutu", "du -sh {{klasör=.}}", .disk),
        .init("inode kullanımı", "df -i", .disk),
        .init("Diskler ve bölümler", "lsblk -f", .disk),
        .init("Disk okuma/yazma hızı", "iostat -xz 1 3", .disk, requires: ["iostat"]),

        // Bellek ve işlemler
        .init("Bellek kullanımı", "free -h", .processes),
        .init("En çok CPU kullananlar", "ps aux --sort=-%cpu | head -15", .processes),
        .init("En çok bellek kullananlar", "ps aux --sort=-%mem | head -15", .processes),
        .init("Canlı işlem izleme", "htop", .processes, requires: ["htop"]),
        .init("Canlı işlem izleme", "top", .processes),
        .init("İşlem ara", "pgrep -af {{ad}}", .processes),
        .init("Bir portu kullanan işlem", "sudo ss -tlnp | grep :{{port}}", .processes),
        .init("İşlemi sonlandır", "kill {{pid}}", .processes, changes: true),

        // Ağ
        .init("Dinlenen portlar", "sudo ss -tulpn", .network),
        .init("Etkin bağlantılar", "ss -tunap | head -40", .network),
        .init("IP adresleri", "ip -br addr", .network),
        .init("Yönlendirme tablosu", "ip route", .network),
        .init("Sunucunun genel IP’si", "curl -s https://api.ipify.org; echo", .network),
        .init("Alan adını çözümle", "dig +short {{alan adı}}", .network, requires: ["dig"]),
        .init("Alan adını çözümle", "getent hosts {{alan adı}}", .network),
        .init("Bağlantı testi", "ping -c 4 {{adres}}", .network),
        .init("Bir porta erişilebiliyor mu?", "nc -zv {{adres}} {{port}}", .network, requires: ["nc"]),
        .init("Web sitesinin yanıt başlıkları", "curl -sI {{adres=https://}}", .network),

        // Servisler
        .init("Çalışan servisler", "systemctl list-units --type=service --state=running --no-pager", .services),
        .init("Çöken servisler", "systemctl --failed --no-pager", .services),
        .init("Servis durumu", "systemctl status {{servis}} --no-pager", .services),
        .init("Servisin canlı logu", "journalctl -u {{servis}} -f", .services),
        .init("Servisi yeniden başlat", "sudo systemctl restart {{servis}}", .services, changes: true),
        .init("Servisi yeniden yükle", "sudo systemctl reload {{servis}}", .services, changes: true),
        .init("Servisi durdur", "sudo systemctl stop {{servis}}", .services, changes: true),
        .init("Servisi başlat ve açılışta etkinleştir", "sudo systemctl enable --now {{servis}}", .services, changes: true),
        .init("Zamanlayıcılar (timer)", "systemctl list-timers --no-pager", .services),

        // Loglar
        .init("Son sistem logları", "journalctl -n 100 --no-pager", .logs),
        .init("Bugünkü hatalar", "journalctl -p err --since today --no-pager", .logs),
        .init("Canlı sistem logu", "journalctl -f", .logs),
        .init("Son açılışın logu", "journalctl -b --no-pager | tail -100", .logs),
        .init("Son bir saatteki SSH girişleri", #"journalctl -u ssh --since "1 hour ago" --no-pager"#, .logs, family: .debian),
        .init("Son bir saatteki SSH girişleri", #"journalctl -u sshd --since "1 hour ago" --no-pager"#, .logs, family: .rhel),
        .init("Başarısız giriş denemeleri", "sudo lastb -n 20", .logs),
        .init("Çekirdek mesajları", "sudo dmesg -T | tail -50", .logs),
        .init("Bir dosyayı canlı izle", "sudo tail -f {{dosya=/var/log/syslog}}", .logs),
        .init("Logların kapladığı yer", "journalctl --disk-usage", .logs),
        .init("7 günden eski logları sil", "sudo journalctl --vacuum-time=7d", .logs, changes: true),

        // Paketler
        .init("Bekleyen güncellemeler", "apt list --upgradable 2>/dev/null", .packages, requires: ["apt"]),
        .init("Güncelle", "sudo apt update && sudo apt upgrade", .packages, requires: ["apt"], changes: true),
        .init("Paket ara", "apt search {{ad}}", .packages, requires: ["apt"]),
        .init("Paket kur", "sudo apt install {{paket}}", .packages, requires: ["apt"], changes: true),
        .init("Paket kaldır", "sudo apt remove {{paket}}", .packages, requires: ["apt"], changes: true),
        .init("Kurulu mu?", "dpkg -l | grep -i {{ad}}", .packages, requires: ["apt"]),
        .init("Gereksiz paketleri temizle", "sudo apt autoremove", .packages, requires: ["apt"], changes: true),
        .init("Bekleyen güncellemeler", "dnf check-update", .packages, requires: ["dnf"]),
        .init("Güncelle", "sudo dnf upgrade", .packages, requires: ["dnf"], changes: true),
        .init("Paket ara", "dnf search {{ad}}", .packages, requires: ["dnf"]),
        .init("Paket kur", "sudo dnf install {{paket}}", .packages, requires: ["dnf"], changes: true),
        .init("Kurulu mu?", "rpm -qa | grep -i {{ad}}", .packages, requires: ["dnf", "yum"]),

        // Kullanıcılar
        .init("Ben kimim, hangi gruplardayım?", "id", .users),
        .init("Normal kullanıcılar", "getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'", .users),
        .init("sudo yetkisi olanlar", "getent group sudo", .users, family: .debian),
        .init("sudo yetkisi olanlar", "getent group wheel", .users, family: .rhel),
        .init("Yetkili SSH anahtarları", "cat ~/.ssh/authorized_keys", .users),
        .init("Kullanıcı ekle", "sudo adduser {{kullanıcı}}", .users, changes: true),
        .init("Kullanıcıya sudo ver", "sudo usermod -aG sudo {{kullanıcı}}", .users, family: .debian, changes: true),

        // Dosyalar
        .init("Ayrıntılı liste", "ls -lah {{yol=.}}", .files),
        .init("Dosya ara (ada göre)", #"find {{klasör=.}} -name "{{desen=*.log}}" 2>/dev/null | head -50"#, .files),
        .init("Dosyaların içinde ara", #"grep -rn "{{metin}}" {{klasör=.}} 2>/dev/null | head -50"#, .files),
        .init("Son değişen dosyalar", "find {{klasör=.}} -type f -mmin -{{dakika=60}} 2>/dev/null | head -50", .files),
        .init("Klasörü arşivle", "tar -czf {{arşiv=yedek.tar.gz}} {{klasör}}", .files),
        .init("Arşivi aç", "tar -xzf {{arşiv}}", .files, changes: true),
        .init("Dosyanın başı", "head -n {{satır=50}} {{dosya}}", .files),
        .init("Dosyanın sonu", "tail -n {{satır=50}} {{dosya}}", .files),

        // Güvenlik
        .init("Güvenlik duvarı durumu", "sudo ufw status verbose", .security, requires: ["ufw"]),
        .init("Güvenlik duvarında port aç", "sudo ufw allow {{port}}", .security, requires: ["ufw"], changes: true),
        .init("Güvenlik duvarı durumu", "sudo firewall-cmd --list-all", .security, requires: ["firewall-cmd"]),
        .init("fail2ban durumu", "sudo fail2ban-client status sshd", .security, requires: ["fail2ban-client"]),
        .init("fail2ban engelini kaldır", "sudo fail2ban-client set sshd unbanip {{ip}}", .security, requires: ["fail2ban-client"], changes: true),
        .init("Dışarıdan erişilebilen portlar", "sudo ss -tulpn | grep -v -e 127.0.0.1 -e '\\[::1\\]'", .security),
        .init("SSH giriş ayarları", "sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|pubkeyauthentication'", .security),

        // Docker
        .init("Çalışan container’lar", "docker ps", .docker, requires: ["docker"]),
        .init("Tüm container’lar", "docker ps -a", .docker, requires: ["docker"]),
        .init("Container logu (canlı)", "docker logs -f --tail 100 {{container}}", .docker, requires: ["docker"]),
        .init("Container’a gir", "docker exec -it {{container}} sh", .docker, requires: ["docker"]),
        .init("Kaynak kullanımı", "docker stats --no-stream", .docker, requires: ["docker"]),
        .init("Container’ı yeniden başlat", "docker restart {{container}}", .docker, requires: ["docker"], changes: true),
        .init("İmajlar", "docker images", .docker, requires: ["docker"]),
        .init("Compose servisleri", "docker compose ps", .docker, requires: ["docker"]),
        .init("Compose logları (canlı)", "docker compose logs -f --tail 100", .docker, requires: ["docker"]),
        .init("Compose ile ayağa kaldır", "docker compose up -d", .docker, requires: ["docker"], changes: true),
        .init("Docker’ın kapladığı yer", "docker system df", .docker, requires: ["docker"]),
        .init("Kullanılmayanları temizle", "docker system prune", .docker, requires: ["docker"], changes: true),

        // Nginx
        .init("Yapılandırmayı test et", "sudo nginx -t", .nginx, requires: ["nginx"]),
        .init("Test et ve yeniden yükle", "sudo nginx -t && sudo systemctl reload nginx", .nginx, requires: ["nginx"], changes: true),
        .init("Etkin siteler", "ls -l /etc/nginx/sites-enabled/", .nginx, requires: ["nginx"], family: .debian),
        .init("Erişim logu (canlı)", "sudo tail -f /var/log/nginx/access.log", .nginx, requires: ["nginx"]),
        .init("Hata logu (canlı)", "sudo tail -f /var/log/nginx/error.log", .nginx, requires: ["nginx"]),
        .init("Tüm yapılandırma", "sudo nginx -T | less", .nginx, requires: ["nginx"]),

        // Apache
        .init("Yapılandırmayı test et", "sudo apachectl configtest", .apache, requires: ["apache2", "httpd"]),
        .init("Yeniden yükle", "sudo systemctl reload apache2", .apache, requires: ["apache2"], changes: true),
        .init("Yeniden yükle", "sudo systemctl reload httpd", .apache, requires: ["httpd"], changes: true),
        .init("Hata logu (canlı)", "sudo tail -f /var/log/apache2/error.log", .apache, requires: ["apache2"]),
        .init("Hata logu (canlı)", "sudo tail -f /var/log/httpd/error_log", .apache, requires: ["httpd"]),

        // Veritabanları
        .init("MySQL’e bağlan", "sudo mysql", .databases, requires: ["mysql", "mariadb"]),
        .init("MySQL veritabanları", #"sudo mysql -e "SHOW DATABASES;""#, .databases, requires: ["mysql", "mariadb"]),
        .init("MySQL yedeği al", "sudo mysqldump {{veritabanı}} > {{veritabanı}}-$(date +%F).sql", .databases, requires: ["mysql", "mariadb"]),
        .init("PostgreSQL’e bağlan", "sudo -u postgres psql", .databases, requires: ["psql"]),
        .init("PostgreSQL veritabanları", #"sudo -u postgres psql -c '\l'"#, .databases, requires: ["psql"]),
        .init("PostgreSQL yedeği al", "sudo -u postgres pg_dump {{veritabanı}} > {{veritabanı}}-$(date +%F).sql", .databases, requires: ["psql"]),
        .init("Redis çalışıyor mu?", "redis-cli ping", .databases, requires: ["redis-cli"]),
        .init("Redis bellek kullanımı", "redis-cli info memory | head -20", .databases, requires: ["redis-cli"]),

        // Node / PM2
        .init("PM2 uygulamaları", "pm2 ls", .node, requires: ["pm2"]),
        .init("PM2 logları", "pm2 logs --lines 100", .node, requires: ["pm2"]),
        .init("PM2 canlı izleme", "pm2 monit", .node, requires: ["pm2"]),
        .init("PM2 uygulamasını yeniden başlat", "pm2 restart {{uygulama}}", .node, requires: ["pm2"], changes: true),
        .init("Node sürümü", "node -v", .node, requires: ["node"]),

        // Git
        .init("Depo durumu", "git status", .git, requires: ["git"]),
        .init("Son commit’ler", "git log --oneline -15", .git, requires: ["git"]),
        .init("Değişiklik özeti", "git diff --stat", .git, requires: ["git"]),
        .init("Güncel kodu çek", "git pull --ff-only", .git, requires: ["git"], changes: true),

        // SSL
        .init("Sertifikalar", "sudo certbot certificates", .ssl, requires: ["certbot"]),
        .init("Yenilemeyi dene (değiştirmez)", "sudo certbot renew --dry-run", .ssl, requires: ["certbot"]),
        .init("Bir sitenin sertifika tarihleri", "echo | openssl s_client -connect {{alan adı}}:443 -servername {{alan adı}} 2>/dev/null | openssl x509 -noout -dates", .ssl),

        // Zamanlanmış görevler
        .init("Cron görevlerim", "crontab -l", .cron),
        .init("Cron görevlerini düzenle", "crontab -e", .cron, changes: true),
        .init("Sistem cron klasörleri", "ls -l /etc/cron.d /etc/cron.daily", .cron),
    ]
}

/// Tab completion at the shell prompt: what has been typed, and the command it most likely continues into.
public enum CommandCompletion {
    public struct Candidate: Hashable, Sendable {
        /// What ends up typed after completing (up to the first blank of a template).
        public let text: String
        /// Shown in the hint: the whole command, blanks as ‹name›.
        public let display: String
        public let title: String

        public init(text: String, display: String, title: String) {
            self.text = text
            self.display = display
            self.title = title
        }
    }

    /// Candidates for a server: the user's saved commands, then the library commands that fit it.
    public static func candidates(saved: [QuickAction], profile: ServerProfile?) -> [Candidate] {
        var seen = Set<String>()
        let all = saved.map { Candidate(text: $0.command, display: $0.command, title: $0.name) }
            + CommandLibrary.relevant(for: profile).map {
                Candidate(text: $0.typedPrefix,
                          display: $0.template.replacingOccurrences(of: "{{", with: "‹").replacingOccurrences(of: "}}", with: "›"),
                          title: $0.title)
            }
        return all.filter { seen.insert($0.text).inserted }
    }

    /// The command typed so far on a prompt line, or nil when this does not look like a prompt with the cursor at
    /// the end of the input (text after the cursor, no "$ " / "# " prompt marker).
    public static func typedInput(beforeCursor: String, afterCursor: String) -> String? {
        guard afterCursor.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let dollar = beforeCursor.range(of: "$ ", options: .backwards)
        let hash = beforeCursor.range(of: "# ", options: .backwards)
        guard let marker = [dollar, hash].compactMap({ $0 }).max(by: { $0.upperBound < $1.upperBound }) else { return nil }
        let input = String(beforeCursor[marker.upperBound...])
        return input.trimmingCharacters(in: .whitespaces).isEmpty ? nil : input
    }

    /// Shortest candidate that continues `input` (at least two characters typed).
    public static func best(for input: String, in candidates: [Candidate]) -> Candidate? {
        guard input.count >= 2 else { return nil }
        return candidates
            .filter { $0.text.hasPrefix(input) && $0.text.count > input.count }
            .min { $0.text.count < $1.text.count }
    }
}
