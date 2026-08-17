import Foundation
import Testing
@testable import Jumbini

@Suite struct TidyPlannerTests {
    private struct StubOpenFiles: TidyOpenFileDetecting {
        let paths: Set<String>

        init(paths: [String]) {
            self.paths = Set(paths)
        }

        func openPaths(under root: URL) -> Set<String> {
            paths
        }
    }

    private let imageRule = TidyRule(
        name: "Images", match: .all,
        conditions: [.extensions(["png"])], destination: "Images"
    )

    @Test func planningIsReadOnly() throws {
        let root = try TemporaryDirectory.make()
        try writeFixture("x", to: root.url.appendingPathComponent("photo.png"))
        let before = try directoryNames(at: root.url)

        let plan = try planner().plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.movable.count == 1)
        #expect(try directoryNames(at: root.url) == before)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Images").path))
    }

    @Test func onlyImmediateChildrenAreEnumerated() throws {
        let root = try TemporaryDirectory.make()
        let folder = root.url.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try writeFixture("nested", to: folder.appendingPathComponent("nested.png"))
        try writeFixture("direct", to: root.url.appendingPathComponent("direct.png"))

        let plan = try planner().plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.movable.map(\.source.lastPathComponent) == ["direct.png"])
        #expect(plan.skipped.contains { $0.source.lastPathComponent == "Folder" && $0.reason == .ordinaryDirectory })
        #expect(!plan.movable.contains { $0.source.lastPathComponent == "nested.png" })
        #expect(!plan.skipped.contains { $0.source.lastPathComponent == "nested.png" })
    }

    @Test func packageIsInspectedAtomicallyWithoutDescending() throws {
        let root = try TemporaryDirectory.make()
        let package = root.url.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try writeFixture("nested", to: package.appendingPathComponent("nested.png"))

        let plan = try planner().plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.movable.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.source.lastPathComponent == "Example.app")
        #expect(plan.skipped.first?.reason == .unmatched)
    }

    @Test func symbolicLinksAreSkipped() throws {
        let root = try TemporaryDirectory.make()
        let target = root.url.appendingPathComponent("target.png")
        let link = root.url.appendingPathComponent("link.png")
        try writeFixture("x", to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let plan = try planner().plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.skipped.contains { $0.source.lastPathComponent == "link.png" && $0.reason == .symbolicLink })
        #expect(!plan.movable.contains { $0.source.lastPathComponent == "link.png" })
    }

    @Test func aliasFilesAreSkipped() throws {
        let root = try TemporaryDirectory.make()
        let target = root.url.appendingPathComponent("target.png")
        let alias = root.url.appendingPathComponent("target alias")
        try writeFixture("x", to: target)
        let bookmark = try target.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)

        let plan = try planner().plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.skipped.contains { $0.source.lastPathComponent == "target alias" && $0.reason == .alias })
        #expect(!plan.movable.contains { $0.source.lastPathComponent == "target alias" })
    }

    @Test func recentlyModifiedFilesAreSkipped() throws {
        let root = try TemporaryDirectory.make()
        let source = root.url.appendingPathComponent("photo.png")
        try writeFixture("x", to: source)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: source.path)

        let plan = try planner().plan(root: root.url, rules: [imageRule], recencyMinutes: 5, now: now)

        #expect(plan.movable.isEmpty)
        #expect(plan.skipped.first?.reason == .recent)
    }

    @Test func unmatchedFilesAreSkipped() throws {
        let root = try TemporaryDirectory.make()
        try writeFixture("x", to: root.url.appendingPathComponent("notes.txt"))

        let plan = try planner().plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.movable.isEmpty)
        #expect(plan.skipped.first?.reason == .unmatched)
    }

    @Test func pathsOpenByAnotherProcessAreSkipped() throws {
        let root = try TemporaryDirectory.make()
        let source = root.url.appendingPathComponent("photo.png")
        try writeFixture("x", to: source)

        let plan = try planner(openPaths: [source.path]).plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.movable.isEmpty)
        #expect(plan.skipped.first?.reason == .openByAnotherProcess)
    }

    @Test func packageIsOpenWhenAContainedPathIsOpen() throws {
        let root = try TemporaryDirectory.make()
        let package = root.url.appendingPathComponent("Example.app", isDirectory: true)
        let nested = package.appendingPathComponent("Contents/config.json")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try writeFixture("x", to: nested)

        let plan = try planner(openPaths: [nested.path]).plan(
            root: root.url, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.source.lastPathComponent == "Example.app")
        #expect(plan.skipped.first?.reason == .openByAnotherProcess)
    }

    @Test func unsafeDestinationInvalidatesWholePlan() throws {
        let root = try TemporaryDirectory.make()
        try Data("x".utf8).write(to: root.url.appendingPathComponent("photo.png"))
        let rule = TidyRule(
            name: "Escape", match: .all,
            conditions: [.extensions(["png"])], destination: "../Outside"
        )

        #expect(throws: TidyPlanError.unsafeDestination("../Outside")) {
            try TidyPlanner(openFiles: StubOpenFiles(paths: [])).plan(
                root: root.url, rules: [rule], recencyMinutes: 1,
                now: Date(timeIntervalSinceNow: 3_600)
            )
        }
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Outside").path) == false)
    }

    @Test func absoluteDestinationInvalidatesWholePlan() throws {
        let root = try TemporaryDirectory.make()
        try writeFixture("x", to: root.url.appendingPathComponent("photo.png"))
        let rule = TidyRule(
            name: "Escape", match: .all,
            conditions: [.extensions(["png"])], destination: "/tmp/Outside"
        )

        #expect(throws: TidyPlanError.unsafeDestination("/tmp/Outside")) {
            try planner().plan(
                root: root.url, rules: [rule], recencyMinutes: 1,
                now: Date(timeIntervalSinceNow: 3_600)
            )
        }
    }

    @Test func destinationSymlinkOutsideRootInvalidatesWholePlan() throws {
        let root = try TemporaryDirectory.make()
        let outside = try TemporaryDirectory.make()
        try writeFixture("x", to: root.url.appendingPathComponent("photo.png"))
        try FileManager.default.createSymbolicLink(
            at: root.url.appendingPathComponent("Images"),
            withDestinationURL: outside.url
        )

        #expect(throws: TidyPlanError.unsafeDestination("Images")) {
            try planner().plan(
                root: root.url, rules: [imageRule], recencyMinutes: 1,
                now: Date(timeIntervalSinceNow: 3_600)
            )
        }
    }

    @Test func rootSymlinkIsResolvedBeforePlanning() throws {
        let root = try TemporaryDirectory.make()
        let links = try TemporaryDirectory.make()
        let link = links.url.appendingPathComponent("Chosen")
        try writeFixture("x", to: root.url.appendingPathComponent("photo.png"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.url)

        let plan = try planner().plan(
            root: link, rules: [imageRule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )

        #expect(plan.root == root.url.standardizedFileURL.resolvingSymlinksInPath())
        #expect(plan.movable.first?.source.deletingLastPathComponent() == plan.root)
        #expect(plan.movable.first?.destination == plan.root.appendingPathComponent("Images/photo.png"))
    }

    @Test func collisionSuffixPrecedesExtension() throws {
        let plan = try fixturePlan(sourceName: "photo.png", existing: ["Images/photo.png"], destination: "Images")
        #expect(plan.movable.first?.destination.lastPathComponent == "photo 2.png")
    }

    @Test func collisionSuffixAdvancesPastExistingSuffixes() throws {
        let plan = try fixturePlan(
            sourceName: "photo.png",
            existing: ["Images/photo.png", "Images/photo 2.png"],
            destination: "Images"
        )
        #expect(plan.movable.first?.destination.lastPathComponent == "photo 3.png")
    }

    private func planner(openPaths: [String] = []) -> TidyPlanner {
        TidyPlanner(openFiles: StubOpenFiles(paths: openPaths))
    }

    private func fixturePlan(
        sourceName: String,
        existing: [String],
        destination: String
    ) throws -> TidyPlan {
        let root = try TemporaryDirectory.make()
        try writeFixture("source", to: root.url.appendingPathComponent(sourceName))
        for path in existing {
            let url = root.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try writeFixture("existing", to: url)
        }
        let rule = TidyRule(
            name: "Fixture", match: .all,
            conditions: [.extensions([sourceName.pathExtension])], destination: destination
        )
        return try planner().plan(
            root: root.url, rules: [rule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )
    }

    private func directoryNames(at url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
