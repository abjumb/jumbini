import Testing
import Foundation
@testable import Jumbini

// The shot scripts are the input to a recording session that a human sits
// through. A typo in a signal name would parse as "no beat here" and show up
// as a clip where the dog does nothing — after the session. So they are
// validated as part of the build instead.

private let shotsDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // JumbiniTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("Tools/demo/shots")

private func shotURLs() throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: shotsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func everyShotInTheDirectoryParses() throws {
    let urls = try shotURLs()
    #expect(!urls.isEmpty)
    for url in urls {
        let data = try Data(contentsOf: url)
        // Throws on an unknown signal, command, trick, toy or kind.
        _ = try DemoScript(json: data)
    }
}

@Test func theNinePlannedShotsAreAllPresent() throws {
    let names = try Set(shotURLs().map { $0.deletingPathExtension().lastPathComponent })
    let planned: Set<String> = [
        "climb", "thermal", "build-party", "quiet",
        "fetch", "toys", "tricks", "pounce", "charm",
    ]
    #expect(names == planned)
}

@Test func everyBeatLandsInsideItsClipDuration() throws {
    for url in try shotURLs() {
        let script = try DemoScript(json: Data(contentsOf: url))
        for beat in script.beats {
            #expect(beat.at >= 0, "\(script.name): beat at \(beat.at) is negative")
            #expect(
                beat.at <= script.duration,
                "\(script.name): beat at \(beat.at) is past the \(script.duration)s end"
            )
        }
    }
}

@Test func scriptNamesMatchTheirFilenames() throws {
    for url in try shotURLs() {
        let script = try DemoScript(json: Data(contentsOf: url))
        #expect(script.name == url.deletingPathExtension().lastPathComponent)
    }
}
