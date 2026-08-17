import Foundation

struct TidyPreferences: Codable, Equatable {
    var needsPreview = true
    var recencyMinutes = 5
    var idleEnabled = false
    var idleMinutes = 10
    var completedManualPass = false
}

struct TidyFolderGrant: Equatable {
    let url: URL
    let isStale: Bool
}

final class TidyStore {
    private let directory: URL
    private let fileManager: FileManager

    private var rulesURL: URL {
        directory.appendingPathComponent("tidy-rules.json")
    }

    private var preferencesURL: URL {
        directory.appendingPathComponent("tidy-preferences.json")
    }

    private var folderBookmarkURL: URL {
        directory.appendingPathComponent("tidy-folder.bookmark")
    }

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    static func defaultDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Jumbini", isDirectory: true)
    }

    func loadRules() throws -> TidyRuleSet {
        guard fileManager.fileExists(atPath: rulesURL.path) else {
            return .defaults
        }
        return try JSONDecoder().decode(TidyRuleSet.self, from: Data(contentsOf: rulesURL))
    }

    func saveRules(_ rules: TidyRuleSet) throws {
        try saveJSON(rules, to: rulesURL)
    }

    func loadPreferences() throws -> TidyPreferences {
        guard fileManager.fileExists(atPath: preferencesURL.path) else {
            return TidyPreferences()
        }
        var preferences = try JSONDecoder().decode(
            TidyPreferences.self,
            from: Data(contentsOf: preferencesURL)
        )
        preferences.recencyMinutes = max(preferences.recencyMinutes, 1)
        preferences.idleMinutes = max(preferences.idleMinutes, 1)
        return preferences
    }

    func savePreferences(_ preferences: TidyPreferences) throws {
        try saveJSON(preferences, to: preferencesURL)
    }

    func saveFolder(_ url: URL) throws {
        try createDirectoryIfNeeded()
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try bookmark.write(to: folderBookmarkURL, options: .atomic)
    }

    func resolveFolder() throws -> TidyFolderGrant? {
        guard fileManager.fileExists(atPath: folderBookmarkURL.path) else {
            return nil
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: Data(contentsOf: folderBookmarkURL),
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return TidyFolderGrant(url: url, isStale: isStale)
    }

    func forgetFolder() throws {
        guard fileManager.fileExists(atPath: folderBookmarkURL.path) else {
            return
        }
        try fileManager.removeItem(at: folderBookmarkURL)
    }

    private func saveJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        try createDirectoryIfNeeded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
