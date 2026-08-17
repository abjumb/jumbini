import Darwin
import Foundation

protocol TidyFileOperating {
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func itemExists(at url: URL) -> Bool
}

struct SystemTidyFileOperator: TidyFileOperating {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func moveItem(at source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(
                    sourcePath,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func itemExists(at url: URL) -> Bool {
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 {
            return true
        }
        return errno != ENOENT && errno != ENOTDIR
    }
}

final class TidyExecutor {
    private static let metadataKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .isAliasFileKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
    ]

    private let ledger: TidyLedger
    private let openFiles: TidyOpenFileDetecting
    private let fileOperator: TidyFileOperating
    private let fileManager: FileManager
    private let identityProbe: TidyFileIdentityProbing

    init(
        ledger: TidyLedger,
        openFiles: TidyOpenFileDetecting = SystemTidyOpenFileDetector(),
        fileOperator: TidyFileOperating = SystemTidyFileOperator(),
        fileManager: FileManager = .default,
        identityProbe: TidyFileIdentityProbing = SystemTidyFileIdentityProbe()
    ) {
        self.ledger = ledger
        self.openFiles = openFiles
        self.fileOperator = fileOperator
        self.fileManager = fileManager
        self.identityProbe = identityProbe
    }

    func execute(
        plan: TidyPlan,
        selectedIDs: Set<UUID>,
        trigger: TidyTrigger,
        now: Date,
        shouldHalt: () -> Bool,
        didMove: (TidyCompletedMove) -> Void
    ) throws -> TidyPassResult {
        let root = try resolvedRoot(plan.root)
        let selectedMoves = plan.movable.filter { selectedIDs.contains($0.id) }

        // Validate the complete selected batch before the journal or filesystem
        // receives any writes.
        for move in selectedMoves {
            try validatePaths(for: move, under: root)
        }

        let pass = TidyPassRecord.started(trigger: trigger, at: now)
        try ledger.begin(pass)

        var completedMoves: [TidyCompletedMove] = []
        var skipped = plan.skipped
        var failures: [String] = []
        var didHitCap = false
        var wasHalted = false

        do {
            for item in plan.skipped {
                try ledger.recordSkip(item, in: pass.id)
            }

            // A single fresh snapshot is shared by all immediate per-item checks.
            let openPaths = Set(openFiles.openPaths(under: root).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })

            for plannedMove in selectedMoves {
                if shouldHalt() {
                    wasHalted = true
                    break
                }
                if completedMoves.count >= TidySafety.maximumMoves {
                    didHitCap = true
                    try ledger.recordCap(passID: pass.id)
                    break
                }

                let validation: CandidateValidation
                do {
                    try validatePaths(for: plannedMove, under: root)
                    validation = validateSource(plannedMove, openPaths: openPaths)
                } catch {
                    let message = failureMessage(error)
                    let failedMove = completedMove(from: plannedMove)
                    try ledger.recordFailure(message, for: failedMove, in: pass.id)
                    failures.append(message)
                    try ledger.finish(pass.id, status: .failed)
                    return TidyPassResult(
                        passID: pass.id,
                        moves: completedMoves,
                        skipped: skipped,
                        failures: failures,
                        didHitCap: false,
                        wasHalted: false
                    )
                }

                switch validation {
                case .skip(let reason):
                    let item = TidySkippedItem(
                        id: plannedMove.id,
                        source: plannedMove.source,
                        reason: reason
                    )
                    skipped.append(item)
                    try ledger.recordSkip(item, in: pass.id)

                case .move(let validatedFileID):
                    var destination = availableDestination(for: plannedMove)
                    let destinationDirectory = destination.deletingLastPathComponent()
                    var completed = TidyCompletedMove(
                        source: plannedMove.source,
                        destination: destination,
                        fileID: validatedFileID,
                        ruleID: plannedMove.ruleID,
                        ruleName: plannedMove.ruleName
                    )

                    do {
                        try fileOperator.createDirectory(at: destinationDirectory)
                        try validateDestinationDirectory(
                            destinationDirectory,
                            under: root,
                            offendingURL: destination
                        )
                        // Recheck after folder creation as that call is an injected
                        // boundary and another process may have claimed the name.
                        if fileOperator.itemExists(at: destination) {
                            destination = availableDestination(for: plannedMove)
                            completed = TidyCompletedMove(
                                source: plannedMove.source,
                                destination: destination,
                                fileID: validatedFileID,
                                ruleID: plannedMove.ruleID,
                                ruleName: plannedMove.ruleName
                            )
                        }

                        while true {
                            try validateSameDevice(
                                source: plannedMove.source,
                                expectedID: validatedFileID,
                                destinationDirectory: destinationDirectory
                            )
                            try ledger.recordIntent(completed, in: pass.id)
                            do {
                                try fileOperator.moveItem(
                                    at: completed.source,
                                    to: completed.destination
                                )
                                break
                            } catch let error as POSIXError where error.code == .EEXIST {
                                do {
                                    try ledger.clearIntent(passID: pass.id)
                                } catch {
                                    throw IntentClearFailure(underlying: error)
                                }
                                destination = availableDestination(for: plannedMove)
                                completed = TidyCompletedMove(
                                    source: plannedMove.source,
                                    destination: destination,
                                    fileID: validatedFileID,
                                    ruleID: plannedMove.ruleID,
                                    ruleName: plannedMove.ruleName
                                )
                            }
                        }
                        try ledger.recordCompletion(completed, in: pass.id)
                        completedMoves.append(completed)
                        didMove(completed)
                    } catch let clearFailure as IntentClearFailure {
                        throw clearFailure.underlying
                    } catch {
                        let originalError = error
                        // Whether the failure occurred before, during, or after the
                        // move, reconciliation derives the durable completed prefix
                        // from exact source/destination identity.
                        let reconciled = try ledger.reconcile()
                        completedMoves = reconciled?.moves ?? completedMoves
                        let message = failureMessage(originalError)
                        try ledger.recordFailure(message, for: completed, in: pass.id)
                        failures.append(message)
                        try ledger.finish(pass.id, status: .failed)
                        return TidyPassResult(
                            passID: pass.id,
                            moves: completedMoves,
                            skipped: skipped,
                            failures: failures,
                            didHitCap: false,
                            wasHalted: false
                        )
                    }
                }
            }

            try ledger.finish(pass.id, status: wasHalted ? .halted : .completed)
            return TidyPassResult(
                passID: pass.id,
                moves: completedMoves,
                skipped: skipped,
                failures: failures,
                didHitCap: didHitCap,
                wasHalted: wasHalted
            )
        } catch {
            // A ledger failure after a completed prefix must not discard that
            // prefix's undo eligibility when the journal remains writable.
            try? ledger.finish(pass.id, status: .failed)
            throw error
        }
    }

    func undoLatest(root: URL, now: Date) throws -> TidyUndoResult {
        _ = now
        let resolved = try resolvedRoot(root)
        guard let pass = try ledger.loadLatestPass(),
              pass.undoAvailable,
              pass.intendedMove == nil,
              !pass.moves.isEmpty else {
            throw TidyUndoError.unavailable
        }

        let reversedMoves = Array(pass.moves.reversed())

        // Complete preflight before the first reverse move.
        for move in reversedMoves {
            try validateRecordedPaths(move, under: resolved)
            if fileOperator.itemExists(at: move.source) {
                throw TidyUndoError.sourceOccupied(move.source)
            }
            guard fileID(at: move.destination) == move.fileID else {
                throw TidyUndoError.destinationChanged(move.destination)
            }
        }

        var restored: [TidyCompletedMove] = []
        for move in reversedMoves {
            do {
                try fileOperator.moveItem(at: move.destination, to: move.source)
                restored.append(move)
            } catch {
                let undoMessage = failureMessage(error)
                // An adapter may report an error after the same-volume rename
                // has already completed. Include that deterministically moved
                // item in the roll-forward set instead of leaving half an undo.
                if fileID(at: move.source) == move.fileID,
                   !fileOperator.itemExists(at: move.destination) {
                    restored.append(move)
                }
                var rollbackMessage: String?
                do {
                    // restored is newest-first; reversing it gives the original
                    // pass order required for a deterministic roll-forward.
                    for restoredMove in restored.reversed() {
                        try fileOperator.moveItem(
                            at: restoredMove.source,
                            to: restoredMove.destination
                        )
                    }
                } catch {
                    rollbackMessage = failureMessage(error)
                }

                let message: String
                if let rollbackMessage {
                    message = "undo=\(undoMessage); roll_forward=\(rollbackMessage)"
                } else {
                    message = undoMessage
                }
                try ledger.recordUndoFailure(message, in: pass.id)
                throw TidyUndoError.rollbackFailed(message)
            }
        }

        do {
            try ledger.completeUndo(reversedMoves, in: pass.id)
        } catch {
            let auditMessage = failureMessage(error)
            var rollbackMessage: String?
            do {
                for move in pass.moves {
                    try fileOperator.moveItem(at: move.source, to: move.destination)
                }
            } catch {
                rollbackMessage = failureMessage(error)
            }
            let message = rollbackMessage.map {
                "audit=\(auditMessage); roll_forward=\($0)"
            } ?? auditMessage
            try? ledger.recordUndoFailure(message, in: pass.id)
            throw TidyUndoError.rollbackFailed(message)
        }

        return TidyUndoResult(restoredCount: restored.count)
    }

    private func validateSource(
        _ move: TidyPlannedMove,
        openPaths: Set<String>
    ) -> CandidateValidation {
        guard let currentID = fileID(at: move.source),
              currentID == move.sourceID else {
            return .skip(.unreadableMetadata)
        }

        let values: URLResourceValues
        do {
            values = try move.source.resourceValues(forKeys: Self.metadataKeys)
        } catch {
            return .skip(.unreadableMetadata)
        }

        if values.isSymbolicLink == true {
            return .skip(.symbolicLink)
        }
        if values.isAliasFile == true {
            return .skip(.alias)
        }
        if values.isDirectory == true && values.isPackage != true {
            return .skip(.ordinaryDirectory)
        }
        guard values.contentModificationDate == move.modifiedAt else {
            return .skip(.recent)
        }

        let sourcePath = move.source.standardizedFileURL.path
        if openPaths.contains(sourcePath)
            || (values.isPackage == true && openPaths.contains {
                $0.hasPrefix(sourcePath + "/")
            }) {
            return .skip(.openByAnotherProcess)
        }
        return .move(currentID)
    }

    private func availableDestination(for move: TidyPlannedMove) -> URL {
        if !fileOperator.itemExists(at: move.destination) {
            return move.destination
        }

        let directory = move.destination.deletingLastPathComponent()
        let sourceName = move.source.lastPathComponent
        let stem = (sourceName as NSString).deletingPathExtension
        let pathExtension = (sourceName as NSString).pathExtension
        var suffix = 2

        while true {
            let name = pathExtension.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(pathExtension)"
            let candidate = directory
                .appendingPathComponent(name)
                .standardizedFileURL
            if !fileOperator.itemExists(at: candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private func validateSameDevice(
        source: URL,
        expectedID: TidyFileID,
        destinationDirectory: URL
    ) throws {
        guard let immediateSourceID = fileID(at: source),
              immediateSourceID == expectedID else {
            throw TidyExecutionError.identityUnavailable(source)
        }
        guard let destinationDirectoryID = fileID(at: destinationDirectory) else {
            throw TidyExecutionError.identityUnavailable(destinationDirectory)
        }
        guard immediateSourceID.device == destinationDirectoryID.device else {
            throw TidyExecutionError.deviceMismatch(
                source: source,
                destinationParent: destinationDirectory
            )
        }
    }

    private func resolvedRoot(_ root: URL) throws -> URL {
        guard root.isFileURL else {
            throw TidyExecutionError.unsafeRoot(root)
        }
        let resolved = root.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: resolved.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw TidyExecutionError.unsafeRoot(root)
        }
        return resolved
    }

    private func validatePaths(
        for move: TidyPlannedMove,
        under root: URL
    ) throws {
        let source = move.source.standardizedFileURL
        guard source.isFileURL,
              source.deletingLastPathComponent().path == root.path,
              contains(source.resolvingSymlinksInPath(), in: root) else {
            throw TidyExecutionError.pathOutsideRoot(move.source)
        }
        try validateDestinationDirectory(
            move.destination.deletingLastPathComponent(),
            under: root,
            offendingURL: move.destination
        )
    }

    private func validateRecordedPaths(
        _ move: TidyCompletedMove,
        under root: URL
    ) throws {
        let source = move.source.standardizedFileURL
        guard source.isFileURL,
              source.deletingLastPathComponent().path == root.path,
              contains(source, in: root) else {
            throw TidyExecutionError.pathOutsideRoot(move.source)
        }
        try validateDestinationDirectory(
            move.destination.deletingLastPathComponent(),
            under: root,
            offendingURL: move.destination
        )
    }

    private func validateDestinationDirectory(
        _ directory: URL,
        under root: URL,
        offendingURL: URL
    ) throws {
        let standardized = directory.standardizedFileURL
        guard standardized.isFileURL,
              standardized.deletingLastPathComponent().path == root.path,
              contains(standardized.resolvingSymlinksInPath(), in: root) else {
            throw TidyExecutionError.pathOutsideRoot(offendingURL)
        }
    }

    private func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    private func fileID(at url: URL) -> TidyFileID? {
        guard case .present(let fileID) = identityProbe.probe(at: url) else {
            return nil
        }
        return fileID
    }

    private func completedMove(from move: TidyPlannedMove) -> TidyCompletedMove {
        TidyCompletedMove(
            source: move.source,
            destination: move.destination,
            fileID: move.sourceID,
            ruleID: move.ruleID,
            ruleName: move.ruleName
        )
    }

    private func failureMessage(_ error: Error) -> String {
        String(describing: error)
    }
}

private enum CandidateValidation {
    case skip(TidySkipReason)
    case move(TidyFileID)
}

private struct IntentClearFailure: Error {
    let underlying: Error
}
