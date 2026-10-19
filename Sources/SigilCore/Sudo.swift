import Foundation
import LocalAuthentication
import Security

/// Why the server refused the sudo password Sigil gave it.
public enum SudoFailure: String, Equatable, Sendable {
    /// The password is wrong (sudo was told about one attempt only).
    case wrongPassword = "badpassword"
    /// This user may not use sudo (not in sudoers, or no sudo installed).
    case notAllowed = "denied"
    /// No place to put the helper (home and /tmp not writable).
    case noHelper = "nohelper"

    public var message: String {
        switch self {
        case .wrongPassword: return "Sudo şifresi yanlış. Yeniden gir."
        case .notAllowed: return "Bu kullanıcı sudo kullanamıyor (sudoers’ta değil ya da sudo kurulu değil)."
        case .noHelper: return "Sunucuda sudo yardımcısı için yazılabilir bir klasör yok (ev dizini ve /tmp)."
        }
    }
}

/// Sudo for users whose sudo asks for a password. Every remote script Sigil runs uses `sudo -n` (or `$S` set to it)
/// for root, so instead of changing each script a preamble defines a `sudo` function: it drops `-n` and answers with
/// the password through a SUDO_ASKPASS helper. The helper holds no secret (it prints `$SIGIL_PW`, which only the sudo
/// process is given), so it can outlive the script for a job left running in the background; stale ones are removed
/// on the next run. The preamble checks the password once, with the helper allowing a single try, so a wrong password
/// costs one failed attempt (pam_faillock locks accounts after a few). The password reaches the server only on
/// stdin: never on a command line, in the process list or in a file.
enum SudoScript {
    /// Each line is one complete statement ending in `;`, so the preamble also works joined into one line (`sh -c`).
    /// No single quotes: it goes inside `sh -c '…'` as is.
    static let lines = [
        // root needs none of this (and may have no sudo at all).
        #"if [ "$(id -u)" -ne 0 ]; then"#,
        #"SIGIL_SB="${XDG_RUNTIME_DIR:-$HOME}"; [ -d "$SIGIL_SB" ] && [ -w "$SIGIL_SB" ] || SIGIL_SB=/tmp;"#,
        #"find "$SIGIL_SB" -maxdepth 1 -name ".sigil-sudo.*" -mmin +10 -exec rm -rf {} + 2>/dev/null;"#,
        #"SIGIL_AD=$(mktemp -d "$SIGIL_SB/.sigil-sudo.XXXXXX") || { echo "SIGIL_SUDO=nohelper"; exit 0; };"#,
        // The helper: once the password is known good it answers every prompt, before that only the first.
        ##"printf "#!/bin/sh\nd=\${0%%/*}\nif [ -e \"\$d/ok\" ]; then printf \"%%s\\\\n\" \"\$SIGIL_PW\"; exit 0; fi\n[ -e \"\$d/tried\" ] && exit 1\n: > \"\$d/tried\"\nprintf \"%%s\\\\n\" \"\$SIGIL_PW\"\n" > "$SIGIL_AD/a";"##,
        #"chmod 700 "$SIGIL_AD/a";"#,
        #"sudo() { while [ $# -gt 0 ]; do case "$1" in -n|--non-interactive) shift;; *) break;; esac; done; SIGIL_PW="$SIGIL_PW" SUDO_ASKPASS="$SIGIL_AD/a" command sudo -A "$@"; };"#,
        // -k: really ask, even if a ticket is cached, so a wrong password shows here and not halfway through.
        #"if SIGIL_OUT=$(sudo -k true 2>&1); then : > "$SIGIL_AD/ok"; else case "$SIGIL_OUT" in *sudoers*|*"not allowed"*|*"not found"*) echo "SIGIL_SUDO=denied";; *) echo "SIGIL_SUDO=badpassword";; esac; exit 0; fi;"#,
        #"unset SIGIL_OUT;"#,
        #"fi;"#,
    ]

    /// The password can't hold a line break: it travels as one line.
    static func isValid(_ password: String) -> Bool {
        !password.isEmpty && password.count <= 256 && !password.contains(where: { $0.isNewline || $0 == "\0" })
    }

    /// `command` and `stdin` rewritten so `sudo` answers with `password`; nil for a command that is not one of
    /// Sigil's scripts (`sh -s` with the script on stdin, or `sh -c '…'`), which is sent unchanged.
    static func apply(password: String, command: String, stdin: String?) -> (command: String, stdin: String)? {
        guard isValid(password) else { return nil }
        if command == "sh -s" {
            return (command, "SIGIL_PW=\(AppScript.q(password))\n" + lines.joined(separator: "\n") + "\n" + (stdin ?? ""))
        }
        let prefix = "sh -c '"
        if command.hasPrefix(prefix) {
            // The script is on the command line, so the password comes first on stdin, before the script's own input.
            let pre = "IFS= read -r SIGIL_PW || exit 1; " + lines.joined(separator: " ") + " "
            return (prefix + pre + String(command.dropFirst(prefix.count)), password + "\n" + (stdin ?? ""))
        }
        return nil
    }

    /// The preamble's verdict, when it stopped the script.
    static func failure(_ stdout: String) -> SudoFailure? {
        guard let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix("SIGIL_SUDO=") }) else { return nil }
        return SudoFailure(rawValue: String(line.dropFirst("SIGIL_SUDO=".count)))
    }
}

/// Sudo passwords kept on this Mac (only when the user asks), opened with Touch ID or the Mac's password.
public protocol SudoPasswordStore: Sendable {
    func save(_ password: String, account: String)
    /// Asks for Touch ID (or the Mac's password) first.
    func load(account: String, reason: String) async -> String?
    func has(account: String) -> Bool
    func delete(account: String)
}

public struct KeychainSudoPasswords: SudoPasswordStore {
    static let service = "com.nakres.sigil.sudo"
    public init() {}

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func save(_ password: String, account: String) {
        SecItemDelete(base(account) as CFDictionary)
        var add = base(account)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Sigil sudo şifresi (\(account))"
        SecItemAdd(add as CFDictionary, nil)
    }

    public func load(account: String, reason: String) async -> String? {
        guard has(account: account) else { return nil }
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func has(account: String) -> Bool {
        var q = base(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func delete(account: String) { SecItemDelete(base(account) as CFDictionary) }
}

final class MemorySudoPasswords: SudoPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func save(_ p: String, account: String) { lock.lock(); values[account] = p; lock.unlock() }
    func load(account: String, reason: String) async -> String? { lock.withLock { values[account] } }
    func has(account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[account] != nil }
    func delete(account: String) { lock.lock(); values[account] = nil; lock.unlock() }
}

/// Where `RemoteService` reports a refused sudo password, so the model can forget it.
final class SudoFailureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RemoteTarget, SudoFailure) -> Void)?
    func set(_ h: @escaping @Sendable (RemoteTarget, SudoFailure) -> Void) { lock.lock(); handler = h; lock.unlock() }
    func report(_ t: RemoteTarget, _ f: SudoFailure) { lock.lock(); let h = handler; lock.unlock(); h?(t, f) }
}

// MARK: - Workflows

extension DeckModel {
    /// Sigil has this server's sudo password for this run.
    public func isSudoUnlocked(_ id: UUID) -> Bool { sudoPasswords[id] != nil }

    /// A sudo password is kept in the Keychain for this server.
    public func hasSavedSudo(_ id: UUID) -> Bool { sudoStore.has(account: id.uuidString) }

    /// Checks `password` on the server (one attempt) and uses it from now on; `remember` keeps it in the Keychain.
    public func unlockSudo(_ id: UUID, password: String, remember: Bool) async throws {
        guard let s = server(id) else { throw DeckError.notFound }
        guard SudoScript.isValid(password) else { throw DeckError.invalid("Şifreyi tek satır olarak yaz.") }
        var t = try await sessionTarget(id)
        t.sudoPassword = password
        let r = try await remote.execute(t, auth(s.store, s.keyFileName), "sh -s", stdin: "echo SIGIL_SUDO_OK\n", timeout: 60)
        if r.exitCode == 255 { throw remote.failure(r, auth(s.store, s.keyFileName)) }
        guard r.stdout.contains("SIGIL_SUDO_OK") else { throw DeckError.ssh("Sunucu beklenen yanıtı vermedi.") }
        sudoPasswords[id] = password
        if remember { sudoStore.save(password, account: id.uuidString) } else { sudoStore.delete(account: id.uuidString) }
        log(id, .info, "Sudo şifresi kullanılıyor" + (remember ? " (bu Mac’te saklı)." : " (yalnızca bu oturum)."))
    }

    /// Opens the saved password with Touch ID (or the Mac's password) and checks it. False when there is none or
    /// the user cancelled.
    @discardableResult
    public func unlockSavedSudo(_ id: UUID) async throws -> Bool {
        guard let s = server(id) else { throw DeckError.notFound }
        guard let pw = await sudoStore.load(account: id.uuidString, reason: "\(s.alias) sunucusunda sudo şifresini kullan") else { return false }
        try await unlockSudo(id, password: pw, remember: true)
        return true
    }

    /// Forgets the password for this run and removes it from the Keychain.
    public func forgetSudo(_ id: UUID) {
        sudoPasswords[id] = nil
        sudoStore.delete(account: id.uuidString)
    }

    /// The server refused the password: never try it again (a wrong one counts towards an account lockout).
    func sudoRefused(_ t: RemoteTarget, _ f: SudoFailure) {
        guard f != .noHelper else { return }
        for s in servers where s.host == t.host && s.port == t.port && s.user == t.user && sudoPasswords[s.id] == t.sudoPassword {
            forgetSudo(s.id)
            log(s.id, .warning, f.message)
        }
    }
}
