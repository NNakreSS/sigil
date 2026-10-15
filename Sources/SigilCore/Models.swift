import Foundation

public struct ServerEvent: Codable, Identifiable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: Level, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

/// Where a server's private key lives.
public enum KeyStoreKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Key file in ~/.ssh/sigil/keys, encrypted with a random passphrase kept in the macOS Keychain.
    case keychain
    /// Key generated inside 1Password; never on disk. ssh uses it through the 1Password SSH agent (Touch ID).
    case onePassword
    /// Non-exportable key in the Mac's Secure Enclave (macOS 26+); every use needs Touch ID.
    case secureEnclave

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keychain: return "macOS Keychain"
        case .onePassword: return "1Password"
        case .secureEnclave: return "Secure Enclave"
        }
    }

    /// Using the key pops an approval prompt, so Sigil never uses it unattended.
    public var asksForApproval: Bool { self != .keychain }

    /// The stores this Mac can use, most protective first.
    public static var available: [KeyStoreKind] {
        (SecureEnclaveService.isSupported ? [.secureEnclave] : []) + [.onePassword, .keychain]
    }

    /// Default for new servers: Secure Enclave where the Mac supports it, otherwise 1Password.
    public static var preferredDefault: KeyStoreKind { SecureEnclaveService.isSupported ? .secureEnclave : .onePassword }

    /// The user's preferred store, or the closest one that works right now.
    public static func usable(_ preferred: KeyStoreKind, onePasswordReady: Bool) -> KeyStoreKind {
        switch preferred {
        case .secureEnclave where !SecureEnclaveService.isSupported: return onePasswordReady ? .onePassword : .keychain
        case .onePassword where !onePasswordReady: return SecureEnclaveService.isSupported ? .secureEnclave : .keychain
        default: return preferred
        }
    }
}

/// A key in the server's authorized_keys that Sigil did not put there.
public struct ForeignKey: Codable, Hashable, Identifiable, Sendable {
    public var id: String { blob }
    public var type: String
    public var blob: String
    public var comment: String
    public var fingerprint: String
    public var firstSeen: Date
    /// The user said "I know this one": no more alerts for it.
    public var acknowledged: Bool
    /// Matches a public key file on this Mac (e.g. "~/.ssh/id_ed25519.pub").
    public var localMatch: String?

    public init(type: String, blob: String, comment: String, fingerprint: String, firstSeen: Date = Date(), acknowledged: Bool = false, localMatch: String? = nil) {
        self.type = type
        self.blob = blob
        self.comment = comment
        self.fingerprint = fingerprint
        self.firstSeen = firstSeen
        self.acknowledged = acknowledged
        self.localMatch = localMatch
    }
}

/// What a server is for. Production servers get extra friction before connecting.
public enum ServerEnvironment: String, Codable, Sendable, CaseIterable, Identifiable {
    case production, staging, development
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .production: return "Production"
        case .staging: return "Staging"
        case .development: return "Geliştirme"
        }
    }
}

/// A managed server. Contains no secrets: the password is never stored and the private key
/// lives in ~/.ssh/sigil/keys, protected by a passphrase kept in the macOS Keychain.
public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var alias: String
    public var host: String
    public var port: Int
    public var user: String

    public var keyFileName: String
    /// Base64 body of the public key; this is what identifies our line in the server's authorized_keys.
    public var publicKeyBlob: String
    public var keyFingerprint: String

    public var createdAt: Date
    public var lastRotatedAt: Date
    /// 0 turns automatic rotation off.
    public var rotationIntervalDays: Int
    public var lastRotationFailureAt: Date?
    /// Old public keys that rotation could not remove from the server yet; retried on the next successful contact.
    public var pendingKeyRemovals: [String]
    /// True when adding this server created the host's known_hosts entries. Only then may removal forget them;
    /// a host the user already trusted on their own is left alone. Optional so older lists still decode (nil = false).
    public var createdKnownHostsEntry: Bool?
    /// nil in lists written before 1Password support = keychain.
    public var keyStore: KeyStoreKind?
    public var onePasswordItemID: String?
    public var onePasswordVaultID: String?
    /// Public-key hash (hex) of the Secure Enclave identity, for deleting it.
    public var secureEnclaveKeyHash: String?

    public var store: KeyStoreKind { keyStore ?? .keychain }

    /// Free-form folder in the sidebar ("Müşteri A", "Kişisel"…). nil = ungrouped.
    public var group: String?
    public var environment: ServerEnvironment?
    public var isProduction: Bool { environment == .production }

    /// Result of the last authorized_keys audit.
    public var foreignKeys: [ForeignKey]?
    public var lastAuditAt: Date?
    /// The server presented a host key that contradicts known_hosts.
    public var hostKeyMismatch: Bool?

    public var unacknowledgedForeignKeys: [ForeignKey] { (foreignKeys ?? []).filter { !$0.acknowledged } }

    public var tunnels: [TunnelProfile]?
    /// Other people's keys the user let in (Erişim ver).
    public var grants: [AccessGrant]?
    /// SSH is only open to these addresses (ufw); nil when there is no allow list.
    public var allowList: [AllowedAddress]?
    /// Reached through this other managed server (ProxyJump). One level only.
    public var jumpServerID: UUID?
    public var health: ServerHealth?
    public var healthHistory: [HealthSample]?
    /// Problems already notified, so each one is announced once.
    public var announcedProblems: [String]?

    public var lastCheckedAt: Date?
    public var lastReachable: Bool?
    public var events: [ServerEvent]

    public init(
        id: UUID = UUID(), alias: String, host: String, port: Int, user: String,
        keyFileName: String, publicKeyBlob: String, keyFingerprint: String,
        createdAt: Date = Date(), lastRotatedAt: Date = Date(), rotationIntervalDays: Int = 30,
        lastRotationFailureAt: Date? = nil, pendingKeyRemovals: [String] = [],
        lastCheckedAt: Date? = nil, lastReachable: Bool? = nil,
        events: [ServerEvent] = []
    ) {
        self.pendingKeyRemovals = pendingKeyRemovals
        self.id = id
        self.alias = alias
        self.host = host
        self.port = port
        self.user = user
        self.keyFileName = keyFileName
        self.publicKeyBlob = publicKeyBlob
        self.keyFingerprint = keyFingerprint
        self.createdAt = createdAt
        self.lastRotatedAt = lastRotatedAt
        self.rotationIntervalDays = rotationIntervalDays
        self.lastRotationFailureAt = lastRotationFailureAt
        self.lastCheckedAt = lastCheckedAt
        self.lastReachable = lastReachable
        self.events = events
    }

    public var nextRotation: Date? {
        var days = rotationIntervalDays
        // Secure Enclave identities come with a one-year certificate and ssh-keychain.dylib only offers valid ones:
        // renew well before it lapses, even when rotation is switched off.
        if store == .secureEnclave { days = min(days > 0 ? days : Self.secureEnclaveMaxDays, Self.secureEnclaveMaxDays) }
        guard days > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: days, to: lastRotatedAt)
    }

    static let secureEnclaveMaxDays = 330

    /// Due, and not retried too soon after a failure.
    public func isRotationDue(now: Date = Date(), retryAfter: TimeInterval = 6 * 3600) -> Bool {
        guard let next = nextRotation, now >= next else { return false }
        if let failed = lastRotationFailureAt, now.timeIntervalSince(failed) < retryAfter { return false }
        return true
    }
}

/// What the user fills in on the "add server" form (the password is passed separately and never stored).
public struct ServerDraft: Sendable {
    public var alias: String
    public var host: String
    public var port: Int
    public var user: String
    public var rotationIntervalDays: Int
    public var keyStore: KeyStoreKind
    public var jumpServerID: UUID?

    public init(alias: String = "", host: String = "", port: Int = 22, user: String = "root", rotationIntervalDays: Int = 30, keyStore: KeyStoreKind = .keychain, jumpServerID: UUID? = nil) {
        self.keyStore = keyStore
        self.jumpServerID = jumpServerID
        self.alias = alias
        self.host = host
        self.port = port
        self.user = user
        self.rotationIntervalDays = rotationIntervalDays
    }

    /// Returns a trimmed, validated copy.
    public func validated() throws -> ServerDraft {
        ServerDraft(
            alias: try Validation.alias(alias),
            host: try Validation.host(host),
            port: try Validation.port(port),
            user: try Validation.user(user),
            rotationIntervalDays: max(0, rotationIntervalDays),
            keyStore: keyStore,
            jumpServerID: jumpServerID
        )
    }
}

/// A server host key offered during the first connection; the user confirms its fingerprint.
public struct HostKey: Identifiable, Hashable, Sendable {
    public var id: String { fingerprint }
    public let algorithm: String
    public let fingerprint: String
    /// Ready-to-append known_hosts line.
    public let knownHostsLine: String
    public let blob: String
}
