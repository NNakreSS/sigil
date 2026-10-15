import Foundation
import XCTest
@testable import SigilCore

/// A scratch ~/.ssh + Application Support that is deleted after the test. Nothing here touches the real home.
final class Sandbox {
    let root: URL
    let paths: DeckPaths

    init() throws {
        // Short path: sshd/ssh refuse very long unix socket and control paths.
        root = URL(fileURLWithPath: "/tmp/sd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = DeckPaths(
            sshDir: root.appendingPathComponent("ssh", isDirectory: true),
            supportDir: root.appendingPathComponent("support", isDirectory: true)
        )
        try paths.ensureDirectories()
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// A throw-away OpenSSH server on 127.0.0.1, running as the current user, accepting only public keys and
/// reading authorized keys from a scratch file (so the real ~/.ssh/authorized_keys is never involved).
final class LocalSSHD {
    let dir: URL
    let port: Int
    let authorizedKeys: URL
    let bootstrapKeyName: String
    private var process: Process?

    init(sandbox: Sandbox, allowPasswordAuth: Bool = false, name: String = "sshd", bootstrapKeyName: String = "bootstrap") throws {
        self.bootstrapKeyName = bootstrapKeyName
        dir = sandbox.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        port = Int.random(in: 40000...59000)
        authorizedKeys = dir.appendingPathComponent("authorized_keys")

        let hostKey = dir.appendingPathComponent("host_ed25519")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])

        // Key used to bootstrap the first login in place of a password.
        let bootstrap = sandbox.paths.keyURL(bootstrapKeyName)
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", bootstrap.path])
        let pub = try String(contentsOf: bootstrap.appendingPathExtension("pub"), encoding: .utf8)
        try pub.write(to: authorizedKeys, atomically: true, encoding: .utf8)

        let cfg = dir.appendingPathComponent("sshd_config")
        let text = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        PidFile \(dir.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorizedKeys.path)
        PubkeyAuthentication yes
        PasswordAuthentication \(allowPasswordAuth ? "yes" : "no")
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        LogLevel ERROR
        Subsystem sftp internal-sftp
        """
        try text.write(to: cfg, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-e", "-f", cfg.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        process = p
        try waitUntilListening()
    }

    deinit { stop() }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    var target: RemoteTarget { RemoteTarget(host: "127.0.0.1", port: port, user: NSUserName()) }

    var authorizedKeyLines: [String] {
        ((try? String(contentsOf: authorizedKeys, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    private func waitUntilListening() throws {
        for _ in 0..<50 {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(s) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("local sshd did not start listening")
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "test", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
