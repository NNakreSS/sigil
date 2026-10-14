import Foundation

/// Persists the server list as JSON in Application Support. Holds no secrets.
public struct ServerStore: Sendable {
    let paths: DeckPaths

    public init(paths: DeckPaths) { self.paths = paths }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// A corrupt file is moved aside (never overwritten) and an empty list is returned.
    public func load() -> (servers: [Server], warning: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.storeFile.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: paths.storeFile)
            return (try decoder.decode([Server].self, from: data), nil)
        } catch {
            let aside = paths.storeFile.deletingLastPathComponent()
                .appendingPathComponent("servers.json.corrupt-\(ConfigManager.stamp())")
            try? fm.moveItem(at: paths.storeFile, to: aside)
            return ([], "Sunucu listesi okunamadı; bozuk dosya \(aside.lastPathComponent) olarak ayrıldı.")
        }
    }

    public func save(_ servers: [Server]) throws {
        try paths.ensureDirectories()
        let data = try encoder.encode(servers)
        try data.write(to: paths.storeFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.storeFile.path)
    }
}
