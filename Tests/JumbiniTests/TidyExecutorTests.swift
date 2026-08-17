import Darwin
import Foundation
import Testing
@testable import Jumbini

@Suite struct TidyExecutorTests {
    @Test func onlySelectedRowsMove() throws {
        let fixture = try ExecutorFixture(fileCount: 3)

        let result = try fixture.executor.execute(
            plan: fixture.plan,
            selectedIDs: [fixture.plan.movable[1].id],
            trigger: .manual,
            now: fixture.now,
            shouldHalt: { false },
            didMove: { _ in }
        )

        #expect(result.moves.map(\.source) == [fixture.sourceURLs[1]])
        #expect(fixture.sourceExists == [true, false, true])
        #expect(fixture.destinationChildren.map(\.lastPathComponent) == ["file-0002.png"])
    }

    @Test func destinationFolderIsCreatedOnlyDuringExecution() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationDirectory.path))

        _ = try fixture.runAll()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: fixture.destinationDirectory.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test func changedSourceIdentityIsSkippedImmediatelyBeforeMove() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        let source = fixture.sourceURLs[0]
        let original = fixture.root.appendingPathComponent("original.png")
        try FileManager.default.moveItem(at: source, to: original)
        try writeFixture("replacement", to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.plan.movable[0].modifiedAt],
            ofItemAtPath: source.path
        )

        let result = try fixture.runAll()

        #expect(result.moves.isEmpty)
        #expect(result.skipped.map(\.reason) == [.unreadableMetadata])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(fixture.destinationChildren.isEmpty)
    }

    @Test func newlyModifiedSourceIsSkippedAsRecent() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now],
            ofItemAtPath: fixture.sourceURLs[0].path
        )

        let result = try fixture.runAll()

        #expect(result.moves.isEmpty)
        #expect(result.skipped.map(\.reason) == [.recent])
        #expect(fixture.sourceExists == [true])
    }

    @Test func newlyOpenSourceIsSkippedImmediatelyBeforeMove() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        fixture.openFiles.paths = [fixture.sourceURLs[0].path]

        let result = try fixture.runAll()

        #expect(result.moves.isEmpty)
        #expect(result.skipped.map(\.reason) == [.openByAnotherProcess])
        #expect(fixture.sourceExists == [true])
    }

    @Test func lateCollisionNeverOverwritesAndUsesNextSuffix() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        try FileManager.default.createDirectory(
            at: fixture.destinationDirectory,
            withIntermediateDirectories: true
        )
        let collision = fixture.destinationDirectory.appendingPathComponent("file-0001.png")
        try writeFixture("existing", to: collision)

        let result = try fixture.runAll()

        #expect(result.moves.first?.destination.lastPathComponent == "file-0001 2.png")
        #expect(try String(contentsOf: collision, encoding: .utf8) == "existing")
        #expect(Set(fixture.destinationChildren.map(\.lastPathComponent)) == [
            "file-0001.png", "file-0001 2.png",
        ])
    }

    @Test func collisionAtAtomicRenameBoundaryRetriesWithNewIntent() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        fixture.fileOperator.collidingMoveNumbers = [1]

        let result = try fixture.runAll()

        let move = try #require(result.moves.first)
        let originalDestination = fixture.destinationDirectory
            .appendingPathComponent("file-0001.png")
        #expect(move.destination.lastPathComponent == "file-0001 2.png")
        #expect(try String(contentsOf: originalDestination, encoding: .utf8) == "racer")
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceURLs[0].path))
        #expect(try fixture.ledger.loadLatestPass()?.intendedMove == nil)
        #expect(try fixture.ledger.loadLatestPass()?.moves == [move])
        #expect(fixture.fileOperator.moveAttempts.map(\.destination) == [
            originalDestination,
            move.destination,
        ])
    }

    @Test func intentClearFailureStopsWithSourceUntouched() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        let fileManager = TemporaryJournalCreateFailingFileManager(
            temporaryJournalURL: fixture.support.url
                .appendingPathComponent("tidy-last-pass.json.tmp")
        )
        let ledger = TidyLedger(
            directory: fixture.support.url,
            fileManager: fileManager,
            now: { fixture.now }
        )
        let executor = TidyExecutor(
            ledger: ledger,
            openFiles: fixture.openFiles,
            fileOperator: fixture.fileOperator
        )
        fixture.fileOperator.collidingMoveNumbers = [1]
        fixture.fileOperator.onCollision = {
            fileManager.failNextTemporaryJournalCreate = true
        }

        #expect(throws: TidyLedgerError.unableToCreateJournal) {
            try executor.execute(
                plan: fixture.plan,
                selectedIDs: Set(fixture.plan.movable.map(\.id)),
                trigger: .manual,
                now: fixture.now,
                shouldHalt: { false },
                didMove: { _ in }
            )
        }

        let originalDestination = fixture.destinationDirectory
            .appendingPathComponent("file-0001.png")
        let retryDestination = fixture.destinationDirectory
            .appendingPathComponent("file-0001 2.png")
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURLs[0].path))
        #expect(try String(contentsOf: originalDestination, encoding: .utf8) == "racer")
        #expect(!FileManager.default.fileExists(atPath: retryDestination.path))
        #expect(fixture.fileOperator.moveAttempts.count == 1)
        #expect(try ledger.loadLatestPass()?.intendedMove?.destination == originalDestination)
    }

    @Test func systemOperatorNeverReplacesExistingDestination() throws {
        let directory = try TemporaryDirectory.make()
        let source = directory.url.appendingPathComponent("source.txt")
        let destination = directory.url.appendingPathComponent("destination.txt")
        try writeFixture("source", to: source)
        try writeFixture("destination", to: destination)

        #expect(throws: POSIXError(.EEXIST)) {
            try SystemTidyFileOperator().moveItem(at: source, to: destination)
        }

        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "destination")
    }

    @Test func systemOperatorRenamePreservesFileIdentity() throws {
        let directory = try TemporaryDirectory.make()
        let source = directory.url.appendingPathComponent("source.txt")
        let destination = directory.url.appendingPathComponent("destination.txt")
        try writeFixture("source", to: source)
        let sourceID = try fileID(at: source)

        try SystemTidyFileOperator().moveItem(at: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try fileID(at: destination) == sourceID)
    }

    @Test func deviceMismatchFailsBeforeIntentOrMove() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        let executor = TidyExecutor(
            ledger: fixture.ledger,
            openFiles: fixture.openFiles,
            fileOperator: fixture.fileOperator,
            identityProbe: DeviceMismatchIdentityProbe(
                destinationDirectory: fixture.destinationDirectory
            )
        )

        let result = try executor.execute(
            plan: fixture.plan,
            selectedIDs: Set(fixture.plan.movable.map(\.id)),
            trigger: .manual,
            now: fixture.now,
            shouldHalt: { false },
            didMove: { _ in }
        )

        #expect(result.moves.isEmpty)
        #expect(result.failures.count == 1)
        #expect(fixture.fileOperator.moveAttempts.isEmpty)
        #expect(fixture.sourceExists == [true])
        #expect(try fixture.ledger.loadLatestPass()?.intendedMove == nil)
        #expect(try fixture.ledger.loadLatestPass()?.status == .failed)
    }

    @Test func hardCapMovesExactlyFifty() throws {
        let fixture = try ExecutorFixture(fileCount: 4_000)

        let result = try fixture.runAll()

        #expect(result.moves.count == 50)
        #expect(result.didHitCap)
        #expect(fixture.destinationChildren.count == 50)
    }

    @Test func haltIsObservedOnlyAtAFileBoundary() throws {
        let fixture = try ExecutorFixture(fileCount: 4)
        var shouldStop = false

        let result = try fixture.executor.execute(
            plan: fixture.plan,
            selectedIDs: Set(fixture.plan.movable.map(\.id)),
            trigger: .idle,
            now: fixture.now,
            shouldHalt: { shouldStop },
            didMove: { _ in
                if fixture.fileOperator.successfulMoveCount == 2 {
                    shouldStop = true
                }
            }
        )

        #expect(result.moves.count == 2)
        #expect(result.wasHalted)
        #expect(!result.didHitCap)
        #expect(try fixture.ledger.loadLatestPass()?.status == .halted)
        #expect(try fixture.ledger.loadLatestPass()?.undoAvailable == true)
    }

    @Test func unexpectedMoveErrorReturnsUndoablePartialPass() throws {
        let fixture = try ExecutorFixture(fileCount: 4)
        fixture.fileOperator.failingMoveNumbers = [3]

        let result = try fixture.runAll()

        #expect(result.moves.count == 2)
        #expect(result.failures.count == 1)
        #expect(try fixture.ledger.loadLatestPass()?.status == .failed)
        #expect(try fixture.ledger.loadLatestPass()?.moves == result.moves)
        #expect(try fixture.ledger.loadLatestPass()?.undoAvailable == true)
        #expect(fixture.destinationChildren.count == 2)

        fixture.fileOperator.reset()
        let undo = try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)
        #expect(undo.restoredCount == 2)
    }

    @Test func journalSetupFailureMovesNothingAndCreatesNoDestination() throws {
        let fixture = try ExecutorFixture(fileCount: 2)
        let blockedJournalDirectory = fixture.root.appendingPathComponent("not-a-directory")
        try writeFixture("blocker", to: blockedJournalDirectory)
        let operatorSpy = RecordingTidyFileOperator()
        let executor = TidyExecutor(
            ledger: TidyLedger(directory: blockedJournalDirectory),
            openFiles: fixture.openFiles,
            fileOperator: operatorSpy
        )

        do {
            _ = try executor.execute(
                plan: fixture.plan,
                selectedIDs: Set(fixture.plan.movable.map(\.id)),
                trigger: .manual,
                now: fixture.now,
                shouldHalt: { false },
                didMove: { _ in }
            )
            Issue.record("Expected journal setup to fail")
        } catch {}

        #expect(operatorSpy.moveAttempts.isEmpty)
        #expect(fixture.sourceExists == [true, true])
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationDirectory.path))
    }

    @Test func undoMovesEveryItemInExactReverseOrder() throws {
        let fixture = try ExecutorFixture(fileCount: 3)
        let pass = try fixture.runAll()
        fixture.fileOperator.reset()

        let result = try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)

        #expect(result.restoredCount == 3)
        #expect(fixture.fileOperator.moveAttempts.map(\.source) == pass.moves.reversed().map(\.destination))
        #expect(fixture.fileOperator.moveAttempts.map(\.destination) == pass.moves.reversed().map(\.source))
        #expect(fixture.sourceExists == [true, true, true])
        #expect(fixture.destinationChildren.isEmpty)
    }

    @Test func occupiedSourceAbortsUndoBeforeAnyMove() throws {
        let fixture = try ExecutorFixture(fileCount: 2)
        _ = try fixture.runAll()
        try writeFixture("new occupant", to: fixture.sourceURLs[0])
        fixture.fileOperator.reset()

        #expect(throws: TidyUndoError.sourceOccupied(fixture.sourceURLs[0])) {
            try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)
        }
        #expect(fixture.fileOperator.moveAttempts.isEmpty)
        #expect(fixture.destinationChildren.count == 2)
    }

    @Test func changedDestinationIdentityAbortsUndoBeforeAnyMove() throws {
        let fixture = try ExecutorFixture(fileCount: 2)
        let pass = try fixture.runAll()
        let destination = pass.moves[1].destination
        let retainedOriginal = fixture.root.appendingPathComponent("retained-original.png")
        try FileManager.default.moveItem(at: destination, to: retainedOriginal)
        try writeFixture("replacement", to: destination)
        fixture.fileOperator.reset()

        #expect(throws: TidyUndoError.destinationChanged(destination)) {
            try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)
        }
        #expect(fixture.fileOperator.moveAttempts.isEmpty)
        #expect(fixture.destinationChildren.count == 2)
    }

    @Test func successfulUndoConsumesAvailability() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        _ = try fixture.runAll()

        _ = try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)

        #expect(try fixture.ledger.loadLatestPass()?.status == .undone)
        #expect(try fixture.ledger.loadLatestPass()?.undoAvailable == false)
        #expect(throws: TidyUndoError.unavailable) {
            try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)
        }
    }

    @Test func finalUndoAuditFailureRollsForwardWithoutConsumingEligibility() throws {
        let fixture = try ExecutorFixture(fileCount: 2)
        let failingFileManager = FinalUndoAuditFailingFileManager(
            auditURL: fixture.support.url.appendingPathComponent("tidy.log")
        )
        let ledger = TidyLedger(
            directory: fixture.support.url,
            fileManager: failingFileManager,
            now: { fixture.now }
        )
        let executor = TidyExecutor(
            ledger: ledger,
            openFiles: fixture.openFiles,
            fileOperator: fixture.fileOperator
        )
        _ = try executor.execute(
            plan: fixture.plan,
            selectedIDs: Set(fixture.plan.movable.map(\.id)),
            trigger: .manual,
            now: fixture.now,
            shouldHalt: { false },
            didMove: { _ in }
        )
        fixture.fileOperator.reset()
        failingFileManager.failAuditCheck(number: 3)

        #expect(throws: TidyUndoError.self) {
            try executor.undoLatest(root: fixture.root, now: fixture.now)
        }

        #expect(fixture.sourceExists == [false, false])
        #expect(fixture.destinationChildren.count == 2)
        #expect(try ledger.loadLatestPass()?.status == .completed)
        #expect(try ledger.loadLatestPass()?.undoAvailable == true)
    }

    @Test func failedUndoRollsForwardAndKeepsUndoAvailable() throws {
        let fixture = try ExecutorFixture(fileCount: 3)
        _ = try fixture.runAll()
        fixture.fileOperator.reset()
        fixture.fileOperator.failingMoveNumbers = [2]

        #expect(throws: TidyUndoError.self) {
            try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)
        }

        #expect(fixture.sourceExists == [false, false, false])
        #expect(fixture.destinationChildren.count == 3)
        #expect(try fixture.ledger.loadLatestPass()?.undoAvailable == true)
        #expect(fixture.auditLines.contains { $0.contains("\taction=UNDO_FAILED\t") })
        #expect(!fixture.auditLines.contains { $0.contains("\taction=UNDO\t") })
    }

    @Test func undoErrorAfterPhysicalMoveStillRollsEveryItemForward() throws {
        let fixture = try ExecutorFixture(fileCount: 3)
        _ = try fixture.runAll()
        fixture.fileOperator.reset()
        fixture.fileOperator.moveThenFailNumbers = [2]

        #expect(throws: TidyUndoError.self) {
            try fixture.executor.undoLatest(root: fixture.root, now: fixture.now)
        }

        #expect(fixture.sourceExists == [false, false, false])
        #expect(fixture.destinationChildren.count == 3)
        #expect(try fixture.ledger.loadLatestPass()?.undoAvailable == true)
        #expect(fixture.auditLines.contains { $0.contains("\taction=UNDO_FAILED\t") })
    }

    @Test func unsafeSelectedPathFailsBeforeJournalOrFilesystemWrites() throws {
        let fixture = try ExecutorFixture(fileCount: 1)
        let outside = try TemporaryDirectory.make()
        let planned = fixture.plan.movable[0]
        let unsafeMove = TidyPlannedMove(
            id: planned.id,
            source: planned.source,
            destination: outside.url.appendingPathComponent("escaped.png"),
            sourceID: planned.sourceID,
            modifiedAt: planned.modifiedAt,
            ruleID: planned.ruleID,
            ruleName: planned.ruleName
        )
        let unsafePlan = TidyPlan(root: fixture.root, movable: [unsafeMove], skipped: [])

        #expect(throws: TidyExecutionError.pathOutsideRoot(unsafeMove.destination)) {
            try fixture.executor.execute(
                plan: unsafePlan,
                selectedIDs: [unsafeMove.id],
                trigger: .manual,
                now: fixture.now,
                shouldHalt: { false },
                didMove: { _ in }
            )
        }
        #expect(fixture.fileOperator.moveAttempts.isEmpty)
        #expect(fixture.sourceExists == [true])
        #expect(!FileManager.default.fileExists(
            atPath: fixture.support.url.appendingPathComponent("tidy-last-pass.json").path
        ))
    }
}

private final class ExecutorFixture {
    let items: TemporaryDirectory
    let support: TemporaryDirectory
    let root: URL
    let destinationDirectory: URL
    let now: Date
    let sourceURLs: [URL]
    let plan: TidyPlan
    let ledger: TidyLedger
    let openFiles: MutableOpenFiles
    let fileOperator: RecordingTidyFileOperator
    let executor: TidyExecutor

    init(fileCount: Int) throws {
        let fixtureNow = Date(timeIntervalSince1970: 2_000_000_000)
        now = fixtureNow
        items = try TemporaryDirectory.make()
        support = try TemporaryDirectory.make()
        root = items.url.standardizedFileURL.resolvingSymlinksInPath()
        destinationDirectory = root.appendingPathComponent("Images", isDirectory: true)
        let modifiedAt = fixtureNow.addingTimeInterval(-3_600)
        let ruleID = UUID(uuidString: "5C8E2694-5D63-437F-AFB5-EF3DF5DA70CB")!

        var sources: [URL] = []
        var moves: [TidyPlannedMove] = []
        sources.reserveCapacity(fileCount)
        moves.reserveCapacity(fileCount)
        for index in 0..<fileCount {
            let name = String(format: "file-%04d.png", index + 1)
            let source = root.appendingPathComponent(name)
            _ = FileManager.default.createFile(
                atPath: source.path,
                contents: Data("fixture-\(index)".utf8)
            )
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: source.path
            )
            let actualModifiedAt = try source.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate!
            moves.append(TidyPlannedMove(
                id: UUID(),
                source: source,
                destination: destinationDirectory.appendingPathComponent(name),
                sourceID: try fileID(at: source),
                modifiedAt: actualModifiedAt,
                ruleID: ruleID,
                ruleName: "Images"
            ))
            sources.append(source)
        }
        sourceURLs = sources
        plan = TidyPlan(root: root, movable: moves, skipped: [])
        ledger = TidyLedger(directory: support.url, now: { fixtureNow })
        openFiles = MutableOpenFiles()
        fileOperator = RecordingTidyFileOperator()
        executor = TidyExecutor(
            ledger: ledger,
            openFiles: openFiles,
            fileOperator: fileOperator
        )
    }

    var sourceExists: [Bool] {
        sourceURLs.map { FileManager.default.fileExists(atPath: $0.path) }
    }

    var destinationChildren: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
    }

    var auditLines: [String] {
        let url = support.url.appendingPathComponent("tidy.log")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func runAll() throws -> TidyPassResult {
        try executor.execute(
            plan: plan,
            selectedIDs: Set(plan.movable.map(\.id)),
            trigger: .manual,
            now: now,
            shouldHalt: { false },
            didMove: { _ in }
        )
    }
}

private final class MutableOpenFiles: TidyOpenFileDetecting {
    var paths: Set<String> = []

    func openPaths(under root: URL) -> Set<String> {
        paths
    }
}

private final class RecordingTidyFileOperator: TidyFileOperating {
    struct InjectedMoveError: Error {}

    private(set) var moveAttempts: [(source: URL, destination: URL)] = []
    var failingMoveNumbers: Set<Int> = []
    var moveThenFailNumbers: Set<Int> = []
    var collidingMoveNumbers: Set<Int> = []
    var onCollision: (() -> Void)?

    var successfulMoveCount: Int {
        moveAttempts.count - moveAttempts.indices.filter {
            failingMoveNumbers.contains($0 + 1)
        }.count
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func moveItem(at source: URL, to destination: URL) throws {
        moveAttempts.append((source, destination))
        if failingMoveNumbers.contains(moveAttempts.count) {
            throw InjectedMoveError()
        }
        if collidingMoveNumbers.contains(moveAttempts.count) {
            try writeFixture("racer", to: destination)
            onCollision?()
            throw POSIXError(.EEXIST)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        if moveThenFailNumbers.contains(moveAttempts.count) {
            throw InjectedMoveError()
        }
    }

    func itemExists(at url: URL) -> Bool {
        var information = stat()
        return Darwin.lstat(url.path, &information) == 0
    }

    func reset() {
        moveAttempts = []
        failingMoveNumbers = []
        moveThenFailNumbers = []
        collidingMoveNumbers = []
        onCollision = nil
    }
}

private struct DeviceMismatchIdentityProbe: TidyFileIdentityProbing {
    let destinationDirectory: URL

    func probe(at url: URL) -> TidyFileIdentityProbeResult {
        let result = SystemTidyFileIdentityProbe().probe(at: url)
        guard url.standardizedFileURL == destinationDirectory.standardizedFileURL,
              case .present(let fileID) = result else {
            return result
        }
        return .present(TidyFileID(
            device: fileID.device ^ 1,
            inode: fileID.inode
        ))
    }
}

private final class FinalUndoAuditFailingFileManager: FileManager {
    private let auditPath: String
    private var currentAuditCheck = 0
    private var failingAuditCheck: Int?

    init(auditURL: URL) {
        auditPath = auditURL.path
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func failAuditCheck(number: Int) {
        currentAuditCheck = 0
        failingAuditCheck = number
    }

    override func fileExists(atPath path: String) -> Bool {
        if path == auditPath, failingAuditCheck != nil {
            currentAuditCheck += 1
            if currentAuditCheck == failingAuditCheck {
                try? super.removeItem(atPath: auditPath)
                try? super.createDirectory(
                    atPath: auditPath,
                    withIntermediateDirectories: false
                )
                failingAuditCheck = nil
                return true
            }
        }
        return super.fileExists(atPath: path)
    }
}

private final class TemporaryJournalCreateFailingFileManager: FileManager {
    private let temporaryJournalPath: String
    var failNextTemporaryJournalCreate = false

    init(temporaryJournalURL: URL) {
        temporaryJournalPath = temporaryJournalURL.path
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func createFile(
        atPath path: String,
        contents data: Data?,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        if path == temporaryJournalPath, failNextTemporaryJournalCreate {
            failNextTemporaryJournalCreate = false
            return false
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private func fileID(at url: URL) throws -> TidyFileID {
    var information = stat()
    guard Darwin.lstat(url.path, &information) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return TidyFileID(
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino)
    )
}
