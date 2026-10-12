import CoreGraphics
import Foundation

/// Disabled displays vanish from NSScreen, so remember them on disk.
/// Shared by the menu bar app and the CLI.
enum DisabledStore {
    struct Entry: Codable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
    }

    static let url: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenOff/disabled.json")

    /// State file of the earlier `dispctl` script ({"name": id}); imported once, then removed.
    static let legacyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dispctl-off.json")

    static func load() -> [Entry] {
        var entries: [Entry] = []
        if let data = try? Data(contentsOf: url) {
            entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: legacyURL),
           let legacy = try? JSONDecoder().decode([String: CGDirectDisplayID].self, from: data) {
            for (name, id) in legacy where !entries.contains(where: { $0.id == id }) {
                entries.append(Entry(id: id, name: name, isBuiltin: false))
            }
            save(entries)
            try? FileManager.default.removeItem(at: legacyURL)
        }
        return entries
    }

    static func save(_ entries: [Entry]) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
