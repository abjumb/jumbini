import Foundation
import Testing
@testable import Jumbini

@Suite struct TidyLedgerTests {
    @Test func completedMoveIsHumanReadableAndRecoverable() throws {
        let support = try TemporaryDirectory.make()
        let completionDate = Date(timeIntervalSince1970: 2)
        let ledger = TidyLedger(directory: support.url, now: { completionDate })
        let pass = TidyPassRecord.started(
            trigger: .manual,
            at: Date(timeIntervalSince1970: 1)
        )
        let move = TidyCompletedMove.fixture(
            source: "/Desktop/a.png",
            destination: "/Desktop/Images/a.png"
        )

        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)
        try ledger.recordCompletion(move, in: pass.id)
        try ledger.finish(pass.id, status: .completed)

        let line = try #require(try auditLines(in: support.url).first {
            $0.contains("\taction=MOVE\t")
        })
        #expect(line == [
            "timestamp=1970-01-01T00:00:02.000Z",
            "pass=\(pass.id.uuidString)",
            "action=MOVE",
            "source=/Desktop/a.png",
            "destination=/Desktop/Images/a.png",
            "rule_id=\(move.ruleID.uuidString)",
            "rule_name=Images",
            "result=completed",
        ].joined(separator: "\t"))
        #expect(try ledger.loadLatestPass()?.moves == [move])
    }

    @Test func skippedItemHasExactHumanReadableFields() throws {
        let support = try TemporaryDirectory.make()
        let timestamp = Date(timeIntervalSince1970: 2)
        let ledger = TidyLedger(directory: support.url, now: { timestamp })
        let pass = TidyPassRecord.started(trigger: .idle, at: timestamp)
        let item = TidySkippedItem(
            id: UUID(),
            source: URL(fileURLWithPath: "/Desktop/report.pdf"),
            reason: .recent
        )

        try ledger.begin(pass)
        try ledger.recordSkip(item, in: pass.id)

        let line = try #require(try auditLines(in: support.url).last)
        #expect(line == [
            "timestamp=1970-01-01T00:00:02.000Z",
            "pass=\(pass.id.uuidString)",
            "action=SKIP",
            "source=/Desktop/report.pdf",
            "destination=-",
            "rule_id=-",
            "rule_name=-",
            "result=recent",
        ].joined(separator: "\t"))
    }

    @Test func failureHasExactHumanReadableFields() throws {
        let support = try TemporaryDirectory.make()
        let timestamp = Date(timeIntervalSince1970: 3)
        let ledger = TidyLedger(directory: support.url, now: { timestamp })
        let pass = TidyPassRecord.started(trigger: .manual, at: timestamp)
        let move = TidyCompletedMove.fixture(
            source: "/Desktop/report.pdf",
            destination: "/Desktop/Documents/report.pdf"
        )

        try ledger.begin(pass)
        try ledger.recordFailure("permission denied", for: move, in: pass.id)

        let line = try #require(try auditLines(in: support.url).last)
        #expect(line == [
            "timestamp=1970-01-01T00:00:03.000Z",
            "pass=\(pass.id.uuidString)",
            "action=FAILURE",
            "source=/Desktop/report.pdf",
            "destination=/Desktop/Documents/report.pdf",
            "rule_id=\(move.ruleID.uuidString)",
            "rule_name=Images",
            "result=permission denied",
        ].joined(separator: "\t"))
    }

    @Test func capNoticeHasExactHumanReadableFields() throws {
        let support = try TemporaryDirectory.make()
        let timestamp = Date(timeIntervalSince1970: 4)
        let ledger = TidyLedger(directory: support.url, now: { timestamp })
        let pass = TidyPassRecord.started(trigger: .idle, at: timestamp)

        try ledger.begin(pass)
        try ledger.recordCap(passID: pass.id)

        let line = try #require(try auditLines(in: support.url).last)
        #expect(line == [
            "timestamp=1970-01-01T00:00:04.000Z",
            "pass=\(pass.id.uuidString)",
            "action=CAP",
            "source=-",
            "destination=-",
            "rule_id=-",
            "rule_name=-",
            "result=maximum_moves=50",
        ].joined(separator: "\t"))
    }

    @Test func undoHasExactHumanReadableFields() throws {
        let support = try TemporaryDirectory.make()
        let timestamp = Date(timeIntervalSince1970: 5)
        let ledger = TidyLedger(directory: support.url, now: { timestamp })
        let pass = TidyPassRecord.started(trigger: .manual, at: timestamp)
        let move = TidyCompletedMove.fixture(
            source: "/Desktop/a.png",
            destination: "/Desktop/Images/a.png"
        )

        try ledger.begin(pass)
        try ledger.recordUndo(move, in: pass.id)

        let line = try #require(try auditLines(in: support.url).last)
        #expect(line == [
            "timestamp=1970-01-01T00:00:05.000Z",
            "pass=\(pass.id.uuidString)",
            "action=UNDO",
            "source=/Desktop/Images/a.png",
            "destination=/Desktop/a.png",
            "rule_id=\(move.ruleID.uuidString)",
            "rule_name=Images",
            "result=completed",
        ].joined(separator: "\t"))
    }

    @Test func consumingUndoPersistsUnavailableStateAtomically() throws {
        let support = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let pass = TidyPassRecord.started(trigger: .manual, at: .now)
        let move = TidyCompletedMove.fixture(index: 0)
        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)
        try ledger.recordCompletion(move, in: pass.id)
        try ledger.finish(pass.id, status: .completed)
        #expect(try ledger.loadLatestPass()?.undoAvailable == true)

        try ledger.consumeUndo()

        let latest = try #require(try ledger.loadLatestPass())
        let data = try Data(
            contentsOf: support.url.appendingPathComponent("tidy-last-pass.json")
        )
        #expect(latest.status == .completed)
        #expect(!latest.undoAvailable)
        #expect(try JSONDecoder().decode(TidyPassRecord.self, from: data) == latest)
        #expect(!FileManager.default.fileExists(
            atPath: support.url.appendingPathComponent("tidy-last-pass.json.tmp").path
        ))
    }

    @Test func destinationOnlyIntentIsRecoveredAsCompletedMove() throws {
        let support = try TemporaryDirectory.make()
        let items = try TemporaryDirectory.make()
        let timestamp = Date(timeIntervalSince1970: 6)
        let ledger = TidyLedger(directory: support.url, now: { timestamp })
        let pass = TidyPassRecord.started(trigger: .manual, at: timestamp)
        let source = items.url.appendingPathComponent("a.png")
        let destination = items.url.appendingPathComponent("Images/a.png")
        let move = TidyCompletedMove.fixture(
            source: source.path,
            destination: destination.path
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFixture("moved", to: destination)
        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)

        let recovered = try ledger.reconcile()

        #expect(recovered?.intendedMove == nil)
        #expect(recovered?.moves == [move])
        #expect(try ledger.loadLatestPass() == recovered)
        let line = try #require(try auditLines(in: support.url).last)
        #expect(line == [
            "timestamp=1970-01-01T00:00:06.000Z",
            "pass=\(pass.id.uuidString)",
            "action=RECOVERED",
            "source=\(source.path)",
            "destination=\(destination.path)",
            "rule_id=\(move.ruleID.uuidString)",
            "rule_name=Images",
            "result=moved",
        ].joined(separator: "\t"))
    }

    @Test func sourceOnlyIntentIsRecoveredAsNotMoved() throws {
        let support = try TemporaryDirectory.make()
        let items = try TemporaryDirectory.make()
        let timestamp = Date(timeIntervalSince1970: 7)
        let ledger = TidyLedger(directory: support.url, now: { timestamp })
        let pass = TidyPassRecord.started(trigger: .idle, at: timestamp)
        let source = items.url.appendingPathComponent("a.png")
        let destination = items.url.appendingPathComponent("Images/a.png")
        let move = TidyCompletedMove.fixture(
            source: source.path,
            destination: destination.path
        )
        try writeFixture("not moved", to: source)
        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)

        let recovered = try ledger.reconcile()

        #expect(recovered?.intendedMove == nil)
        #expect(recovered?.moves.isEmpty == true)
        #expect(try ledger.loadLatestPass() == recovered)
        let line = try #require(try auditLines(in: support.url).last)
        #expect(line.hasSuffix("\taction=RECOVERED\tsource=\(source.path)" +
            "\tdestination=\(destination.path)\trule_id=\(move.ruleID.uuidString)" +
            "\trule_name=Images\tresult=not_moved"))
    }

    @Test func reconciliationRefusesToGuessWhenBothPathsExist() throws {
        let support = try TemporaryDirectory.make()
        let items = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let pass = TidyPassRecord.started(trigger: .manual, at: .now)
        let source = items.url.appendingPathComponent("a.png")
        let destination = items.url.appendingPathComponent("Images/a.png")
        let move = TidyCompletedMove.fixture(
            source: source.path,
            destination: destination.path
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFixture("source", to: source)
        try writeFixture("destination", to: destination)
        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)
        let journalBefore = try journalData(in: support.url)
        let auditBefore = try auditData(in: support.url)

        #expect(throws: TidyRecoveryError.bothPathsExist(
            source: source,
            destination: destination
        )) {
            try ledger.reconcile()
        }
        #expect(try journalData(in: support.url) == journalBefore)
        #expect(try auditData(in: support.url) == auditBefore)
        #expect(try ledger.loadLatestPass()?.intendedMove == move)
    }

    @Test func reconciliationRefusesToGuessWhenNeitherPathExists() throws {
        let support = try TemporaryDirectory.make()
        let items = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let pass = TidyPassRecord.started(trigger: .manual, at: .now)
        let source = items.url.appendingPathComponent("missing.png")
        let destination = items.url.appendingPathComponent("Images/missing.png")
        let move = TidyCompletedMove.fixture(
            source: source.path,
            destination: destination.path
        )
        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)
        let journalBefore = try journalData(in: support.url)
        let auditBefore = try auditData(in: support.url)

        #expect(throws: TidyRecoveryError.neitherPathExists(
            source: source,
            destination: destination
        )) {
            try ledger.reconcile()
        }
        #expect(try journalData(in: support.url) == journalBefore)
        #expect(try auditData(in: support.url) == auditBefore)
        #expect(try ledger.loadLatestPass()?.intendedMove == move)
    }

    @Test func completionRequiresTheMatchingPersistedIntent() throws {
        let support = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let pass = TidyPassRecord.started(trigger: .manual, at: .now)
        let move = TidyCompletedMove.fixture(index: 0)
        try ledger.begin(pass)
        let journalBefore = try journalData(in: support.url)

        #expect(throws: TidyLedgerError.completionWithoutMatchingIntent) {
            try ledger.recordCompletion(move, in: pass.id)
        }
        #expect(try journalData(in: support.url) == journalBefore)
        #expect(try auditLines(in: support.url).allSatisfy {
            !$0.contains("\taction=MOVE\t")
        })
    }

    @Test func intentIsDurableBeforeCompletionAndClearedAfterward() throws {
        let support = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let pass = TidyPassRecord.started(trigger: .manual, at: .now)
        let move = TidyCompletedMove.fixture(index: 1)
        try ledger.begin(pass)

        try ledger.recordIntent(move, in: pass.id)

        let intended = try JSONDecoder().decode(
            TidyPassRecord.self,
            from: journalData(in: support.url)
        )
        #expect(intended.intendedMove == move)
        #expect(intended.moves.isEmpty)

        try ledger.recordCompletion(move, in: pass.id)

        let completed = try #require(try ledger.loadLatestPass())
        #expect(completed.intendedMove == nil)
        #expect(completed.moves == [move])
    }

    @Test func beginningNewPassReplacesUndoEligibilityButNotAuditHistory() throws {
        let support = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let first = TidyPassRecord.started(trigger: .manual, at: .now)
        let move = TidyCompletedMove.fixture(index: 0)
        try ledger.begin(first)
        try ledger.recordIntent(move, in: first.id)
        try ledger.recordCompletion(move, in: first.id)
        try ledger.finish(first.id, status: .completed)
        #expect(try ledger.loadLatestPass()?.undoAvailable == true)

        let second = TidyPassRecord.started(trigger: .idle, at: .now)
        try ledger.begin(second)

        #expect(try ledger.loadLatestPass() == second)
        let lines = try auditLines(in: support.url)
        #expect(lines.contains { $0.contains("pass=\(first.id.uuidString)\taction=MOVE") })
        #expect(lines.contains { $0.contains("pass=\(second.id.uuidString)\taction=BEGIN") })
    }

    @Test func controlCharactersCannotForgeAuditLines() throws {
        let support = try TemporaryDirectory.make()
        let ledger = TidyLedger(directory: support.url)
        let pass = TidyPassRecord.started(trigger: .manual, at: .now)
        let fixture = TidyCompletedMove.fixture(index: 0)
        let move = TidyCompletedMove(
            source: URL(fileURLWithPath: "/Desktop/line\nbreak\tname.png"),
            destination: URL(fileURLWithPath: "/Desktop/Images/line\rbreak.png"),
            fileID: fixture.fileID,
            ruleID: fixture.ruleID,
            ruleName: "Images\nforged"
        )

        try ledger.begin(pass)
        try ledger.recordIntent(move, in: pass.id)
        try ledger.recordCompletion(move, in: pass.id)

        let lines = try auditLines(in: support.url)
        #expect(lines.count == 2)
        let moveLine = try #require(lines.last)
        #expect(moveLine.contains("source=/Desktop/line%0Abreak%09name.png"))
        #expect(moveLine.contains("destination=/Desktop/Images/line%0Dbreak.png"))
        #expect(moveLine.contains("rule_name=Images%0Aforged"))
    }

    private func auditLines(in directory: URL) throws -> [String] {
        try String(
            contentsOf: directory.appendingPathComponent("tidy.log"),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
    }

    private func journalData(in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("tidy-last-pass.json"))
    }

    private func auditData(in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("tidy.log"))
    }
}
