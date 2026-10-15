import Foundation

/// A read-only snapshot of a server's condition.
public struct ServerHealth: Codable, Hashable, Sendable {
    public struct Certificate: Codable, Hashable, Sendable {
        public var name: String
        public var expires: Date
    }

    public struct FailedUnit: Codable, Hashable, Sendable {
        public var name: String
        public var description: String
    }

    public var collectedAt: Date
    public var os: String?
    public var uptimeSeconds: Double?
    public var load: [Double]?
    public var cpus: Int?
    public var memTotalKB: Double?
    public var memAvailableKB: Double?
    public var diskTotalKB: Double?
    public var diskUsedKB: Double?
    public var updates: Int?
    public var securityUpdates: Int?
    public var rebootRequired: Bool?
    public var failedUnits: Int?
    /// Which units failed (systemctl --failed), first 20.
    public var failedUnitList: [FailedUnit]?
    /// Packages that asked for the reboot (/var/run/reboot-required.pkgs), first 10.
    public var rebootPackages: [String]?
    /// Packages with a pending security update, first 20.
    public var securityPackages: [String]?
    public var certificates: [Certificate]

    public var diskUsage: Double? {
        guard let t = diskTotalKB, let u = diskUsedKB, t > 0 else { return nil }
        return u / t
    }

    public var memoryUsage: Double? {
        guard let t = memTotalKB, let a = memAvailableKB, t > 0 else { return nil }
        return max(0, min(1, (t - a) / t))
    }

    /// Load relative to CPU count (1.0 = every core busy).
    public var loadRatio: Double? {
        guard let l = load?.first, let c = cpus, c > 0 else { return nil }
        return l / Double(c)
    }

    public func daysLeft(_ cert: Certificate, now: Date = Date()) -> Int {
        Int((cert.expires.timeIntervalSince(now) / 86400).rounded(.down))
    }

    /// Short human sentences for things that need doing.
    public func problems(now: Date = Date()) -> [String] {
        var out: [String] = []
        if let d = diskUsage, d >= 0.9 { out.append("Disk %\(Int(d * 100)) dolu") }
        if let m = memoryUsage, m >= 0.95 { out.append("Bellek %\(Int(m * 100)) dolu") }
        if rebootRequired == true { out.append("Yeniden başlatma gerekiyor") }
        if let s = securityUpdates, s > 0 { out.append("\(s) güvenlik güncellemesi bekliyor") }
        if let f = failedUnits, f > 0 {
            let names = (failedUnitList ?? []).map(\.name)
            out.append(names.isEmpty ? "\(f) servis çalışmıyor" : "Çalışmayan servis: " + names.joined(separator: ", "))
        }
        for c in certificates where daysLeft(c, now: now) < 14 {
            out.append("\(c.name) sertifikası \(max(0, daysLeft(c, now: now))) gün içinde bitiyor")
        }
        return out
    }
}

/// One point in a server's metric history (kept small: the last 48 samples).
public struct HealthSample: Codable, Hashable, Sendable {
    public var at: Date
    public var disk: Double?
    public var memory: Double?
    public var load: Double?
}

enum HealthScript {
    /// Sent on stdin to `sh -s`. Reads only; every probe tolerates its tool being absent.
    static let source = #"""
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "os=$PRETTY_NAME"; else echo "os=$(uname -sr)"; fi
    [ -r /proc/uptime ] && echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
    [ -r /proc/loadavg ] && echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
    command -v nproc >/dev/null 2>&1 && echo "cpus=$(nproc)"
    [ -r /proc/meminfo ] && awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print "mem=" t " " a}' /proc/meminfo
    df -kP / 2>/dev/null | awk 'NR==2{print "disk=" $2 " " $3}'
    if [ -x /usr/lib/update-notifier/apt-check ]; then echo "updates=$(/usr/lib/update-notifier/apt-check 2>&1 | tr ';' ' ')"; fi
    if [ -f /var/run/reboot-required ]; then echo "reboot=1"; else echo "reboot=0"; fi
    command -v systemctl >/dev/null 2>&1 && echo "failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')"
    command -v systemctl >/dev/null 2>&1 && systemctl --failed --no-legend --plain 2>/dev/null | head -n 20 \
      | awk '{d=""; for (i = 5; i <= NF; i++) d = d (i > 5 ? " " : "") $i; print "failedunit=" $1 "|" d}'
    [ -r /var/run/reboot-required.pkgs ] && sort -u /var/run/reboot-required.pkgs | head -n 10 | sed 's/^/rebootpkg=/'
    command -v apt >/dev/null 2>&1 && apt list --upgradable 2>/dev/null | awk -F/ '/-security/{print "secpkg=" $1}' | head -n 20
    for c in /etc/letsencrypt/live/*/cert.pem; do
      [ -r "$c" ] && echo "cert=$(basename "$(dirname "$c")")|$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2)"
    done
    exit 0
    """#

    static func parse(_ text: String, now: Date = Date()) -> ServerHealth {
        var h = ServerHealth(collectedAt: now, certificates: [])
        let certDate = DateFormatter()
        certDate.locale = Locale(identifier: "en_US_POSIX")
        certDate.timeZone = TimeZone(identifier: "GMT")
        certDate.dateFormat = "MMM d HH:mm:ss yyyy zzz"

        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let nums = value.split(separator: " ").compactMap { Double($0) }
            switch key {
            case "os": h.os = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).nilIfEmpty
            case "uptime": h.uptimeSeconds = nums.first
            case "load": if nums.count == 3 { h.load = nums }
            case "cpus": h.cpus = nums.first.map(Int.init)
            case "mem": if nums.count == 2 { h.memTotalKB = nums[0]; h.memAvailableKB = nums[1] }
            case "disk": if nums.count == 2 { h.diskTotalKB = nums[0]; h.diskUsedKB = nums[1] }
            case "updates": if nums.count == 2 { h.updates = Int(nums[0]); h.securityUpdates = Int(nums[1]) }
            case "reboot": h.rebootRequired = value == "1"
            case "failed": h.failedUnits = nums.first.map(Int.init)
            case "failedunit":
                let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if let name = parts.first, !name.isEmpty {
                    h.failedUnitList = (h.failedUnitList ?? []) + [ServerHealth.FailedUnit(name: name, description: parts.count > 1 ? parts[1] : "")]
                }
            case "rebootpkg": if !value.isEmpty { h.rebootPackages = (h.rebootPackages ?? []) + [value] }
            case "secpkg": if !value.isEmpty { h.securityPackages = (h.securityPackages ?? []) + [value] }
            case "cert":
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                // openssl prints e.g. "Jan  6 14:10:17 2027 GMT" (double space before single-digit days).
                if parts.count == 2, let d = certDate.date(from: parts[1].replacingOccurrences(of: "  ", with: " ")) {
                    h.certificates.append(.init(name: parts[0], expires: d))
                }
            default: break
            }
        }
        return h
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension RemoteService {
    public func collectHealth(target: RemoteTarget, auth: RemoteAuth) async throws -> ServerHealth {
        let r = try await execute(target, auth, "sh -s", stdin: HealthScript.source)
        guard r.exitCode != 255, !r.timedOut else { throw failure(r, auth) }
        return HealthScript.parse(r.stdout)
    }
}
