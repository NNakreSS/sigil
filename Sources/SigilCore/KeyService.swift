import CryptoKit
import Foundation

public struct KeyMaterial: Sendable {
    public let fileName: String
    /// For 1Password keys this is the public key file (the private key never leaves 1Password).
    public let privateKeyURL: URL
    public let publicKeyLine: String
    public let blob: String
    public let fingerprint: String
    public var onePasswordItemID: String? = nil
    public var onePasswordVaultID: String? = nil
    public var secureEnclaveKeyHash: String? = nil
}

/// Creates and removes per-server ed25519 keys.
///
/// In production every key gets its own random passphrase, which is stored only in the macOS Keychain
/// (via `ssh-add --apple-use-keychain`); ssh finds it there with `UseKeychain yes`. Tests turn this off.
public struct KeyService: Sendable {
    let paths: DeckPaths
    let protectWithKeychain: Bool

    public init(paths: DeckPaths, protectWithKeychain: Bool = true) {
        self.paths = paths
        self.protectWithKeychain = protectWithKeychain
    }

    public func generate(fileName: String, comment: String) async throws -> KeyMaterial {
        try paths.ensureDirectories()
        let url = paths.keyURL(fileName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw DeckError.keyGeneration("\(fileName) zaten var.") }

        var args = ["-q", "-t", "ed25519", "-a", "100", "-C", comment, "-f", url.path]

        if protectWithKeychain {
            try await Askpass.withSecret(Askpass.randomPassphrase()) { env in
                // No -N: ssh-keygen asks for the passphrase twice, askpass answers both.
                let gen = try await Shell.run("/usr/bin/ssh-keygen", args, environment: env, timeout: 60)
                guard gen.succeeded else { throw DeckError.keyGeneration(gen.stderr.trimmed) }
                let add = try await Shell.run("/usr/bin/ssh-add", ["--apple-use-keychain", url.path], environment: env, timeout: 30)
                guard add.succeeded else {
                    try? fm.removeItem(at: url)
                    try? fm.removeItem(at: url.appendingPathExtension("pub"))
                    throw DeckError.keyGeneration("Anahtar Keychain’e eklenemedi: \(add.stderr.trimmed)")
                }
            }
        } else {
            args += ["-N", ""]
            let gen = try await Shell.run("/usr/bin/ssh-keygen", args, timeout: 60)
            guard gen.succeeded else { throw DeckError.keyGeneration(gen.stderr.trimmed) }
        }

        return try material(fileName: fileName)
    }

    public func material(fileName: String) throws -> KeyMaterial {
        let url = paths.keyURL(fileName)
        let pub = try String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8).trimmed
        let parts = pub.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { throw DeckError.keyGeneration("Genel anahtar okunamadı.") }
        let blob = try Validation.keyBlob(parts[1])
        return KeyMaterial(
            fileName: fileName, privateKeyURL: url, publicKeyLine: pub, blob: blob,
            fingerprint: Fingerprint.sha256(ofBase64: blob) ?? ""
        )
    }

    /// Removes the key files, and the key + its passphrase from ssh-agent / Keychain.
    public func delete(fileName: String) async {
        let url = paths.keyURL(fileName)
        if protectWithKeychain, FileManager.default.fileExists(atPath: url.path) {
            _ = try? await Shell.run("/usr/bin/ssh-add", ["-d", "--apple-use-keychain", url.path], timeout: 15)
        }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pub"))
    }
}

public enum Fingerprint {
    /// OpenSSH-style "SHA256:xxxx" fingerprint of a base64 key blob.
    public static func sha256(ofBase64 blob: String) -> String? {
        guard let data = Data(base64Encoded: blob) else { return nil }
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
