import Foundation

/// Everything the user types ends up in ssh arguments and in ~/.ssh/config, so it is validated
/// strictly: no whitespace, no leading dash (option injection), no newlines (config injection).
public enum Validation {
    public static func alias(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(s, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"#) else {
            throw DeckError.invalid("İsim harf veya rakamla başlamalı; sadece harf, rakam, nokta, tire ve alt çizgi içerebilir.")
        }
        return s
    }

    public static func host(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(s, #"^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$"#) else {
            throw DeckError.invalid("Adres geçerli bir IP ya da alan adı olmalı.")
        }
        return s
    }

    public static func user(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(s, #"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$"#) else {
            throw DeckError.invalid("Kullanıcı adı geçersiz.")
        }
        return s
    }

    public static func port(_ p: Int) throws -> Int {
        guard (1...65535).contains(p) else { throw DeckError.invalid("Port 1 ile 65535 arasında olmalı.") }
        return p
    }

    /// Base64 body of a public key, as it appears in authorized_keys.
    public static func keyBlob(_ s: String) throws -> String {
        guard matches(s, #"^[A-Za-z0-9+/=]{20,}$"#) else { throw DeckError.invalid("Anahtar biçimi geçersiz.") }
        return s
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
