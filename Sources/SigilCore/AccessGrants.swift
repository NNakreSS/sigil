import Foundation

/// Someone else's key that the user let into a server, with the limits they chose.
public struct AccessGrant: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Who it is for ("Ali"), as the user typed it.
    public var name: String
    /// The server account the key opens.
    public var account: String
    public var keyType: String
    public var publicKeyBlob: String
    public var fingerprint: String
    public var createdAt: Date
    /// Enforced by sshd itself (`expiry-time`), so it holds even when Sigil is not running.
    public var expiresAt: Date?
    /// `from="…"`: only these addresses may use the key.
    public var fromAddresses: [String]?
    /// no-port-forwarding, no-agent-forwarding, no-X11-forwarding.
    public var restrictForwarding: Bool
    /// Sigil created the account, so it may offer to remove it again.
    public var createdAccount: Bool
    public var sudo: Bool

    public func isExpired(now: Date = Date()) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

/// A public key someone sent, checked before it goes anywhere near a server.
public struct GuestKey: Hashable, Sendable {
    public let type: String
    public let blob: String
    public let comment: String

    static let allowedTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    public var fingerprint: String { Fingerprint.sha256(ofBase64: blob) ?? "" }

    /// Accepts the single line of a `.pub` file (`type base64 [comment]`).
    public static func parse(_ text: String) throws -> GuestKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("PRIVATE KEY") {
            throw DeckError.invalid("Bu bir GİZLİ anahtar. Kullanma: gizli anahtar kimseyle paylaşılmamalı. Arkadaşından yeni bir anahtar üretmesini ve yalnızca .pub dosyasındaki satırı göndermesini iste.")
        }
        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else { throw DeckError.invalid("Tek bir açık anahtar satırı yapıştır (ssh-ed25519 AAAA… ad).") }
        let tokens = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2, allowedTypes.contains(tokens[0]) else {
            throw DeckError.invalid("Bu bir açık anahtar satırına benzemiyor. “ssh-ed25519 AAAA…” ile başlamalı.")
        }
        let blob = try Validation.keyBlob(tokens[1])
        // The blob starts with its own type; it must agree with the label in front of it.
        guard let data = Data(base64Encoded: blob), data.count > 4 else { throw DeckError.invalid("Anahtar bozuk.") }
        let n = Int(data.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        guard data.count >= 4 + n, String(data: data.subdata(in: 4..<(4 + n)), encoding: .utf8) == tokens[0] else {
            throw DeckError.invalid("Anahtar bozuk ya da eksik kopyalanmış.")
        }
        return GuestKey(type: tokens[0], blob: blob, comment: tokens.dropFirst(2).joined(separator: " "))
    }
}

public struct GrantRequest: Sendable {
    public var name: String
    public var key: GuestKey
    /// nil: the account Sigil logs in with.
    public var account: String?
    public var sudo: Bool
    public var expiresAt: Date?
    public var fromAddresses: [String]
    public var restrictForwarding: Bool

    public init(name: String, key: GuestKey, account: String? = nil, sudo: Bool = false, expiresAt: Date? = nil,
                fromAddresses: [String] = [], restrictForwarding: Bool = true) {
        self.name = name
        self.key = key
        self.account = account
        self.sudo = sudo
        self.expiresAt = expiresAt
        self.fromAddresses = fromAddresses
        self.restrictForwarding = restrictForwarding
    }
}

enum GrantScript {
    static func account(_ s: String) throws -> String {
        guard Validation.matches(s, #"^[a-z_][a-z0-9_-]{0,31}$"#) else {
            throw DeckError.invalid("Kullanıcı adı küçük harf, rakam, - ve _ içerebilir; harfle başlamalı.")
        }
        return s
    }

    static func address(_ s: String) throws -> String {
        guard Validation.matches(s, #"^[A-Za-z0-9.:/*?-]{1,64}$"#) else {
            throw DeckError.invalid("Geçersiz adres: \(s). IP (203.0.113.7), ağ (203.0.113.0/24) ya da alan adı olmalı.")
        }
        return s
    }

    /// "Ali Veli" → "ali-veli"; safe as the key comment.
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
        let mapped = folded.lowercased().map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) ? c : "-"
        }
        let s = String(mapped).split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "misafir" : String(s.prefix(32))
    }

    static let expiryFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }()

    /// `[options] type blob sigil-guest:<slug>`.
    static func keyLine(_ r: GrantRequest) throws -> String {
        var options: [String] = []
        if let e = r.expiresAt { options.append("expiry-time=\"\(expiryFormat.string(from: e))Z\"") }
        let from = try r.fromAddresses.map(address)
        if !from.isEmpty { options.append("from=\"\(from.joined(separator: ","))\"") }
        if r.restrictForwarding { options.append("no-port-forwarding,no-agent-forwarding,no-X11-forwarding") }
        let key = "\(r.key.type) \(r.key.blob) sigil-guest:\(slug(r.name))"
        return options.isEmpty ? key : options.joined(separator: ",") + " " + key
    }

    /// Adds the key to another account's authorized_keys (creating the account if needed), as root or via
    /// password-less sudo. Exit 3: sudo needs a password. Sent to `sh -s`; every value is validated first.
    static func add(account: String, line: String, sudo: Bool) -> String {
        """
        S=""; if [ "$(id -u)" -ne 0 ]; then sudo -n true 2>/dev/null || exit 3; S="sudo -n"; fi
        U=\(account)
        if ! id "$U" >/dev/null 2>&1; then $S useradd -m -s /bin/bash "$U" || exit 4; echo created; fi
        H=$(getent passwd "$U" | cut -d: -f6); [ -n "$H" ] || exit 4
        K=$(cat <<'SIGILKEY'
        \(line)
        SIGILKEY
        )
        $S mkdir -p "$H/.ssh"; $S touch "$H/.ssh/authorized_keys"
        $S grep -qxF -- "$K" "$H/.ssh/authorized_keys" || printf '%s\\n' "$K" | $S tee -a "$H/.ssh/authorized_keys" >/dev/null
        $S chown -R "$U": "$H/.ssh"; $S chmod 700 "$H/.ssh"; $S chmod 600 "$H/.ssh/authorized_keys"
        \(sudo ? sudoBlock : "")
        echo ok
        """
    }

    private static let sudoBlock = """
    G=sudo; getent group sudo >/dev/null || G=wheel; $S usermod -aG "$G" "$U"
    F=/etc/sudoers.d/90-sigil-$U
    printf '%s ALL=(ALL) NOPASSWD:ALL\\n' "$U" | $S tee "$F" >/dev/null; $S chmod 440 "$F"
    $S visudo -cf "$F" >/dev/null || { $S rm -f "$F"; exit 5; }
    """

    /// Takes the key out of the account's authorized_keys; with `removeAccount`, also the account Sigil made.
    static func remove(account: String, blob: String, removeAccount: Bool) -> String {
        """
        S=""; if [ "$(id -u)" -ne 0 ]; then sudo -n true 2>/dev/null || exit 3; S="sudo -n"; fi
        U=\(account); B=\(blob)
        H=$(getent passwd "$U" | cut -d: -f6)
        if [ -n "$H" ] && $S test -f "$H/.ssh/authorized_keys"; then
          $S sh -c 'grep -vF -- "$1" "$2" > "$2.sigil-tmp"; cat "$2.sigil-tmp" > "$2"; rm -f "$2.sigil-tmp"' _ "$B" "$H/.ssh/authorized_keys"
        fi
        \(removeAccount ? #"if id "$U" >/dev/null 2>&1; then $S pkill -u "$U" 2>/dev/null; $S userdel -r "$U" 2>/dev/null; fi; $S rm -f "/etc/sudoers.d/90-sigil-$U""# : "")
        echo ok
        """
    }
}

extension RemoteService {
    func runGrantScript(target: RemoteTarget, auth: RemoteAuth, _ script: String) async throws -> String {
        let r = try await execute(target, auth, "sh -s", stdin: script)
        switch r.exitCode {
        case 0: return r.stdout
        case 3: throw DeckError.ssh("Bu kullanıcı için sudo parola istiyor; başka bir hesaba erişim verilemiyor. Root ile bağlanan bir sunucuda dene ya da şifresiz sudo ver.")
        case 4: throw DeckError.ssh("Kullanıcı hesabı oluşturulamadı.")
        case 5: throw DeckError.ssh("sudo yetkisi dosyası doğrulanamadı; yetki verilmedi.")
        default: throw failure(r, auth)
        }
    }
}

extension DeckModel {
    /// Lets someone else's key into the server with the chosen limits. Into the account Sigil uses, the key line is
    /// appended like Sigil's own; into any other account (created if missing), as root or via password-less sudo.
    @discardableResult
    public func grantAccess(_ id: UUID, _ request: GrantRequest) async throws -> AccessGrant {
        guard let s = server(id) else { throw DeckError.notFound }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw DeckError.invalid("Kime erişim verdiğini yaz (en fazla 40 karakter).") }
        guard request.key.blob != s.publicKeyBlob, !(s.grants ?? []).contains(where: { $0.publicKeyBlob == request.key.blob }) else {
            throw DeckError.invalid("Bu anahtar bu sunucuda zaten tanımlı.")
        }
        if let e = request.expiresAt, e <= Date() { throw DeckError.invalid("Bitiş zamanı geçmişte olamaz.") }
        let account = try GrantScript.account(request.account ?? s.user)
        let own = account == s.user
        let line = try GrantScript.keyLine(request)

        return try await withBusy(id, "Erişim veriliyor") {
            let target = sharedTarget(for: s), a = auth(s.store, s.keyFileName)
            var created = false
            if own {
                try await remote.installKey(target: target, auth: a, publicKeyLine: line)
            } else {
                let out = try await remote.runGrantScript(target: target, auth: a,
                                                          GrantScript.add(account: account, line: line, sudo: request.sudo && !own))
                created = out.contains("created")
            }
            let grant = AccessGrant(
                id: UUID(), name: name, account: account, keyType: request.key.type, publicKeyBlob: request.key.blob,
                fingerprint: request.key.fingerprint, createdAt: Date(), expiresAt: request.expiresAt,
                fromAddresses: request.fromAddresses.isEmpty ? nil : request.fromAddresses,
                restrictForwarding: request.restrictForwarding, createdAccount: created, sudo: request.sudo && !own
            )
            update(id) { $0.grants = ($0.grants ?? []) + [grant] }
            let until = request.expiresAt.map { " (\($0.formatted(date: .abbreviated, time: .shortened)) tarihine kadar)" } ?? ""
            log(id, .warning, "\(name) için “\(account)” hesabına erişim verildi\(until).")
            return grant
        }
    }

    /// Takes the key back off the server; with `removeAccount`, also deletes an account Sigil created for it.
    public func revokeAccess(_ id: UUID, grantID: UUID, removeAccount: Bool = false) async throws {
        guard let s = server(id), let g = s.grants?.first(where: { $0.id == grantID }) else { throw DeckError.notFound }
        try await withBusy(id, "Erişim kaldırılıyor") {
            let target = sharedTarget(for: s), a = auth(s.store, s.keyFileName)
            if g.account == s.user && !removeAccount {
                try await remote.removeKey(target: target, auth: a, blob: g.publicKeyBlob)
            } else {
                _ = try await remote.runGrantScript(target: target, auth: a, GrantScript.remove(
                    account: try GrantScript.account(g.account), blob: try Validation.keyBlob(g.publicKeyBlob),
                    removeAccount: removeAccount && g.createdAccount))
            }
            update(id) { $0.grants?.removeAll { $0.id == grantID } }
            log(id, .info, "\(g.name) için verilen erişim kaldırıldı\(removeAccount && g.createdAccount ? "; “\(g.account)” hesabı silindi" : "").")
        }
    }
}
