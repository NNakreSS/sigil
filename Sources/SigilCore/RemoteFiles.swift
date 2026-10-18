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
    /// For editing: "<mtime> <size>" on the first line, then up to 512 KB of the file.
    static let editRead = #"""
    R=""; read -r P; [ -f "$P" ] || exit 4; [ -r "$P" ] || { sudo -n true 2>/dev/null && R="sudo -n" || exit 7; }
    M=$($R stat -L -c '%Y %s' -- "$P" 2>/dev/null || $R stat -L -f '%m %z' -- "$P" 2>/dev/null) || exit 4
    echo "$M"; $R head -c 524288 -- "$P"
    """#
    /// Saves stdin (after the path and "<mtime> <size> <new size>" lines) into the file: first into a private temp
    /// file whose size is checked, then copied over the original so its owner, mode and inode stay. Refuses when the
    /// file changed on the server since it was read (exit 8).
    static let write = #"""
    read -r P; read -r E1 E2 N
    [ -f "$P" ] || exit 4
    R=""; [ -w "$P" ] || { sudo -n true 2>/dev/null && R="sudo -n" || exit 7; }
    M=$($R stat -L -c '%Y %s' -- "$P" 2>/dev/null || $R stat -L -f '%m %z' -- "$P" 2>/dev/null)
    [ "$M" = "$E1 $E2" ] || exit 8
    T=$(mktemp) || exit 9
    cat > "$T"
    [ "$(wc -c < "$T" | tr -d ' ')" = "$N" ] || { rm -f "$T"; exit 9; }
    if [ -z "$R" ]; then cat "$T" > "$P"; else $R tee -- "$P" < "$T" >/dev/null; fi; rc=$?
    rm -f "$T"; [ $rc -eq 0 ] || exit 9
    $R stat -L -c '%Y %s' -- "$P" 2>/dev/null || $R stat -L -f '%m %z' -- "$P" 2>/dev/null
    """#
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

    /// `sh -c '<script>'` with the script kept verbatim (newlines, quotes), unlike RemoteService.wrap.
    static func command(_ script: String) -> String {
        "sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// Largest file the editor opens.
    public static let editableLimit = 524_288

    /// A file opened for editing, with what identifies the version that was read.
    public struct EditableFile: Sendable, Equatable {
        public var text: String
        /// "<mtime> <size>" when read; saving checks the file still has it.
        public var version: String
        /// Not valid UTF-8 text (or too big): shown, but not saved back.
        public var readOnlyReason: String?
    }

    public func openForEditing(_ id: UUID, _ path: String) async throws -> EditableFile {
        let r = try await runShared(id, FileScript.command(FileScript.editRead), stdin: try FileScript.checkPath(path) + "\n")
        switch r.exitCode {
        case 0: break
        case 4: throw DeckError.invalid("Dosya okunamadı.")
        case 7: throw DeckError.invalid("Bu dosyayı okuma yetkin yok (şifresiz sudo da yok).")
        default: throw DeckError.ssh(SSHErrorText.friendly(r.stderr, exitCode: r.exitCode, timedOut: r.timedOut))
        }
        let parts = r.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let version = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        let text = parts.count > 1 ? String(parts[1]) : ""
        let size = Int(version.split(separator: " ").last ?? "") ?? 0
        var reason: String?
        if size > Self.editableLimit { reason = "Dosya 512 KB’tan büyük; yalnızca başı gösteriliyor ve kaydedilemez." }
        else if text.contains("\u{FFFD}") || text.contains("\0") { reason = "Bu bir metin dosyası değil (ya da UTF-8 değil); kaydedilemez." }
        else if text.utf8.count != size { reason = "Dosya okunurken değişti; yeniden yükle." }
        return EditableFile(text: text, version: version, readOnlyReason: reason)
    }

    /// Writes `text` over the file if it is still the version that was read. Returns the new version.
    public func saveFile(_ id: UUID, _ path: String, text: String, version: String) async throws -> String {
        let v = version.split(separator: " ")
        guard v.count == 2, v.allSatisfy({ Int($0) != nil }) else { throw DeckError.invalid("Dosya sürümü okunamadı; yeniden yükle.") }
        let input = try FileScript.checkPath(path) + "\n\(version) \(text.utf8.count)\n" + text
        let r = try await runShared(id, FileScript.command(FileScript.write), stdin: input, timeout: 120)
        switch r.exitCode {
        case 0: break
        case 4: throw DeckError.invalid("Dosya sunucuda artık yok.")
        case 7: throw DeckError.invalid("Bu dosyaya yazma yetkin yok (şifresiz sudo da yok).")
        case 8: throw DeckError.invalid("Dosya sen açtıktan sonra sunucuda değişmiş; üzerine yazılmadı. Yeniden yükleyip değişikliklerini tekrar yap.")
        case 9: throw DeckError.ssh("Dosya yazılamadı (disk dolu ya da bağlantı koptu); sunucudaki dosya değişmedi.")
        default: throw DeckError.ssh(SSHErrorText.friendly(r.stderr, exitCode: r.exitCode, timedOut: r.timedOut))
        }
        log(id, .info, "Dosya düzenlendi: \(path)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
