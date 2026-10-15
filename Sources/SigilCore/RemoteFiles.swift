import Foundation

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case directory, file, link, other }
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: Int64
    public let modified: Date
    public let mode: String
    public let owner: String
    public var isHidden: Bool { name.hasPrefix(".") }
}

/// File operations over ssh. Paths travel on stdin (one per line), never inside the command, so names with spaces,
/// quotes or `$` cannot be misread by the remote shell.
enum FileScript {
    /// GNU find's -printf where available (most Linux servers); otherwise stat per entry (BusyBox, BSD).
    static let list = """
    read -r P; if [ "$P" = "~" ]; then cd; else cd -- "$P" 2>/dev/null || exit 4; fi; pwd; \
    if find . -maxdepth 0 -printf "" >/dev/null 2>&1; then \
      find . -mindepth 1 -maxdepth 1 -printf "%y\\t%s\\t%T@\\t%M\\t%u\\t%f\\n" 2>/dev/null | head -n 5000; \
    else n=0; for f in .* *; do \
      case "$f" in .|..) continue;; esac; [ -e "$f" ] || [ -L "$f" ] || continue; n=$((n+1)); [ $n -gt 5000 ] && break; \
      if [ -L "$f" ]; then t=l; elif [ -d "$f" ]; then t=d; elif [ -f "$f" ]; then t=f; else t=o; fi; \
      S=$(stat -c "%s\\t%Y\\t%A\\t%U" -- "$f" 2>/dev/null || stat -f "%z%t%m%t%Sp%t%Su" -- "$f" 2>/dev/null) || continue; \
      printf "%s\\t%s\\t%s\\n" "$t" "$S" "$f"; done; fi
    """
    static let read = #"read -r P; [ -f "$P" ] || exit 4; head -c 262144 -- "$P""#
    static let mkdir = #"read -r P; mkdir -p -- "$P""#
    static let rename = #"read -r A; read -r B; [ -e "$B" ] && exit 5; mv -- "$A" "$B""#
    static let delete = #"read -r P; case "$P" in ""|"/"|"/*") exit 6;; esac; rm -rf -- "$P""#

    static func parse(_ text: String, in dir: String) -> [RemoteFile] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, !f[5].isEmpty else { return nil }
            let kind: RemoteFile.Kind = f[0] == "d" ? .directory : f[0] == "f" ? .file : f[0] == "l" ? .link : .other
            let path = dir == "/" ? "/" + f[5] : dir + "/" + f[5]
            return RemoteFile(name: f[5], path: path, kind: kind, size: Int64(f[1]) ?? 0,
                              modified: Date(timeIntervalSince1970: Double(f[2]) ?? 0), mode: f[3], owner: f[4])
        }
        .sorted { a, b in
            if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func checkPath(_ p: String) throws -> String {
        guard !p.isEmpty, !p.contains("\n"), !p.contains("\0") else { throw DeckError.invalid("Geçersiz yol.") }
        return p
    }
}

extension DeckModel {
    /// Lists a directory ("~" = home). Returns the resolved absolute path and its entries, folders first.
    public func listDirectory(_ id: UUID, _ path: String) async throws -> (path: String, files: [RemoteFile]) {
        let r = try await runShared(id, RemoteService.wrap(FileScript.list), stdin: try FileScript.checkPath(path) + "\n")
        if r.exitCode == 4 { throw DeckError.invalid("Klasör açılamadı: \(path)") }
        guard r.succeeded else { throw DeckError.ssh(SSHErrorText.friendly(r.stderr, exitCode: r.exitCode, timedOut: r.timedOut)) }
        let lines = r.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let dir = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? path
        return (dir, FileScript.parse(lines.count > 1 ? String(lines[1]) : "", in: dir))
    }

    /// The first 256 KB of a file, for a quick look.
    public func readFile(_ id: UUID, _ path: String) async throws -> String {
        let r = try await runShared(id, RemoteService.wrap(FileScript.read), stdin: try FileScript.checkPath(path) + "\n")
        if r.exitCode == 4 { throw DeckError.invalid("Dosya okunamadı.") }
        guard r.succeeded else { throw DeckError.ssh(SSHErrorText.friendly(r.stderr, exitCode: r.exitCode, timedOut: r.timedOut)) }
        return r.stdout
    }

    public func makeDirectory(_ id: UUID, _ path: String) async throws {
        try await fileOp(id, FileScript.mkdir, [path])
    }

    public func renameFile(_ id: UUID, from: String, to: String) async throws {
        try await fileOp(id, FileScript.rename, [from, to])
        log(id, .info, "Dosya taşındı: \(from) → \(to)")
    }

    public func deleteFile(_ id: UUID, _ path: String) async throws {
        try await fileOp(id, FileScript.delete, [path])
        log(id, .warning, "Silindi: \(path)")
    }

    private func fileOp(_ id: UUID, _ script: String, _ paths: [String]) async throws {
        let input = try paths.map(FileScript.checkPath).joined(separator: "\n") + "\n"
        let r = try await runShared(id, RemoteService.wrap(script), stdin: input)
        switch r.exitCode {
        case 0: return
        case 5: throw DeckError.invalid("Bu adda bir dosya zaten var.")
        case 6: throw DeckError.invalid("Bu yol silinemez.")
        default: throw DeckError.ssh(r.stderr.trimmed.isEmpty ? "İşlem yapılamadı." : r.stderr.trimmed)
        }
    }

    /// scp over the shared connection. `toServer`: local → remote directory; otherwise remote → local.
    public func copy(_ id: UUID, local: URL, remote remotePath: String, toServer: Bool) async throws {
        guard let s = server(id) else { throw DeckError.notFound }
        let t = try await sessionTarget(id)
        var args = remote.arguments(for: t, auth: auth(s.store, s.keyFileName), command: "")
        args.removeLast()   // command
        args.removeLast()   // user@host
        if let i = args.firstIndex(of: "-p") { args[i] = "-P" }   // scp spells the port option differently
        let remoteSpec = "\(t.user)@\(t.host.contains(":") ? "[\(t.host)]" : t.host):\(try FileScript.checkPath(remotePath))"
        args += ["-r", "-q"] + (toServer ? [local.path, remoteSpec] : [remoteSpec, local.path])
        let r = try await Shell.run("/usr/bin/scp", args, timeout: 3600)
        guard r.succeeded else { throw DeckError.ssh(r.stderr.trimmed.isEmpty ? "Kopyalanamadı." : r.stderr.trimmed) }
        log(id, .info, toServer ? "Yüklendi: \(local.lastPathComponent) → \(remotePath)" : "İndirildi: \(remotePath)")
    }
}
