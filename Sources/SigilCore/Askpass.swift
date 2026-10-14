import Foundation
import Security

/// Hands a secret (server password or key passphrase) to ssh / ssh-keygen / ssh-add through the
/// SSH_ASKPASS mechanism, so it never appears in a command line. The helper script lives in a 0700
/// temp directory only for the duration of the call; the secret itself is only in the child's environment.
enum Askpass {
    static func withSecret<T>(_ secret: String, _ body: ([String: String]) async throws -> T) async throws -> T {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sigil-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }

        let script = dir.appendingPathComponent("askpass.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$SIGIL_SECRET\"\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let env = [
            "SSH_ASKPASS": script.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":sigil",
            "SIGIL_SECRET": secret,
        ]
        return try await body(env)
    }

    /// 192 random bits, URL-safe base64 (32 characters).
    static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
