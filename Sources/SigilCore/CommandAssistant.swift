import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the assistant knows about the server it is helping with. No hostnames, users or keys: only the OS and tools.
public struct AssistantContext: Sendable {
    public var os: String?
    public var profile: ServerProfile?

    public init(os: String?, profile: ServerProfile?) {
        self.os = os
        self.profile = profile
    }

    public init(health: ServerHealth?) {
        self.init(os: health?.os, profile: ServerProfile(health))
    }

    var description: String {
        var parts = ["Sunucu: \(os ?? "Linux (sürüm bilinmiyor)")"]
        if let f = profile?.family { parts.append("Ailesi: \(f.rawValue)") }
        if let t = profile?.tools, !t.isEmpty { parts.append("Kurulu araçlar: \(t.sorted().joined(separator: ", "))") }
        return parts.joined(separator: ". ")
    }
}

public struct AssistantAnswer: Sendable, Equatable {
    /// A command to type at the prompt (suggestions), or one that would help (explanations); may be empty.
    public var command: String
    public var explanation: String
    public var changesSystem: Bool
    /// Sigil's own checks of the command: unknown program, shell syntax error…
    public var warnings: [String] = []
}

public enum AssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case off, onDevice, claude
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Kapalı"
        case .onDevice: return "Cihaz içi (Apple)"
        case .claude: return "Claude (kendi API anahtarın)"
        }
    }

    public static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }
}

public protocol CommandAssistant: Sendable {
    func suggest(_ request: String, context: AssistantContext) async throws -> AssistantAnswer
    func explain(_ text: String, context: AssistantContext) async throws -> AssistantAnswer
}

/// Prompt material shared by both providers.
public enum AssistantPrompt {
    static let suggestInstructions = """
    Sen deneyimli bir Linux sunucu yöneticisisin. Kullanıcının Türkçe isteğini, belirtilen sunucuda çalışacak TEK SATIRLIK bir kabuk komutuna çevir.
    Kurallar:
    - Yalnızca gerçekten var olan komutları ve seçenekleri kullan. Emin değilsen daha basit, bilinen bir komut seç. Komut ya da seçenek uydurma.
    - Verilen örnek komutlar bu sunucuda çalışır; isteğe uyan varsa onu temel al.
    - Bilmediğin bir değer gerekiyorsa (servis ya da container adı gibi) <servis> biçiminde bırak.
    - Açıklama Türkçe ve tek cümle olsun.
    - Komut sunucuda bir şeyi değiştiriyorsa (yeniden başlatma, kurma, silme, dosyaya yazma) bunu belirt.
    """

    static let explainInstructions = """
    Sen deneyimli bir Linux sunucu yöneticisisin. Kullanıcı terminalden bir çıktı ya da hata mesajı seçti.
    Ne anlama geldiğini Türkçe, sade ve en fazla dört cümleyle açıkla. Bir çözüm komutu gerçekten işe yarayacaksa tek satır olarak öner; yoksa komut alanını boş bırak.
    Yalnızca gerçekten var olan komutları kullan; uydurma.
    """

    /// The library commands closest to the request, given to the model as known-good examples.
    public static func examples(for request: String, context: AssistantContext, limit: Int = 8) -> [CommandTemplate] {
        let words = request.lowercased(with: Locale(identifier: "tr_TR"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0.prefix(5)) }      // crude stemming: Turkish suffixes come after the first letters
            .filter { $0.count >= 3 }
        guard !words.isEmpty else { return [] }
        let candidates = CommandLibrary.relevant(for: context.profile)
        func score(_ c: CommandTemplate) -> Int {
            let hay = (c.title + " " + c.template + " " + c.category.rawValue).lowercased(with: Locale(identifier: "tr_TR"))
            return words.filter { hay.contains($0) }.count
        }
        return candidates.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func suggestPrompt(_ request: String, context: AssistantContext) -> String {
        let ex = examples(for: request, context: context)
        let exText = ex.isEmpty ? "" : "\nÖrnek komutlar:\n" + ex.map {
            "- \($0.title): " + $0.template.replacingOccurrences(of: "{{", with: "<").replacingOccurrences(of: "}}", with: ">")
        }.joined(separator: "\n")
        return "\(context.description).\(exText)\n\nİstek: \(request)"
    }

    static func explainPrompt(_ text: String, context: AssistantContext) -> String {
        "\(context.description).\n\nTerminal çıktısı:\n\(String(text.prefix(4000)))"
    }
}

/// Sigil's own sanity checks on a suggested command; the model can be wrong, so say so plainly.
public enum CommandCheck {
    static let common: Set<String> = [
        "ls", "cat", "grep", "egrep", "zgrep", "tail", "head", "less", "more", "find", "du", "df", "free", "ps", "top", "htop", "kill",
        "pkill", "pgrep", "killall", "ss", "netstat", "ip", "ping", "curl", "wget", "dig", "nslookup", "host", "journalctl",
        "systemctl", "service", "apt", "apt-get", "apt-cache", "dpkg", "dnf", "yum", "rpm", "docker", "nginx", "apachectl", "mysql",
        "mysqldump", "psql", "pg_dump", "redis-cli", "pm2", "node", "npm", "php", "git", "ufw", "firewall-cmd", "fail2ban-client",
        "certbot", "openssl", "crontab", "tar", "gzip", "gunzip", "zip", "unzip", "chmod", "chown", "mkdir", "rm", "rmdir", "cp", "mv",
        "ln", "touch", "echo", "printf", "awk", "sed", "sort", "uniq", "wc", "xargs", "id", "whoami", "w", "who", "last", "lastb",
        "uptime", "hostnamectl", "timedatectl", "uname", "lsblk", "mount", "umount", "dmesg", "useradd", "adduser", "usermod",
        "userdel", "deluser", "passwd", "getent", "groups", "lscpu", "iostat", "vmstat", "watch", "env", "which", "stat", "file",
        "lsof", "nc", "traceroute", "tracepath", "scp", "rsync", "ssh", "ssh-keygen", "sudo", "test", "[", "date", "cut", "tr",
        "tee", "diff", "basename", "dirname", "realpath", "readlink", "sleep", "nohup", "screen", "tmux", "vim", "vi", "nano",
        "chattr", "lsattr", "ulimit", "sysctl", "modprobe", "lsmod", "reboot", "shutdown", "logrotate", "zcat", "bzip2", "xz",
    ]

    public static func warnings(for command: String, profile: ServerProfile?) async -> [String] {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return [] }
        var out: [String] = []
        if c.contains("<") && c.contains(">") && c.range(of: #"<[^<>\s]+>"#, options: .regularExpression) != nil {
            out.append("Komutta doldurman gereken bir yer var (<…>).")
        } else if let r = try? await Shell.run("/bin/sh", ["-n", "-c", c], timeout: 5), !r.succeeded {
            out.append("Kabuk sözdizimi hatalı görünüyor.")
        }
        for program in programs(in: c) where !common.contains(program) && !(profile?.tools.contains(program) ?? false) {
            out.append("“\(program)” tanıdığım bir komut değil; uydurulmuş olabilir.")
        }
        return out
    }

    /// The program at the start of each pipeline stage, skipping sudo and VAR=value prefixes.
    static func programs(in command: String) -> [String] {
        // Quoted text (grep patterns, awk programs) may contain | or ; that are not pipeline separators.
        let unquoted = command
            .replacingOccurrences(of: #"'[^']*'"#, with: "Q", options: .regularExpression)
            .replacingOccurrences(of: #""[^"]*""#, with: "Q", options: .regularExpression)
        return unquoted.components(separatedBy: CharacterSet(charactersIn: "|;&")).compactMap { stage in
            stage.split(separator: " ").map(String.init)
                .drop { $0 == "sudo" || $0 == "-n" || $0 == "-E" || $0.contains("=") || $0.hasPrefix("-") || $0 == "env" }
                .first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()$`\"'")) }
                .flatMap { $0.isEmpty || $0.first?.isNumber == true || $0.hasPrefix("/") || $0.hasPrefix(".") ? nil : $0 }
        }
    }
}

// MARK: - On-device (Apple Foundation Models)

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct GeneratedAnswer {
    @Guide(description: "Tek satırlık kabuk komutu; gerekmiyorsa boş")
    var command: String
    @Guide(description: "Türkçe, kısa açıklama")
    var explanation: String
    @Guide(description: "Komut sunucuda bir şeyi değiştiriyor mu (yeniden başlatma, kurma, silme, yazma)")
    var changesSystem: Bool
}

/// Runs on this Mac only; nothing leaves it.
@available(macOS 26, *)
public struct OnDeviceAssistant: CommandAssistant {
    public init() {}

    public func suggest(_ request: String, context: AssistantContext) async throws -> AssistantAnswer {
        try await run(AssistantPrompt.suggestInstructions, AssistantPrompt.suggestPrompt(request, context: context), context)
    }

    public func explain(_ text: String, context: AssistantContext) async throws -> AssistantAnswer {
        try await run(AssistantPrompt.explainInstructions, AssistantPrompt.explainPrompt(text, context: context), context)
    }

    private func run(_ instructions: String, _ prompt: String, _ context: AssistantContext) async throws -> AssistantAnswer {
        guard case .available = SystemLanguageModel.default.availability else {
            throw DeckError.invalid("Apple Intelligence bu Mac’te açık değil (Sistem Ayarları → Apple Intelligence ve Siri).")
        }
        let session = LanguageModelSession(instructions: instructions)
        let r = try await session.respond(to: prompt, generating: GeneratedAnswer.self)
        var a = AssistantAnswer(command: r.content.command.trimmingCharacters(in: .whitespacesAndNewlines),
                                explanation: r.content.explanation, changesSystem: r.content.changesSystem)
        a.warnings = await CommandCheck.warnings(for: a.command, profile: context.profile)
        return a
    }
}
#endif

// MARK: - Claude (the user's own API key)

/// Sends the request (or the selected terminal text) plus the server's OS and tool list to Anthropic's API with the
/// user's key. Only used when the user picks it in Settings.
public struct ClaudeAssistant: CommandAssistant {
    public let apiKey: String
    public let model: String
    var session: URLSession = .shared

    public static let models: [(id: String, title: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"), ("claude-haiku-5-5", "Claude Haiku 5.5 (hızlı)"), ("claude-opus-5-5", "Claude Opus 5.5"),
    ]

    public init(apiKey: String, model: String = "claude-sonnet-5-5") {
        self.apiKey = apiKey
        self.model = model
    }

    public func suggest(_ request: String, context: AssistantContext) async throws -> AssistantAnswer {
        try await run(AssistantPrompt.suggestInstructions, AssistantPrompt.suggestPrompt(request, context: context), context)
    }

    public func explain(_ text: String, context: AssistantContext) async throws -> AssistantAnswer {
        try await run(AssistantPrompt.explainInstructions, AssistantPrompt.explainPrompt(text, context: context), context)
    }

    static let jsonRule = """

    Yanıtı YALNIZCA şu biçimde, başka hiçbir metin olmadan bir JSON nesnesi olarak ver:
    {"command": "<tek satır komut ya da boş>", "explanation": "<Türkçe açıklama>", "changes_system": true|false}
    """

    private func run(_ instructions: String, _ prompt: String, _ context: AssistantContext) async throws -> AssistantAnswer {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model, "max_tokens": 700, "system": instructions + Self.jsonRule,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw DeckError.invalid(status == 401 ? "Claude API anahtarı geçersiz." : "Claude yanıt vermedi (\(status)) \(message ?? "")")
        }
        var a = try Self.parse(data)
        a.warnings = await CommandCheck.warnings(for: a.command, profile: context.profile)
        return a
    }

    static func parse(_ data: Data) throws -> AssistantAnswer {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first,
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw DeckError.invalid("Claude’un yanıtı anlaşılamadı.") }
        return AssistantAnswer(command: (json["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                               explanation: json["explanation"] as? String ?? "",
                               changesSystem: json["changes_system"] as? Bool ?? true)
    }
}
