import Foundation
import Testing
@testable import Jumbini

// Turning a chosen URL into a coat folder.
//
// Every individual step here is already covered by CoatValidatorTests — the zip
// safety rules, findCoatFolder, the validator itself. What was never covered,
// because it sat behind `NSOpenPanel().runModal()` on line six of doImport, is
// the part that only exists in the pipeline: the ORDER of the steps, and the
// promise that an archive with a link out of the staging directory has its
// extraction discarded rather than left in temp.
//
// So these assert existence and absence rather than matching strings. The
// wording belongs to the findings, which are tested where they are produced.

private final class Sandbox {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jumbini-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func makeDirectory(_ name: String) throws -> URL {
        let dir = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// A one-pixel PNG is enough: nothing here validates image content, it only has
/// to be a file named `idle_south.png` so `findCoatFolder` recognises a coat.
private func writeSprite(named name: String, in folder: URL) throws {
    let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
    try png.write(to: folder.appendingPathComponent(name))
}

/// Runs a shell command in `directory`, returning false if the tool is absent
/// or fails — the caller turns that into a skip, since `zip` is an environment
/// dependency and not a product behaviour.
@discardableResult
private func shell(_ arguments: [String], in directory: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", arguments.joined(separator: " ")]
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func extractedDirectory(of outcome: CoatImport.Outcome) -> URL {
    outcome.stagingRoot.appendingPathComponent("extracted", isDirectory: true)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

// MARK: - The ordering

@Test func anArchiveThatCannotBeListedIsNeverExtracted() throws {
    // The listing is checked before anything is written to disk, so an archive
    // that fails at that step must leave no extraction behind at all.
    let sandbox = Sandbox()
    let notAnArchive = sandbox.url.appendingPathComponent("broken.zip")
    try Data("this is not a zip".utf8).write(to: notAnArchive)

    let outcome = try CoatImport.stage(notAnArchive)

    guard case .refused(let error, let messages) = outcome.result else {
        Issue.record("a file that is not an archive must be refused")
        return
    }
    #expect(error == .zipListingFailed)
    #expect(!messages.isEmpty, "a refusal has to say something")
    #expect(!exists(extractedDirectory(of: outcome)), "nothing may be extracted before the listing passes")
}

@Test func anArchiveWithALinkOutOfStagingHasItsExtractionDiscarded() throws {
    // The promise that existed only as a comment. Symlinks are invisible in a
    // listing, so this is the first point the archive can be checked — and a
    // link into the user's home must not be left sitting in temp.
    let sandbox = Sandbox()
    let source = try sandbox.makeDirectory("evil")
    try writeSprite(named: CoatValidator.requiredSprite, in: source)

    let built = shell(["ln", "-s", "/etc/passwd", "escape.png"], in: source)
        && shell(["zip", "-r", "--symlinks", "../evil.zip", "."], in: source)
    try #require(built, "zip with --symlinks is unavailable in this environment")
    let archive = sandbox.url.appendingPathComponent("evil.zip")

    let outcome = try CoatImport.stage(archive)

    guard case .refused(let error, let messages) = outcome.result else {
        Issue.record("an archive linking outside staging must be refused")
        return
    }
    #expect(error == .unsafeArchive)
    #expect(!messages.isEmpty)
    #expect(
        !exists(extractedDirectory(of: outcome)),
        "the extraction must be discarded, not left in temp with a link into the user's home"
    )
}

@Test func aCleanArchiveYieldsItsCoatFolder() throws {
    let sandbox = Sandbox()
    let source = try sandbox.makeDirectory("nova")
    try writeSprite(named: CoatValidator.requiredSprite, in: source)

    let built = shell(["zip", "-r", "../nova.zip", "."], in: source)
    try #require(built, "zip is unavailable in this environment")
    let archive = sandbox.url.appendingPathComponent("nova.zip")

    let outcome = try CoatImport.stage(archive)

    guard case .imported(let coatFolder, _) = outcome.result else {
        Issue.record("a clean archive must import; got \(outcome.result)")
        return
    }
    #expect(exists(coatFolder.appendingPathComponent(CoatValidator.requiredSprite)))
    #expect(coatFolder.path.hasPrefix(outcome.stagingRoot.path), "the coat must land inside staging")
}

// MARK: - Cleanup is always possible

@Test func theStagingRootComesBackOnEveryPath() throws {
    // The leak this replaces happened because a refusal returned nothing the
    // caller could hang a cleanup off. Both paths must give one back.
    let sandbox = Sandbox()
    let broken = sandbox.url.appendingPathComponent("broken.zip")
    try Data("not a zip".utf8).write(to: broken)
    let folder = try sandbox.makeDirectory("plain")
    try writeSprite(named: CoatValidator.requiredSprite, in: folder)

    let refused = try CoatImport.stage(broken)
    let imported = try CoatImport.stage(folder)

    for outcome in [refused, imported] {
        #expect(exists(outcome.stagingRoot), "the staging root must exist so it can be deleted")
    }
    #expect(refused.stagingRoot != imported.stagingRoot, "each import stages separately")
}

@Test func stagingThatCannotBeCreatedThrowsRatherThanRefusing() {
    // Temp being unwritable is not something the archive did, so it is the one
    // genuinely exceptional case here.
    final class BrokenTemp: FileManager, @unchecked Sendable {
        override var temporaryDirectory: URL { URL(fileURLWithPath: "/dev/null/nowhere") }
    }
    let sandbox = Sandbox()
    let folder = try? sandbox.makeDirectory("plain")

    #expect(throws: ValidationError.stagingFailed) {
        _ = try CoatImport.stage(folder ?? sandbox.url, fileManager: BrokenTemp())
    }
}

// MARK: - The folder path is deliberately different

@Test func aChosenFolderIsCopiedWithoutTheArchiveSafetyPasses() throws {
    // Deliberate asymmetry, pinned so it reads as decided rather than forgotten.
    // A zip is a third-party artifact; a folder is one the user just picked out
    // of a file dialog, so they already have access to everything in it and
    // copying their own symlink into temp grants nobody anything.
    let sandbox = Sandbox()
    let source = try sandbox.makeDirectory("mine")
    try writeSprite(named: CoatValidator.requiredSprite, in: source)
    let linked = shell(["ln", "-s", "/etc/passwd", "escape.png"], in: source)
    try #require(linked, "ln is unavailable in this environment")

    let outcome = try CoatImport.stage(source)

    guard case .imported(let coatFolder, let findings) = outcome.result else {
        Issue.record("a chosen folder is trusted and must import; got \(outcome.result)")
        return
    }
    #expect(findings.isEmpty, "the folder path runs no archive checks, so it reports none")
    #expect(exists(coatFolder.appendingPathComponent(CoatValidator.requiredSprite)))
}
