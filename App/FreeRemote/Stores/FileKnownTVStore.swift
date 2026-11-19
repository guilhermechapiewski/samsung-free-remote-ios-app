import Foundation
import os
import SamsungTVKit

/// Persists the `KnownTVRegistry` as JSON. A missing or unreadable file yields an empty registry.
struct FileKnownTVStore: Sendable {
    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "known-tvs.json")
    }

    private static let logger = Logger(subsystem: "FreeRemote", category: "FileKnownTVStore")

    let url: URL

    init(url: URL = FileKnownTVStore.defaultURL) {
        self.url = url
    }

    func load() -> KnownTVRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return KnownTVRegistry()
        } catch {
            Self.logger.error("Could not read known TVs: \(error.localizedDescription, privacy: .public)")
            return KnownTVRegistry()
        }
        do {
            return try JSONDecoder().decode(KnownTVRegistry.self, from: data)
        } catch {
            Self.logger.error("Known TVs file is corrupt; starting empty")
            return KnownTVRegistry()
        }
    }

    /// Writes atomically, creating the containing directory if needed.
    func save(_ r: KnownTVRegistry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(r).write(to: url, options: .atomic)
    }
}
