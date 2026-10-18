import Foundation

/// The kinds of file the editor knows how to colour and check.
public enum CodeLanguage: String, CaseIterable, Sendable, Identifiable {
    case plain, shell, env, yaml, json, conf, nginx, systemd, dockerfile, caddyfile, python, javascript, php, sql, markdown, xml, log

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plain: return "Düz metin"
        case .shell: return "Shell"
        case .env: return ".env"
        case .yaml: return "YAML"
        case .json: return "JSON"
        case .conf: return "Yapılandırma (ini/conf/toml)"
        case .nginx: return "nginx"
        case .systemd: return "systemd"
        case .dockerfile: return "Dockerfile"
        case .caddyfile: return "Caddyfile"
        case .python: return "Python"
        case .javascript: return "JavaScript / TypeScript"
        case .php: return "PHP"
        case .sql: return "SQL"
        case .markdown: return "Markdown"
        case .xml: return "XML / HTML"
        case .log: return "Log"
        }
    }

    /// What ⌘/ puts in front of a line; nil when the format has no line comments.
    public var lineComment: String? {
        switch self {
        case .shell, .env, .yaml, .conf, .nginx, .systemd, .dockerfile, .caddyfile, .python: return "#"
        case .javascript, .php: return "//"
        case .sql: return "--"
        case .plain, .json, .markdown, .xml, .log: return nil
        }
    }

    /// Spaces per indent level (0 = a tab).
    public var indentWidth: Int {
        switch self {
        case .python, .php, .conf, .nginx, .sql, .xml: return 4
        case .caddyfile: return 0
        default: return 2
        }
    }

    /// Guesses the language from the file name, its folder and the first line (shebang).
    public static func detect(path: String, firstLine: String = "") -> CodeLanguage {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        let dir = (path as NSString).deletingLastPathComponent.lowercased()

        if lower == ".env" || lower.hasPrefix(".env.") || ext == "env" { return .env }
        if lower.hasPrefix("dockerfile") || ext == "dockerfile" || lower == "containerfile" { return .dockerfile }
        if lower == "caddyfile" || ext == "caddy" { return .caddyfile }
        if ["service", "timer", "socket", "mount", "target", "path", "slice", "automount"].contains(ext) { return .systemd }
        if lower.contains("nginx") || dir.contains("/nginx") { if ext == "conf" || ext.isEmpty || dir.contains("sites-") { return .nginx } }
        if [".bashrc", ".bash_profile", ".profile", ".zshrc", ".bash_aliases", ".bash_logout", "crontab", "authorized_keys"].contains(lower) { return .shell }

        switch ext {
        case "sh", "bash", "zsh", "ksh", "dash": return .shell
        case "yml", "yaml": return .yaml
        case "json", "jsonc", "webmanifest": return .json
        case "conf", "cfg", "cnf", "ini", "toml", "properties", "local", "rules": return .conf
        case "py", "pyw": return .python
        case "js", "mjs", "cjs", "ts", "tsx", "jsx", "mts": return .javascript
        case "php", "phtml": return .php
        case "sql": return .sql
        case "md", "markdown": return .markdown
        case "xml", "html", "htm", "svg", "plist", "xhtml": return .xml
        case "log", "out", "err": return .log
        default: break
        }
        if lower.hasSuffix("_config") || dir.hasPrefix("/etc/ssh") { return .conf }
        if dir.hasPrefix("/var/log") || lower.range(of: #"\.log\.\d+$"#, options: .regularExpression) != nil { return .log }

        if firstLine.hasPrefix("#!") {
            if firstLine.range(of: #"\b(ba|z|da|k|a)?sh\b"#, options: .regularExpression) != nil { return .shell }
            if firstLine.contains("python") { return .python }
            if firstLine.contains("node") || firstLine.contains("deno") || firstLine.contains("bun") { return .javascript }
            if firstLine.contains("php") { return .php }
        }
        if firstLine.hasPrefix("<?xml") || firstLine.lowercased().hasPrefix("<!doctype html") { return .xml }
        if firstLine.hasPrefix("<?php") { return .php }
        return .plain
    }
}

// MARK: - Highlighting

public enum TokenKind: Sendable, Hashable {
    case comment, string, number, keyword, key, variable, section, constant, punctuation, error, warning
}

public struct Token: Sendable, Hashable {
    public let range: NSRange
    public let kind: TokenKind
}

/// Regex-based colouring. First the "protected" spans (strings, comments) are found left to right, so a `#` inside a
/// string is not a comment; then the other rules colour what is left.
public enum Highlighter {
    struct Rule {
        let regex: NSRegularExpression
        let kind: TokenKind
        /// Capture group to colour (0 = the whole match).
        let group: Int
        init(_ pattern: String, _ kind: TokenKind, group: Int = 0, caseless: Bool = false) {
            var o: NSRegularExpression.Options = [.anchorsMatchLines]
            if caseless { o.insert(.caseInsensitive) }
            regex = try! NSRegularExpression(pattern: pattern, options: o)
            self.kind = kind
            self.group = group
        }
    }

    /// One alternation per language; each capture group is a protected kind, in order.
    struct Protected {
        let regex: NSRegularExpression
        let kinds: [TokenKind]
        init(_ parts: [(String, TokenKind)]) {
            regex = try! NSRegularExpression(pattern: parts.map { "(\($0.0))" }.joined(separator: "|"), options: [.anchorsMatchLines])
            kinds = parts.map(\.1)
        }
    }

    private static let dq = #""(?:[^"\\\n]|\\.)*"?"#
    private static let sq = #"'(?:[^'\\\n]|\\.)*'?"#
    private static let hashComment = #"(?:^|(?<=\s))#.*$"#
    private static let number = Rule(#"\b-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#, .number)

    private static func words(_ list: String, _ kind: TokenKind, caseless: Bool = false) -> Rule {
        Rule(#"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#, kind, caseless: caseless)
    }

    struct Grammar {
        let protected: Protected?
        let rules: [Rule]
        /// Rules also applied inside double-quoted strings (shell variables).
        let insideStrings: [Rule]
    }

    private static let shellVariable = Rule(#"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$-]"#, .variable)

    static let grammars: [CodeLanguage: Grammar] = {
        var g: [CodeLanguage: Grammar] = [:]
        g[.shell] = Grammar(
            protected: Protected([(hashComment, .comment), (dq, .string), (sq, .string)]),
            rules: [words("if then else elif fi for while until do done case esac in function return local export readonly set unset shift exit source alias select declare trap eval exec break continue", .keyword),
                    words("echo printf cd read test sudo cat grep sed awk systemctl apt apt-get docker curl wget chmod chown mkdir rm cp mv ls tar", .key),
                    shellVariable, number, Rule(#"[|&;<>]+"#, .punctuation)],
            insideStrings: [shellVariable])
        g[.env] = Grammar(
            protected: Protected([(#"^\s*#.*$"#, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)(?=\s*=)"#, .key, group: 1), Rule(#"^\s*export\b"#, .keyword),
                    shellVariable, words("true false yes no on off null", .constant, caseless: true), number],
            insideStrings: [shellVariable])
        g[.yaml] = Grammar(
            protected: Protected([(hashComment, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"^\s*(?:-\s+)*([^\s#:'"\-][^#:\n]*?|-[^\s#:\n][^#:\n]*?)\s*:(?=\s|$)"#, .key, group: 1),
                    Rule(#"^(?:---|\.\.\.)\s*$"#, .section), Rule(#"^\s*-(?=\s)"#, .punctuation),
                    Rule(#"[&*][A-Za-z0-9_-]+"#, .variable), shellVariable,
                    words("true false null yes no on off", .constant, caseless: true), Rule(#"(?<=:\s)~$"#, .constant), number, Rule(#"[|>][+-]?\s*$"#, .punctuation)],
            insideStrings: [shellVariable])
        g[.json] = Grammar(
            protected: Protected([(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, .key), (dq, .string)]),
            rules: [words("true false null", .constant), number, Rule(#"[{}\[\],:]"#, .punctuation)], insideStrings: [])
        g[.conf] = Grammar(
            protected: Protected([(#"^\s*[#;].*$"#, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"^\s*\[[^\]\n]+\]"#, .section), Rule(#"^\s*([A-Za-z0-9_.\-]+)"#, .key, group: 1),
                    words("true false yes no on off none null", .constant, caseless: true), shellVariable, number],
            insideStrings: [])
        g[.systemd] = Grammar(
            protected: Protected([(#"^\s*[#;].*$"#, .comment), (dq, .string)]),
            rules: [Rule(#"^\s*\[[^\]\n]+\]"#, .section), Rule(#"^\s*([A-Za-z0-9]+)(?==)"#, .key, group: 1),
                    words("true false yes no on off always on-failure", .constant), Rule(#"%[a-zA-Z%]"#, .variable), shellVariable, number],
            insideStrings: [])
        g[.nginx] = Grammar(
            protected: Protected([(hashComment, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"^\s*([a-z_][a-z0-9_]*)"#, .keyword, group: 1), words("server location upstream http events if include return", .keyword),
                    Rule(#"\$[A-Za-z_][A-Za-z0-9_]*"#, .variable), words("on off", .constant),
                    Rule(#"\b\d+[kKmMgGsShHdDwWyY]?\b"#, .number), Rule(#"[{};]"#, .punctuation)],
            insideStrings: [Rule(#"\$[A-Za-z_][A-Za-z0-9_]*"#, .variable)])
        g[.caddyfile] = Grammar(
            protected: Protected([(hashComment, .comment), (dq, .string), (#"`[^`]*`"#, .string)]),
            rules: [Rule(#"^\s*([a-z_][a-z0-9_]*)"#, .keyword, group: 1), Rule(#"^[^\s{#][^{\n]*(?=\{)"#, .section),
                    Rule(#"\{[a-zA-Z_.$][^}\s]*\}"#, .variable), Rule(#"@[A-Za-z0-9_-]+"#, .variable), number, Rule(#"[{}]"#, .punctuation)],
            insideStrings: [])
        g[.dockerfile] = Grammar(
            protected: Protected([(#"^\s*#.*$"#, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"^\s*(FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL|MAINTAINER)\b"#, .keyword, group: 1, caseless: true),
                    Rule(#"\bAS\b"#, .keyword, caseless: true), Rule(#"--[a-z-]+"#, .key), shellVariable, number],
            insideStrings: [shellVariable])
        g[.python] = Grammar(
            protected: Protected([(#"#.*$"#, .comment), (#"(?:[rbuf]|rb|br|fr|rf)?(?:\"\"\"[\s\S]*?(?:\"\"\"|$(?![\s\S]))|'''[\s\S]*?(?:'''|$(?![\s\S])))"#, .string),
                                  (#"(?:[rbuf]|rb|br|fr|rf)?"# + dq, .string), (#"(?:[rbuf]|rb|br|fr|rf)?"# + sq, .string)]),
            rules: [words("def class return if elif else for while try except finally with as import from pass break continue raise yield lambda global nonlocal assert del in is not and or async await match case", .keyword),
                    words("True False None self", .constant), Rule(#"^\s*@[\w.]+"#, .variable), Rule(#"(?<=def |class )\w+"#, .key), number],
            insideStrings: [])
        g[.javascript] = Grammar(
            protected: Protected([(#"//.*$"#, .comment), (#"/\*[\s\S]*?(?:\*/|$(?![\s\S]))"#, .comment), (dq, .string), (sq, .string), (#"`(?:[^`\\]|\\.)*`?"#, .string)]),
            rules: [words("const let var function return if else for while do switch case default break continue new try catch finally throw class extends import export from as async await typeof instanceof in of this super yield type interface enum implements public private protected readonly static", .keyword),
                    words("true false null undefined NaN", .constant), Rule(#"(?<=function |class )\w+"#, .key), Rule(#"\b[A-Za-z_$][\w$]*(?=\s*:)"#, .key), number],
            insideStrings: [])
        g[.php] = Grammar(
            protected: Protected([(#"(?://|#).*$"#, .comment), (#"/\*[\s\S]*?(?:\*/|$(?![\s\S]))"#, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"<\?php|\?>"#, .section), Rule(#"\$[A-Za-z_]\w*"#, .variable),
                    words("function return if else elseif foreach for while do switch case default break continue new try catch finally throw class extends implements interface trait namespace use public private protected static const echo require require_once include include_once array fn match", .keyword, caseless: true),
                    words("true false null", .constant, caseless: true), number],
            insideStrings: [Rule(#"\$[A-Za-z_]\w*"#, .variable)])
        g[.sql] = Grammar(
            protected: Protected([(#"--.*$"#, .comment), (#"/\*[\s\S]*?(?:\*/|$(?![\s\S]))"#, .comment), (sq, .string), (#""[^"\n]*""#, .key)]),
            rules: [words("select from where and or not insert into values update set delete create alter drop table index view database schema primary key foreign references join left right inner outer on group by order having limit offset as distinct union all exists in is null default grant revoke begin commit rollback if returning case when then else end", .keyword, caseless: true),
                    words("true false null", .constant, caseless: true), number],
            insideStrings: [])
        g[.markdown] = Grammar(
            protected: Protected([(#"^```[\s\S]*?(?:^```|$(?![\s\S]))"#, .string), (#"`[^`\n]+`"#, .string)]),
            rules: [Rule(#"^#{1,6}\s.*$"#, .section), Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .keyword), Rule(#"\[[^\]\n]*\]\([^)\n]*\)"#, .key),
                    Rule(#"^\s*(?:[-*+]|\d+\.)\s"#, .punctuation), Rule(#"^>.*$"#, .comment)],
            insideStrings: [])
        g[.xml] = Grammar(
            protected: Protected([(#"<!--[\s\S]*?(?:-->|$(?![\s\S]))"#, .comment), (dq, .string), (sq, .string)]),
            rules: [Rule(#"</?[A-Za-z][\w:.-]*|/?>"#, .keyword), Rule(#"\s([A-Za-z_:][\w:.-]*)(?==)"#, .key, group: 1), Rule(#"&[a-z#0-9]+;"#, .constant)],
            insideStrings: [])
        g[.log] = Grammar(
            protected: nil,
            rules: [Rule(#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|^[A-Z][a-z]{2} [ \d]\d \d{2}:\d{2}:\d{2}"#, .comment),
                    Rule(#"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, .key),
                    Rule(#"\b(?:INFO|NOTICE)\b"#, .keyword),
                    Rule(#"\b(?:WARN|WARNING)\b|\bwarn(?:ing)?\b"#, .warning),
                    Rule(#"\b(?:ERROR|ERR|FATAL|CRIT|CRITICAL|PANIC|EMERG|ALERT)\b|\b(?:error|failed|failure|denied|refused|fatal)\b"#, .error),
                    Rule(#"\bDEBUG\b"#, .comment), Rule(#"\b[1-5]\d\d\b(?= )"#, .number)],
            insideStrings: [])
        return g
    }()

    /// Tokens for `text` (whole document). Later tokens win where they overlap.
    public static func tokens(_ text: String, language: CodeLanguage) -> [Token] {
        guard let g = grammars[language] else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Token] = []
        var protectedRanges: [NSRange] = []
        if let p = g.protected {
            p.regex.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m else { return }
                for (i, kind) in p.kinds.enumerated() {
                    let r = m.range(at: i + 1)
                    if r.location != NSNotFound, r.length > 0 {
                        out.append(Token(range: r, kind: kind))
                        protectedRanges.append(r)
                        break
                    }
                }
            }
        }
        // Gaps between protected spans: where the other rules apply.
        var gaps: [NSRange] = []
        var cursor = 0
        for r in protectedRanges {
            if r.location > cursor { gaps.append(NSRange(location: cursor, length: r.location - cursor)) }
            cursor = max(cursor, NSMaxRange(r))
        }
        if cursor < ns.length { gaps.append(NSRange(location: cursor, length: ns.length - cursor)) }

        var rest: [Token] = []
        for gap in gaps {
            for rule in g.rules {
                rule.regex.enumerateMatches(in: text, range: gap) { m, _, _ in
                    guard let r = m?.range(at: rule.group), r.location != NSNotFound, r.length > 0 else { return }
                    rest.append(Token(range: r, kind: rule.kind))
                }
            }
        }
        if !g.insideStrings.isEmpty {
            for t in out where t.kind == .string && ns.character(at: t.range.location) == 34 {   // double quotes only
                for rule in g.insideStrings {
                    rule.regex.enumerateMatches(in: text, range: t.range) { m, _, _ in
                        guard let r = m?.range(at: rule.group), r.location != NSNotFound, r.length > 0 else { return }
                        rest.append(Token(range: r, kind: rule.kind))
                    }
                }
            }
        }
        return out + rest
    }
}
