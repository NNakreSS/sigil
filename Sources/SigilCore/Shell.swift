import Foundation

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thin async wrapper around Process. Arguments are always passed as an argv array, never through a shell.
public enum Shell {
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        stdin: String? = nil,
        discardStdout: Bool = false,
        timeout: TimeInterval = 60
    ) async throws -> ShellResult {
        _ = ignoreSigpipe
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runSync(executable, arguments, environment, stdin, discardStdout, timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Upper bound kept per stream. Output comes from remote servers, which must not be able to exhaust memory.
    static let maxOutputBytes = 1 << 20

    /// Reads until EOF, keeping at most `limit` bytes and draining (discarding) the rest so the child never blocks.
    static func readCapped(_ handle: FileHandle, limit: Int) -> Data {
        var kept = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if kept.count < limit { kept.append(chunk.prefix(limit - kept.count)) }
        }
        return kept
    }

    private static func runSync(
        _ executable: String, _ arguments: [String], _ extraEnv: [String: String],
        _ stdin: String?, _ discardStdout: Bool, _ timeout: TimeInterval
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        // discardStdout: for commands whose stdout carries secrets we never want in this process (e.g. `op item create`).
        process.standardOutput = discardStdout ? FileHandle.nullDevice : outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        try process.run()

        let group = DispatchGroup()
        let outBox = LockedBox(Data()), errBox = LockedBox(Data())
        if !discardStdout {
            group.enter()
            DispatchQueue.global().async {
                outBox.set(readCapped(outPipe.fileHandleForReading, limit: maxOutputBytes)); group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(readCapped(errPipe.fileHandleForReading, limit: maxOutputBytes)); group.leave()
        }

        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let timedOut = LockedBox(false)
        let killer = DispatchWorkItem {
            if process.isRunning { timedOut.set(true); process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        group.wait()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: timedOut.get()
        )
    }
}
