import Darwin
import Foundation

enum TidyTrigger: String, Codable, Equatable {
    case manual, idle
}

enum TidyPassStatus: String, Codable, Equatable {
    case running, completed, halted, failed, undone
}

struct TidyCompletedMove: Codable, Equatable {
    let source: URL
    let destination: URL
    let fileID: TidyFileID
    let ruleID: UUID
    let ruleName: String
}

struct TidyPassRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let trigger: TidyTrigger
    let startedAt: Date
    var status: TidyPassStatus
    var intendedMove: TidyCompletedMove?
    var moves: [TidyCompletedMove]
    var undoAvailable: Bool

    static func started(trigger: TidyTrigger, at date: Date) -> TidyPassRecord {
        TidyPassRecord(
            id: UUID(),
            trigger: trigger,
            startedAt: date,
            status: .running,
            intendedMove: nil,
            moves: [],
            undoAvailable: false
        )
    }
}

enum TidyLedgerError: Error, Equatable {
    case noLatestPass
    case passMismatch(expected: UUID, actual: UUID)
    case intentAlreadyPending
    case completionWithoutMatchingIntent
    case unableToCreateJournal
}

enum TidyRecoveryError: Error, Equatable {
    case bothPathsExist(source: URL, destination: URL)
    case neitherPathExists(source: URL, destination: URL)
    case identityMismatch(path: URL, expected: TidyFileID, actual: TidyFileID)
    case probeFailed(path: URL, errorCode: Int32)
}

enum TidyFileIdentityProbeResult: Equatable {
    case absent
    case present(TidyFileID)
    case failed(Int32)
}

protocol TidyFileIdentityProbing {
    func probe(at url: URL) -> TidyFileIdentityProbeResult
}

struct SystemTidyFileIdentityProbe: TidyFileIdentityProbing {
    func probe(at url: URL) -> TidyFileIdentityProbeResult {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            let errorCode = errno
            if errorCode == ENOENT || errorCode == ENOTDIR {
                return .absent
            }
            return .failed(errorCode)
        }
        return .present(TidyFileID(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        ))
    }
}

final class TidyLedger {
    private let directory: URL
    private let fileManager: FileManager
    private let identityProbe: TidyFileIdentityProbing
    private let now: () -> Date

    private var auditURL: URL {
        directory.appendingPathComponent("tidy.log")
    }

    private var journalURL: URL {
        directory.appendingPathComponent("tidy-last-pass.json")
    }

    private var temporaryJournalURL: URL {
        directory.appendingPathComponent("tidy-last-pass.json.tmp")
    }

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        identityProbe: TidyFileIdentityProbing = SystemTidyFileIdentityProbe(),
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory ?? TidyStore.defaultDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.identityProbe = identityProbe
        self.now = now
    }

    func begin(_ pass: TidyPassRecord) throws {
        try save(pass)
        try append(
            passID: pass.id,
            action: "BEGIN",
            result: pass.status.rawValue,
            at: pass.startedAt
        )
    }

    func recordIntent(_ move: TidyCompletedMove, in passID: UUID) throws {
        var pass = try requirePass(passID)
        guard pass.intendedMove == nil else {
            throw TidyLedgerError.intentAlreadyPending
        }
        pass.intendedMove = move
        try save(pass)
    }

    func recordCompletion(_ move: TidyCompletedMove, in passID: UUID) throws {
        var pass = try requirePass(passID)
        guard pass.intendedMove == move else {
            throw TidyLedgerError.completionWithoutMatchingIntent
        }

        // Keep the intent recoverable until the completed-move audit is durable.
        try append(
            passID: passID,
            action: "MOVE",
            source: move.source,
            destination: move.destination,
            ruleID: move.ruleID,
            ruleName: move.ruleName,
            result: "completed"
        )
        pass.intendedMove = nil
        pass.moves.append(move)
        try save(pass)
    }

    func recordSkip(_ item: TidySkippedItem, in passID: UUID) throws {
        _ = try requirePass(passID)
        try append(
            passID: passID,
            action: "SKIP",
            source: item.source,
            result: item.reason.rawValue
        )
    }

    func recordFailure(
        _ message: String,
        for move: TidyCompletedMove,
        in passID: UUID
    ) throws {
        _ = try requirePass(passID)
        try append(
            passID: passID,
            action: "FAILURE",
            source: move.source,
            destination: move.destination,
            ruleID: move.ruleID,
            ruleName: move.ruleName,
            result: message
        )
    }

    func recordCap(passID: UUID) throws {
        _ = try requirePass(passID)
        try append(
            passID: passID,
            action: "CAP",
            result: "maximum_moves=\(TidySafety.maximumMoves)"
        )
    }

    func recordUndo(_ move: TidyCompletedMove, in passID: UUID) throws {
        _ = try requirePass(passID)
        try append(
            passID: passID,
            action: "UNDO",
            source: move.destination,
            destination: move.source,
            ruleID: move.ruleID,
            ruleName: move.ruleName,
            result: "completed"
        )
    }

    func finish(_ passID: UUID, status: TidyPassStatus) throws {
        var pass = try requirePass(passID)
        pass.status = status
        switch status {
        case .completed, .halted, .failed:
            pass.undoAvailable = !pass.moves.isEmpty
        case .running, .undone:
            pass.undoAvailable = false
        }
        try save(pass)
        try append(passID: passID, action: "FINISH", result: status.rawValue)
    }

    func loadLatestPass() throws -> TidyPassRecord? {
        guard fileManager.fileExists(atPath: journalURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            TidyPassRecord.self,
            from: Data(contentsOf: journalURL)
        )
    }

    func consumeUndo() throws {
        guard var pass = try loadLatestPass() else {
            throw TidyLedgerError.noLatestPass
        }
        pass.undoAvailable = false
        try save(pass)
    }

    @discardableResult
    func reconcile() throws -> TidyPassRecord? {
        guard var pass = try loadLatestPass() else {
            return nil
        }
        guard let move = pass.intendedMove else {
            return pass
        }

        let sourceID = try recoveryFileID(at: move.source)
        let destinationID = try recoveryFileID(at: move.destination)
        // Audit first so a failed append leaves the intent available to retry.
        switch (sourceID, destinationID) {
        case (.some(let actualID), nil):
            guard actualID == move.fileID else {
                throw TidyRecoveryError.identityMismatch(
                    path: move.source,
                    expected: move.fileID,
                    actual: actualID
                )
            }
            try append(
                passID: pass.id,
                action: "RECOVERED",
                source: move.source,
                destination: move.destination,
                ruleID: move.ruleID,
                ruleName: move.ruleName,
                result: "not_moved"
            )
            pass.intendedMove = nil
        case (nil, .some(let actualID)):
            guard actualID == move.fileID else {
                throw TidyRecoveryError.identityMismatch(
                    path: move.destination,
                    expected: move.fileID,
                    actual: actualID
                )
            }
            try append(
                passID: pass.id,
                action: "RECOVERED",
                source: move.source,
                destination: move.destination,
                ruleID: move.ruleID,
                ruleName: move.ruleName,
                result: "moved"
            )
            pass.intendedMove = nil
            pass.moves.append(move)
        case (.some, .some):
            throw TidyRecoveryError.bothPathsExist(
                source: move.source,
                destination: move.destination
            )
        case (nil, nil):
            throw TidyRecoveryError.neitherPathExists(
                source: move.source,
                destination: move.destination
            )
        }

        try save(pass)
        return pass
    }

    private func requirePass(_ passID: UUID) throws -> TidyPassRecord {
        guard let pass = try loadLatestPass() else {
            throw TidyLedgerError.noLatestPass
        }
        guard pass.id == passID else {
            throw TidyLedgerError.passMismatch(expected: pass.id, actual: passID)
        }
        return pass
    }

    private func save(_ pass: TidyPassRecord) throws {
        try createDirectoryIfNeeded()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pass)

        if fileManager.fileExists(atPath: temporaryJournalURL.path) {
            try fileManager.removeItem(at: temporaryJournalURL)
        }
        guard fileManager.createFile(atPath: temporaryJournalURL.path, contents: nil) else {
            throw TidyLedgerError.unableToCreateJournal
        }

        let handle = try FileHandle(forWritingTo: temporaryJournalURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // POSIX rename atomically replaces a destination on the same filesystem.
        guard Darwin.rename(temporaryJournalURL.path, journalURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func append(
        passID: UUID,
        action: String,
        source: URL? = nil,
        destination: URL? = nil,
        ruleID: UUID? = nil,
        ruleName: String? = nil,
        result: String,
        at date: Date? = nil
    ) throws {
        try createDirectoryIfNeeded()
        if !fileManager.fileExists(atPath: auditURL.path) {
            guard fileManager.createFile(atPath: auditURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let fields = [
            "timestamp=\(Self.timestamp(date ?? now()))",
            "pass=\(passID.uuidString)",
            "action=\(action)",
            "source=\(Self.auditValue(source?.path ?? "-"))",
            "destination=\(Self.auditValue(destination?.path ?? "-"))",
            "rule_id=\(ruleID?.uuidString ?? "-")",
            "rule_name=\(Self.auditValue(ruleName ?? "-"))",
            "result=\(Self.auditValue(result))",
        ]
        let data = Data((fields.joined(separator: "\t") + "\n").utf8)
        let handle = try FileHandle(forWritingTo: auditURL)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func recoveryFileID(at url: URL) throws -> TidyFileID? {
        switch identityProbe.probe(at: url) {
        case .absent:
            return nil
        case .present(let fileID):
            return fileID
        case .failed(let errorCode):
            throw TidyRecoveryError.probeFailed(
                path: url,
                errorCode: errorCode
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func auditValue(_ value: String) -> String {
        var encoded = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar) {
                for byte in String(scalar).utf8 {
                    encoded += String(format: "%%%02X", byte)
                }
            } else {
                encoded.unicodeScalars.append(scalar)
            }
        }
        return encoded
    }
}
