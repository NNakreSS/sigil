import Foundation

public enum DeckError: LocalizedError, Equatable {
    case invalid(String)
    case aliasTaken(String)
    case hostKeyChanged(String)
    case ssh(String)
    case keyGeneration(String)
    case remoteRemovalFailed(String)
    case onePassword(String)
    case busy
    case notFound

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        case .aliasTaken(let a): return "“\(a)” adı zaten kullanılıyor (ya listede ya da ~/.ssh/config içinde var). Başka bir isim seç."
        case .hostKeyChanged(let m): return m
        case .ssh(let m): return m
        case .keyGeneration(let m): return "Anahtar oluşturulamadı: \(m)"
        case .remoteRemovalFailed(let m): return "Sunucudaki anahtar kaldırılamadı: \(m)"
        case .onePassword(let m): return "1Password: \(m)"
        case .busy: return "Bu sunucu için başka bir işlem sürüyor."
        case .notFound: return "Sunucu bulunamadı."
        }
    }
}

/// Turns raw ssh stderr into something a person can act on.
enum SSHErrorText {
    static func friendly(_ stderr: String, exitCode: Int32, timedOut: Bool, usedPassword: Bool = false) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if timedOut { return "Sunucu zamanında yanıt vermedi." }
        if lower.contains("remote host identification has changed") || lower.contains("host key verification failed") {
            return "Sunucunun parmak izi daha önce kaydedilenden farklı. Sunucu yeniden kurulmadıysa araya biri girmiş olabilir; bağlanmadım."
        }
        if lower.contains("permission denied") {
            return usedPassword
                ? "Kullanıcı adı ya da şifre hatalı; ya da sunucu şifreyle girişe izin vermiyor."
                : "Anahtar sunucu tarafından kabul edilmedi (Permission denied)."
        }
        if lower.contains("connection refused") { return "Bağlantı reddedildi. Adres ve port doğru mu, SSH servisi çalışıyor mu?" }
        if lower.contains("timed out") || lower.contains("operation timed out") { return "Bağlantı zaman aşımına uğradı. Adres, port ve güvenlik duvarını kontrol et." }
        if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") { return "Adres çözümlenemedi. Yazımı kontrol et." }
        if lower.contains("no route to host") || lower.contains("network is unreachable") { return "Sunucuya ulaşılamıyor (ağ yolu yok)." }
        if text.isEmpty { return "SSH komutu başarısız oldu (çıkış kodu \(exitCode))." }
        return text
    }
}
