import Foundation

/// One authenticated ssh connection kept open in the background (ControlMaster) while a panel such as the file
/// browser or Docker is open. Commands run through its socket without authenticating again; closing the panel
/// closes it. The socket lives in a 0700 folder next to Sigil's ssh config.
public final class RemoteSession: @unchecked Sendable {
    public let path: String
    let process: Process

    init(path: String, process: Process) {
        self.path = path
        self.process = process
    }

    public var isAlive: Bool { process.isRunning && FileManager.default.fileExists(atPath: path) }

    func close() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: path)
    }
}

extension RemoteService {
    /// Starts `ssh -M -N` and waits (up to two minutes, for a Touch ID or 1Password approval) until the shared
    /// connection is ready.
    func openSession(target: RemoteTarget, auth: RemoteAuth, socketPath: String) async throws -> RemoteSession {
        var t = target
        t.controlPath = socketPath
        var args = arguments(for: t, auth: auth, command: "")
        args.removeLast()   // no remote command
        let destination = args.removeLast()
        if let i = args.firstIndex(of: "ControlMaster=no") { args[i] = "ControlMaster=yes" }
        args += ["-N", "-T", "-o", "ControlPersist=no", destination]

        if case .password = auth { throw DeckError.invalid("Şifreyle paylaşılan bağlantı açılmaz.") }
        try? FileManager.default.removeItem(atPath: socketPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        for _ in 0..<1200 {
            if FileManager.default.fileExists(atPath: socketPath) { return RemoteSession(path: socketPath, process: p) }
            if !p.isRunning {
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw DeckError.ssh(SSHErrorText.friendly(text.isEmpty ? "Bağlantı kurulamadı." : text, exitCode: p.terminationStatus, timedOut: false))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        p.terminate()
        throw DeckError.ssh("Bağlantı iki dakika içinde kurulamadı (onay verilmedi mi?).")
    }
}

extension DeckModel {
    /// The target for `id`, going through its shared connection (opened on first use).
    public func sessionTarget(_ id: UUID) async throws -> RemoteTarget {
        guard let s = server(id) else { throw DeckError.notFound }
        // Within the approval window the shared login already does this (and asks once for everything).
        let shared = sharedTarget(for: s)
        if shared.persist != nil { return shared }
        var t = target(for: s)
        if let existing = sessions[id], existing.isAlive {
            t.controlPath = existing.path
            return t
        }
        sessions[id]?.close()
        let dir = paths.includeFile.deletingLastPathComponent().appendingPathComponent("cm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Unix socket paths are short (104 bytes): a short random name.
        let socket = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased()).path
        let session = try await remote.openSession(target: t, auth: auth(s.store, s.keyFileName), socketPath: socket)
        sessions[id] = session
        t.controlPath = session.path
        return t
    }

    public func closeSession(_ id: UUID) {
        sessions[id]?.close()
        sessions[id] = nil
    }

    public func closeAllSessions() {
        for s in sessions.values { s.close() }
        sessions = [:]
    }

    /// Runs one command over the shared connection.
    func runShared(_ id: UUID, _ command: String, stdin: String? = nil, timeout: TimeInterval? = nil) async throws -> ShellResult {
        guard let s = server(id) else { throw DeckError.notFound }
        let t = try await sessionTarget(id)
        return try await remote.execute(t, auth(s.store, s.keyFileName), command, stdin: stdin, timeout: timeout)
    }
}
