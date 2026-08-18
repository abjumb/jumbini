import Foundation

/// Turning a URL the user picked into a coat folder that is safe to look at.
///
/// This was six steps inside `CoatWorkshopPanel.doImport`, whose first act is
/// `NSOpenPanel().runModal()` — so everything after it was unreachable from a
/// test. Every individual step it calls is well covered by `CoatValidatorTests`;
/// what was not covered is the part that only exists here: the ORDER, and one
/// promise that lived solely in a comment — that an archive containing a symlink
/// out of the staging directory has its extraction discarded rather than left
/// sitting in temp with a link into the user's home.
///
/// The seam is "a URL the user already chose". The picker stays with the panel,
/// because choosing is genuinely an AppKit act; everything after it is files and
/// rules.
enum CoatImport {
    struct Outcome {
        /// Always present, including on a refusal, so the caller's cleanup is
        /// unconditional. The leak this replaces happened because there was
        /// nothing to hang a `defer` on.
        ///
        /// Only ever a directory this type created. Deliberately not the same
        /// thing as the panel's `stagingURL`, which also holds an *installed*
        /// coat's root when the workshop is opened on one — deleting that would
        /// destroy an installed coat.
        let stagingRoot: URL
        let result: Result

        enum Result: Equatable {
            /// `findings` are about the archive itself, which
            /// `CoatValidator.validate` never sees because it is handed a
            /// folder. The caller shows them alongside the report.
            case imported(coatFolder: URL, findings: [ValidationFinding])
            /// An ordinary answer, not an error: most refusals are "this is not
            /// a coat" rather than "something went wrong". `messages` is what to
            /// put in front of the user.
            case refused(ValidationError, messages: [String])
        }
    }

    /// Stage `url` — a zip archive or a folder — and report what came of it.
    ///
    /// Throws only when the staging directory cannot be created, which is the
    /// one genuinely exceptional case here: temp being unwritable is not
    /// something the archive did.
    static func stage(_ url: URL, fileManager: FileManager = .default) throws -> Outcome {
        let stagingRoot = try makeStagingDirectory(fileManager: fileManager)
        let result: Outcome.Result
        if url.pathExtension.lowercased() == "zip" {
            result = stageZip(url, into: stagingRoot, fileManager: fileManager)
        } else {
            result = stageFolder(url, into: stagingRoot, fileManager: fileManager)
        }
        return Outcome(stagingRoot: stagingRoot, result: result)
    }

    // MARK: - Zip

    private static func stageZip(
        _ url: URL, into stagingRoot: URL, fileManager: FileManager
    ) -> Outcome.Result {
        let entries: [String]
        do {
            entries = try CoatValidator.listZipContents(at: url)
        } catch {
            return .refused(.zipListingFailed, messages: [Self.listingFailedMessage])
        }

        // Checked BEFORE extracting, so an archive naming an absolute path or a
        // parent traversal never gets written to disk at all.
        let listingErrors = errors(in: CoatValidator.checkZipSafety(entries))
        if !listingErrors.isEmpty {
            return .refused(.zipListingFailed, messages: listingErrors)
        }

        let extractDir = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        do {
            try CoatValidator.extractZip(at: url, to: extractDir)
        } catch {
            return .refused(.zipExtractionFailed, messages: [Self.extractionFailedMessage])
        }

        // Symlinks are invisible in a listing, so this is the first point the
        // archive can be checked for one. Discard the extraction on an escape
        // rather than leaving a link into the user's home in the staging dir.
        let treeFindings = CoatValidator.checkExtractedTree(at: extractDir, fileManager: fileManager)
        let treeErrors = errors(in: treeFindings)
        if !treeErrors.isEmpty {
            try? fileManager.removeItem(at: extractDir)
            return .refused(.unsafeArchive, messages: treeErrors)
        }

        guard let coatFolder = CoatValidator.findCoatFolder(in: extractDir) else {
            return .refused(
                .noCoatFolderFound,
                messages: ["No coat folder found in archive (needs \(CoatValidator.requiredSprite))."]
            )
        }
        return .imported(coatFolder: coatFolder, findings: treeFindings)
    }

    // MARK: - Folder

    /// A chosen folder is copied without the two safety passes a zip gets, and
    /// that asymmetry is deliberate. A zip is a third-party artifact of unknown
    /// provenance; a folder is one the user just picked out of a file dialog, so
    /// they already have access to everything inside it and copying their own
    /// symlink into temp grants nobody anything. If that reasoning ever stops
    /// holding, `checkExtractedTree` is the pass to add here.
    private static func stageFolder(
        _ url: URL, into stagingRoot: URL, fileManager: FileManager
    ) -> Outcome.Result {
        let destination = stagingRoot.appendingPathComponent(
            url.lastPathComponent, isDirectory: true
        )
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            return .refused(.noCoatFolderFound, messages: [error.localizedDescription])
        }
        return .imported(coatFolder: destination, findings: [])
    }

    // MARK: - Helpers

    private static func makeStagingDirectory(fileManager: FileManager) throws -> URL {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("jumbini-workshop-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw ValidationError.stagingFailed
        }
        return staging
    }

    private static func errors(in findings: [ValidationFinding]) -> [String] {
        findings.filter { $0.severity == .error }.map(\.message)
    }

    private static let listingFailedMessage = "That archive could not be read."
    private static let extractionFailedMessage = "That archive could not be extracted."
}
