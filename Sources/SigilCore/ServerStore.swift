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
            do { return (try decoder.decode([Server].self, from: data), nil) } catch {
                // What the servers report (installed apps, health) may hold a value only a newer Sigil knows, e.g. a
                // new access mode. It is read again from the server, so drop it rather than the whole list.
                guard let trimmed = Self.withoutServerCaches(data),
                      let servers = try? decoder.decode([Server].self, from: trimmed) else { throw error }
                return (servers, nil)
            }
        } catch {
            let aside = paths.storeFile.deletingLastPathComponent()
                .appendingPathComponent("servers.json.corrupt-\(ConfigManager.stamp())")
            try? fm.moveItem(at: paths.storeFile, to: aside)
            return ([], "Sunucu listesi okunamadı; bozuk dosya \(aside.lastPathComponent) olarak ayrıldı.")
        }
    }

    static let serverCacheKeys = ["apps", "health"]

    static func withoutServerCaches(_ data: Data) -> Data? {
        guard var list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        for i in list.indices { for key in serverCacheKeys { list[i][key] = nil } }
        return try? JSONSerialization.data(withJSONObject: list)
    }

    public func save(_ servers: [Server]) throws {
        try paths.ensureDirectories()
        let data = try encoder.encode(servers)
        try data.write(to: paths.storeFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.storeFile.path)
    }
}
