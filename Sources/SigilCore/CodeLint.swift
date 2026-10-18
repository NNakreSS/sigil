import Foundation

/// A problem the editor shows next to a line.
public struct Diagnostic: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable { case error, warning }
    /// 1-based.
    public let line: Int
    public let message: String
    public let severity: Severity
    public var id: String { "\(line):\(message)" }

    public init(line: Int, message: String, severity: Severity = .error) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

/// Checks run on this Mac while typing. Nothing here touches the server.
public enum CodeLint {
    /// Fast, synchronous checks (JSON, YAML, .env).
    public static func check(_ text: String, language: CodeLanguage) -> [Diagnostic] {
        switch language {
        case .json: return json(text)
        case .yaml: return yaml(text)
        case .env: return env(text)
        default: return []
        }
    }

    /// Shell syntax via the Mac's own shell (`-n`: parse only, never run).
    public static func shell(_ text: String) async -> [Diagnostic] {
        let first = text.prefix { $0 != "\n" }
        let shell = first.contains("bash") ? "/bin/bash" : first.contains("zsh") ? "/bin/zsh" : "/bin/sh"
        guard let r = try? await Shell.run(shell, ["-n"], environment: ["LC_ALL": "C"], stdin: text, timeout: 5) else { return [] }
        return parseShellErrors(r.stderr)
    }

    static func parseShellErrors(_ stderr: String) -> [Diagnostic] {
        let re = try! NSRegularExpression(pattern: #"line (\d+):\s*(.*)$|:(\d+):\s*(.*)$"#, options: [.anchorsMatchLines])
        var out: [Diagnostic] = []
        for line in stderr.split(whereSeparator: \.isNewline).map(String.init) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let g = m.range(at: 1).location != NSNotFound ? 1 : 3
            guard let n = Int(ns.substring(with: m.range(at: g))) else { continue }
            let msg = ns.substring(with: m.range(at: g + 1)).replacingOccurrences(of: "syntax error", with: "sözdizimi hatası")
            out.append(Diagnostic(line: n, message: msg))
        }
        return out
    }

    // MARK: JSON

    static func json(_ text: String) -> [Diagnostic] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return []
        } catch let e as NSError {
            let detail = (e.userInfo["NSDebugDescription"] as? String) ?? e.localizedDescription
            var line = 1
            if let idx = e.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                line = lineNumber(atUTF8Offset: idx, in: text)
            } else if let m = detail.range(of: #"line (\d+)"#, options: .regularExpression),
                      let n = Int(detail[m].dropFirst(5)) {
                line = n
            }
            return [Diagnostic(line: line, message: "Geçersiz JSON: " + detail)]
        }
    }

    static func lineNumber(atUTF8Offset offset: Int, in text: String) -> Int {
        var line = 1
        for (i, b) in text.utf8.enumerated() {
            if i >= offset { break }
            if b == 10 { line += 1 }
        }
        return line
    }

    // MARK: YAML (structure only; no full parser)

    static func yaml(_ text: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        // key → line, per indentation level, reset when a shallower line starts a new block.
        var seen: [Int: [String: Int]] = [:]
        let keyRe = try! NSRegularExpression(pattern: #"^(\s*)([A-Za-z0-9_.\-]+|"[^"]*"|'[^']*')\s*:(?:\s|$)"#)
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" || trimmed == "..." { seen = [:]; continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            if indent.contains("\t") {
                out.append(Diagnostic(line: n, message: "YAML’de girinti için tab kullanılamaz; boşluk kullan."))
                continue
            }
            if line.range(of: #"^\s*-?\s*[A-Za-z_][\w.-]*:[^\s:/\[{'"]"#, options: .regularExpression) != nil
                && line.range(of: #"^\s*-?\s*[A-Za-z_][\w.-]*:\d+(:\d+)?\s*$"#, options: .regularExpression) == nil {
                out.append(Diagnostic(line: n, message: "“:” işaretinden sonra boşluk olmalı.", severity: .warning))
            }
            if unbalancedQuotes(stripComment(trimmed)) {
                out.append(Diagnostic(line: n, message: "Kapanmamış tırnak.", severity: .warning))
            }
            let ns = line as NSString
            let level = indent.count
            for k in seen.keys where k > level { seen[k] = nil }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") { seen[level + 2] = nil }
            if let m = keyRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let first = seen[level]?[key] {
                    out.append(Diagnostic(line: n, message: "“\(key)” aynı seviyede ikinci kez tanımlanmış (önceki: satır \(first)).", severity: .warning))
                } else {
                    seen[level, default: [:]][key] = n
                }
            }
        }
        return out
    }

    private static func stripComment(_ s: String) -> String {
        var inS = false, inD = false, prev: Character = " "
        for (i, c) in s.enumerated() {
            if c == "'" && !inD { inS.toggle() }
            if c == "\"" && !inS && prev != "\\" { inD.toggle() }
            if c == "#" && !inS && !inD && (i == 0 || prev == " ") { return String(s.prefix(i)) }
            prev = c
        }
        return s
    }

    private static func unbalancedQuotes(_ s: String) -> Bool {
        // Only a value that starts with a quote must end with one (YAML allows apostrophes inside plain text).
        guard let colon = s.range(of: ": ") ?? (s.hasPrefix("- ") ? s.range(of: "- ") : nil) else { return false }
        let value = s[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let q = value.first, q == "\"" || q == "'" else { return false }
        if value.count == 1 { return true }
        if q == "\"" { return !(value.hasSuffix("\"") && !value.hasSuffix("\\\"")) }
        return !value.hasSuffix("'")
    }

    // MARK: .env

    static func env(_ text: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var keys: [String: Int] = [:]
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let body = t.hasPrefix("export ") ? String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) : t
            guard let eq = body.firstIndex(of: "=") else {
                out.append(Diagnostic(line: n, message: "ANAHTAR=değer biçiminde değil."))
                continue
            }
            let key = String(body[..<eq])
            if key.hasSuffix(" ") || body[body.index(after: eq)...].hasPrefix(" ") {
                out.append(Diagnostic(line: n, message: "“=” işaretinin etrafında boşluk olmamalı."))
            }
            let name = key.trimmingCharacters(in: .whitespaces)
            if name.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) == nil {
                out.append(Diagnostic(line: n, message: "“\(name)” geçerli bir değişken adı değil."))
            }
            if let first = keys[name] {
                out.append(Diagnostic(line: n, message: "\(name) ikinci kez tanımlanmış (önceki: satır \(first)); sonuncusu geçerli olur.", severity: .warning))
            } else { keys[name] = n }
            let value = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let q = value.first, q == "\"" || q == "'" {
                let closed = value.dropFirst().contains(q)
                if !closed { out.append(Diagnostic(line: n, message: "Kapanmamış tırnak.")) }
            } else if value.contains(" ") && !value.contains(" #") {
                out.append(Diagnostic(line: n, message: "Boşluk içeren değer tırnak içinde olmalı.", severity: .warning))
            }
        }
        return out
    }
}
