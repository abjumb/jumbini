import Foundation
import Testing
@testable import Jumbini

@Suite struct TidyStoreTests {
    @Test func defaultDirectoryIsTheJumbiniApplicationSupportFolder() throws {
        let applicationSupport = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first)

        let directory = TidyStore.defaultDirectory(fileManager: .default)
        #expect(directory.deletingLastPathComponent().standardizedFileURL == applicationSupport.standardizedFileURL)
        #expect(directory.lastPathComponent == "Jumbini")
    }

    @Test func rulesRoundTripAsReadableJSON() throws {
        let support = try TemporaryDirectory.make()
        let store = TidyStore(directory: support.url)
        try store.saveRules(.defaults)

        let data = try Data(contentsOf: support.url.appendingPathComponent("tidy-rules.json"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(try store.loadRules() == .defaults)
    }

    @Test func malformedRulesArePreserved() throws {
        let support = try TemporaryDirectory.make()
        let rulesURL = support.url.appendingPathComponent("tidy-rules.json")
        let malformed = "{ not valid JSON"
        try writeFixture(malformed, to: rulesURL)

        #expect(throws: DecodingError.self) {
            try TidyStore(directory: support.url).loadRules()
        }
        #expect(try String(contentsOf: rulesURL, encoding: .utf8) == malformed)
    }

    @Test func missingPreferencesUseDefaultsWithoutWriting() throws {
        let support = try TemporaryDirectory.make()
        let preferencesURL = support.url.appendingPathComponent("tidy-preferences.json")
        let store = TidyStore(directory: support.url)

        #expect(try store.loadPreferences() == TidyPreferences())
        #expect(!FileManager.default.fileExists(atPath: preferencesURL.path))
    }

    @Test func decodedPreferenceIntervalsAreAtLeastOneMinute() throws {
        let support = try TemporaryDirectory.make()
        try writeFixture("""
        {"needsPreview":false,"recencyMinutes":0,"idleEnabled":true,"idleMinutes":-3,"completedManualPass":true}
        """, to: support.url.appendingPathComponent("tidy-preferences.json"))

        let preferences = try TidyStore(directory: support.url).loadPreferences()
        #expect(preferences == TidyPreferences(
            needsPreview: false,
            recencyMinutes: 1,
            idleEnabled: true,
            idleMinutes: 1,
            completedManualPass: true
        ))
    }

    @Test func savedFolderResolvesToTheChosenDirectory() throws {
        let support = try TemporaryDirectory.make()
        let chosen = try TemporaryDirectory.make()
        let store = TidyStore(directory: support.url)
        try store.saveFolder(chosen.url)

        let grant = try #require(try store.resolveFolder())
        #expect(grant.url.standardizedFileURL == chosen.url.standardizedFileURL)
    }

    @Test func forgettingFolderRemovesOnlyTheBookmark() throws {
        let support = try TemporaryDirectory.make()
        let chosen = try TemporaryDirectory.make()
        let store = TidyStore(directory: support.url)
        try store.saveRules(.defaults)
        try store.saveFolder(chosen.url)
        try store.forgetFolder()
        #expect(try store.resolveFolder() == nil)
        #expect(try store.loadRules() == .defaults)
    }
}
