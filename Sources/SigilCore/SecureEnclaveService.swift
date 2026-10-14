import Foundation
import LocalAuthentication
import Security

/// Keys that live in the Mac's Secure Enclave (macOS 26+).
///
/// `sc_auth create-ctk-identity -k p-256-ne -t bio` creates a non-exportable P-256 key whose every use needs Touch ID.
/// OpenSSH reaches it through Apple's `/usr/lib/ssh-keychain.dylib` (`SecurityKeyProvider`) as an
/// `sk-ecdsa-sha2-nistp256@openssh.com` key. On disk Sigil keeps only the "key handle" file ssh needs to pick that
/// identity: the public key and the identity's public-key hash. It holds no secret.
///
/// `ssh-keygen -K` would export handles too, but it writes every identity to the same file name, so Sigil builds the
/// handle for exactly one identity itself (`keyHandleFile`). The format matches what ssh-keygen writes.
public struct SecureEnclaveService: Sendable {
    public static let provider = "/usr/lib/ssh-keychain.dylib"
    static let scAuth = "/usr/sbin/sc_auth"
    static let keyType = "sk-ecdsa-sha2-nistp256@openssh.com"
    /// The application string ssh-keychain.dylib reports for its keys.
    static let application = "ssh:"
    /// user presence required (0x01) | resident key (0x20), as ssh-keygen -K records it.
    static let flags: UInt8 = 0x21

    let paths: DeckPaths

    public init(paths: DeckPaths) { self.paths = paths }

    /// macOS 26+ with Apple's provider, on a Mac with Touch ID: the keys are created biometry-protected, so a Mac
    /// without a fingerprint reader must not be offered them.
    public static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
            && FileManager.default.fileExists(atPath: provider)
            && FileManager.default.isExecutableFile(atPath: scAuth)
            && hasTouchID
    }

    static var hasTouchID: Bool {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)   // fills in biometryType
        return context.biometryType == .touchID
    }

    public func generate(fileName: String, alias: String) async throws -> KeyMaterial {
        guard Self.isSupported else { throw DeckError.keyGeneration("Secure Enclave anahtarları macOS 26 ve sonrasını gerektirir.") }
        try paths.ensureDirectories()
        let url = paths.keyURL(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw DeckError.keyGeneration("\(fileName) zaten var.") }

        // Unique label, so the new identity can be found again without guessing.
        let label = "sigil-\(alias)-\(UUID().uuidString.lowercased().prefix(8))"
        let r = try await Shell.run(Self.scAuth, ["create-ctk-identity", "-l", label, "-k", "p-256-ne", "-t", "bio"], timeout: 60)
        guard r.succeeded else {
            throw DeckError.keyGeneration("Secure Enclave anahtarı oluşturulamadı: \(r.stderr.trimmed)")
        }
        guard let identity = Self.identity(label: label) else {
            throw DeckError.keyGeneration("Oluşturulan Secure Enclave anahtarı bulunamadı.")
        }
        let hash = identity.hash.map { String(format: "%02X", $0) }.joined()
        do {
            let file = Self.keyHandleFile(point: identity.point, keyHandle: identity.hash, comment: "sigil:\(alias)")
            try Self.writeOwnerOnly(file.privateText, to: url)
            try (file.publicLine + "\n").write(to: url.appendingPathExtension("pub"), atomically: true, encoding: .utf8)
            var m = try KeyService(paths: paths, protectWithKeychain: false).material(fileName: fileName)
            m.secureEnclaveKeyHash = hash
            return m
        } catch {
            await delete(fileName: fileName, keyHash: hash)
            throw error
        }
    }

    /// Removes the identity from the Secure Enclave and the handle files. Deleting needs no Touch ID.
    public func delete(fileName: String, keyHash: String?) async {
        if let keyHash, Validation.matches(keyHash, #"^[0-9A-F]{40}$"#) {
            _ = try? await Shell.run(Self.scAuth, ["delete-ctk-identity", "-h", keyHash], timeout: 30)
        }
        let url = paths.keyURL(fileName)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pub"))
    }

    /// The identity's public-key hash (SHA-1, 20 bytes; also its key handle) and uncompressed public point.
    /// Reading the public half needs no Touch ID.
    static func identity(label: String) -> (hash: Data, point: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrAccessGroup as String: kSecAttrAccessGroupToken,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any],
              let hash = attrs[kSecAttrApplicationLabel as String] as? Data, hash.count == 20,
              let ref = attrs[kSecValueRef as String] as CFTypeRef?, CFGetTypeID(ref) == SecKeyGetTypeID()
        else { return nil }
        guard let pub = SecKeyCopyPublicKey(ref as! SecKey),
              let point = SecKeyCopyExternalRepresentation(pub, nil) as Data?, point.count == 65, point.first == 0x04
        else { return nil }
        return (hash, point)
    }

    /// An unencrypted OpenSSH private-key file for a security-key identity: public point + key handle, no secret.
    static func keyHandleFile(point: Data, keyHandle: Data, comment: String,
                              checkInt: UInt32 = UInt32.random(in: .min ... .max)) -> (privateText: String, publicLine: String) {
        func string(_ d: Data) -> Data { var o = UInt32(d.count).bigEndianData; o.append(d); return o }
        func string(_ s: String) -> Data { string(Data(s.utf8)) }

        let pub = string(keyType) + string("nistp256") + string(point) + string(application)
        var priv = checkInt.bigEndianData + checkInt.bigEndianData
        priv += string(keyType) + string("nistp256") + string(point) + string(application)
        priv.append(flags)
        priv += string(keyHandle) + string(Data()) + string(comment)
        var pad: UInt8 = 1
        while priv.count % 8 != 0 { priv.append(pad); pad += 1 }

        var body = Data("openssh-key-v1".utf8); body.append(0)
        body += string("none") + string("none") + string(Data()) + UInt32(1).bigEndianData + string(pub) + string(priv)

        let b64 = body.base64EncodedString()
        let wrapped = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let start = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[start..<(b64.index(start, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + wrapped.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
        return (text, "\(keyType) \(pub.base64EncodedString()) \(comment)")
    }

    private static func writeOwnerOnly(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw DeckError.keyGeneration("Anahtar dosyası yazılamadı.")
        }
    }
}

private extension UInt32 {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
