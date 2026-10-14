import Foundation

/// A saved port forward: localhost:localPort → (as seen from the server) remoteHost:remotePort.
public struct TunnelProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(id: UUID = UUID(), name: String, localPort: Int, remoteHost: String = "localhost", remotePort: Int) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    public func validated() throws -> TunnelProfile {
        guard (1024...65535).contains(localPort) else { throw DeckError.invalid("Yerel port 1024–65535 arasında olmalı.") }
        guard (1...65535).contains(remotePort) else { throw DeckError.invalid("Uzak port 1–65535 arasında olmalı.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw DeckError.invalid("Tünele bir ad ver.") }
        return TunnelProfile(id: id, name: name, localPort: localPort, remoteHost: try Validation.host(remoteHost), remotePort: remotePort)
    }

    public var summary: String { "localhost:\(localPort) → \(remoteHost):\(remotePort)" }
}

/// A running `ssh -N -L` process.
final class TunnelProcess: @unchecked Sendable {
    let process: Process
    let errors: Pipe
    init(process: Process, errors: Pipe) {
        self.process = process
        self.errors = errors
    }
}

extension RemoteService {
    /// Starts the forward and waits briefly to catch immediate failures (port in use, auth refused).
    func startTunnel(target: RemoteTarget, auth: RemoteAuth, tunnel: TunnelProfile,
                     onExit: @escaping @Sendable (String) -> Void) async throws -> TunnelProcess {
        var args = arguments(for: target, auth: auth, command: "")
        args.removeLast()   // no remote command
        let destination = args.removeLast()
        args += [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:\(tunnel.localPort):\(tunnel.remoteHost):\(tunnel.remotePort)",
            destination,
        ]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let handle = TunnelProcess(process: p, errors: err)
        p.terminationHandler = { proc in
            let text = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
            onExit(proc.terminationReason == .uncaughtSignal ? "" : text)
        }
        try p.run()

        // Either the forward is listening, or ssh has already exited with a reason.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !p.isRunning {
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw DeckError.ssh(SSHErrorText.friendly(text.isEmpty ? "Tünel açılamadı." : text, exitCode: p.terminationStatus, timedOut: false))
            }
            if Self.isListening(port: tunnel.localPort) { return handle }
        }
        return handle
    }

    static func isListening(port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
