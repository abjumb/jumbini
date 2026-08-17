import Foundation
import CoreGraphics
import ImageIO

/// The 17 coat states from COATS.md, in the order they should be previewed.
enum FullCoatState: String, CaseIterable {
    case idle, run1, run2, sit, sleep, bark, sniff
    case hunch, stalk, pounce, paw, highfive, playdead
    case brace, fall, land, peek
}

/// All 8 directions from COATS.md.
extension Facing {
    static let coatDirections: [Facing] = [.south, .southEast, .east, .northEast,
                                           .north, .northWest, .west, .southWest]
}

/// A single validation finding.
enum ValidationSeverity: Equatable {
    case error
    case warning
    case info
}

/// A finding is its severity and its message and nothing else. It carried a
/// `let id = UUID()` for `Identifiable`, which — being freshly random per
/// instance — made `==` false for every pair, including two findings with
/// identical text. Nothing consumed the id; a test asserting on findings, or
/// any future dedupe, needs the equality more than the identity.
struct ValidationFinding: Equatable {
    let severity: ValidationSeverity
    let message: String
}

/// The result of validating a coat folder. Pure data, no AppKit.
struct CoatValidationReport {
    let coatID: String
    let coatName: String
    let findings: [ValidationFinding]
    let presentStates: Set<String>
    let missingStates: Set<String>
    let stateDirections: [String: Set<String>]
    let scales: [String: CGFloat]

    var errors: [String] {
        findings.filter { $0.severity == .error }.map(\.message)
    }

    var warnings: [String] {
        findings.filter { $0.severity == .warning }.map(\.message)
    }

    var infos: [String] {
        findings.filter { $0.severity == .info }.map(\.message)
    }

    var canInstall: Bool { !findings.contains { $0.severity == .error } }
}

/// Pure validation of a coat folder against COATS.md. No AppKit, no SpriteKit,
/// no bundle access — testable against a temporary directory.
enum CoatValidator {
    static let canvasSize = 48
    static let allowedStates = Set(FullCoatState.allCases.map(\.rawValue))

    /// The one sprite every coat must have to qualify.
    static let requiredSprite = "idle_south.png"

    /// Validate a coat folder. Returns a report even if there are errors —
    /// the caller decides whether to block installation.
    static func validate(
        folder: URL,
        fileManager: FileManager = .default
    ) -> CoatValidationReport {
        var findings: [ValidationFinding] = []
        let folderName = folder.lastPathComponent

        let manifest = readManifest(in: folder, fileManager: fileManager)
        let trimmed = manifest?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let coatName = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? folderName

        guard fileManager.fileExists(atPath: folder.appendingPathComponent(requiredSprite).path) else {
            findings.append(ValidationFinding(
                severity: .error,
                message: "Missing \(requiredSprite) — a coat folder must contain at least this sprite."
            ))
            return CoatValidationReport(
                coatID: folderName, coatName: coatName, findings: findings,
                presentStates: [], missingStates: Set(allowedStates),
                stateDirections: [:], scales: [:]
            )
        }

        let spriteFiles = spriteFileNames(in: folder, fileManager: fileManager)
        let parsed = parseSprites(spriteFiles)

        // Check every state × direction pair.
        var presentStates = Set<String>()
        var missingStates = Set<String>()
        var stateDirections: [String: Set<String>] = [:]
        var imageFindings: [ValidationFinding] = []

        for state in FullCoatState.allCases {
            let stateName = state.rawValue
            var haveDirections = Set<String>()
            var missingDirections = Set<String>()

            for direction in Facing.coatDirections {
                let suffix = direction.fileSuffix
                let filename = "\(stateName)_\(suffix).png"
                if parsed.contains(filename) {
                    haveDirections.insert(suffix)
                } else {
                    missingDirections.insert(suffix)
                }
            }

            if haveDirections.isEmpty {
                missingStates.insert(stateName)
            } else {
                presentStates.insert(stateName)
                stateDirections[stateName] = haveDirections
            }

            if !missingDirections.isEmpty && !haveDirections.isEmpty {
                let missing = missingDirections.sorted().joined(separator: ", ")
                findings.append(ValidationFinding(
                    severity: .warning,
                    message: "\(stateName): missing directions \(missing) — falls back to Jumba for those facings."
                ))
            }
        }

        for state in missingStates.sorted() {
            findings.append(ValidationFinding(
                severity: .info,
                message: "\(state): all directions missing — uses Jumba's art for this pose."
            ))
        }

        // Check image format and dimensions for each sprite.
        for filename in spriteFiles {
            let url = folder.appendingPathComponent(filename)
            imageFindings.append(contentsOf: validateImage(at: url, filename: filename))
        }
        findings.append(contentsOf: imageFindings)

        // Check for unsafe filenames.
        for filename in spriteFiles {
            if let finding = validateFilename(filename) {
                findings.append(finding)
            }
        }

        // Check for extra files that aren't sprites or manifest.
        let knownFiles = Set(spriteFiles).union(["coat.json"])
        if let allFiles = try? fileManager.contentsOfDirectory(atPath: folder.path) {
            for file in allFiles {
                if !knownFiles.contains(file) {
                    findings.append(ValidationFinding(
                        severity: .warning,
                        message: "Unexpected file: \(file)"
                    ))
                }
            }
        }

        // Check built-in shadowing.
        if Coat.builtIn.map(\.id).contains(folderName) {
            findings.append(ValidationFinding(
                severity: .error,
                message: "Folder name \"\(folderName)\" shadows a built-in coat. Rename the folder."
            ))
        }

        // Duplicate check against installed coats.
        if let coatsDir = CoatCatalog.defaultCoatsDirectory(fileManager: fileManager) {
            let installed = CoatCatalog.installed(coatsDirectory: coatsDir, fileManager: fileManager)
            if installed.contains(where: { $0.id == folderName }) {
                findings.append(ValidationFinding(
                    severity: .warning,
                    message: "A coat named \"\(folderName)\" is already installed. Installing will replace it."
                ))
            }
        }

        return CoatValidationReport(
            coatID: folderName,
            coatName: coatName,
            findings: findings,
            presentStates: presentStates,
            missingStates: missingStates,
            stateDirections: stateDirections,
            scales: (manifest?.scales ?? [:]).mapValues { CGFloat($0) }
        )
    }

    // MARK: - Zip safety

    /// List the entry paths in an archive, for `checkZipSafety` to judge
    /// before anything is written to disk.
    static func listZipContents(
        at archiveURL: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", archiveURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()

        // Drain before waiting. `unzip -l` on a large archive will fill the
        // pipe buffer and block forever if we wait for exit first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError.zipListingFailed
        }

        guard let output = String(data: data, encoding: .utf8) else {
            throw ValidationError.zipListingFailed
        }

        return parseZipList(output)
    }

    /// Check a list of zip entry paths for traversal and other dangers.
    ///
    /// A listing names entries but does not say what they are, so symlinks are
    /// invisible here — they are caught after extraction by
    /// `checkExtractedTree(at:fileManager:)`.
    static func checkZipSafety(
        _ entries: [String],
        maxFiles: Int = 500,
        maxExpansionRatio: Int = 100
    ) -> [ValidationFinding] {
        var findings: [ValidationFinding] = []

        if entries.count > maxFiles {
            findings.append(ValidationFinding(
                severity: .error,
                message: "Archive contains \(entries.count) files (max \(maxFiles))."
            ))
        }

        for entry in entries {
            let normalized = (entry as NSString).standardizingPath
            if normalized.hasPrefix("/") {
                findings.append(ValidationFinding(
                    severity: .error,
                    message: "Path traversal detected: \"\(entry)\" is an absolute path."
                ))
            }
            if normalized.hasPrefix("..") {
                findings.append(ValidationFinding(
                    severity: .error,
                    message: "Path traversal detected: \"\(entry)\" escapes the archive root."
                ))
            }
            if entry.contains("..") && !normalized.hasPrefix("..") {
                findings.append(ValidationFinding(
                    severity: .error,
                    message: "Path traversal detected: \"\(entry)\" contains \"..\"."
                ))
            }
            let filename = (entry as NSString).lastPathComponent
            if filename.hasPrefix(".") && filename != ".DS_Store" {
                findings.append(ValidationFinding(
                    severity: .warning,
                    message: "Hidden file: \(entry)"
                ))
            }
            if entry.hasSuffix("/") {
                // It's a directory — fine.
                continue
            }
            let ext = (entry as NSString).pathExtension.lowercased()
            if ext != "png" && ext != "json" {
                findings.append(ValidationFinding(
                    severity: .warning,
                    message: "Unsupported file type: \(entry)"
                ))
            }
        }

        let pngCount = entries.filter { ($0 as NSString).pathExtension.lowercased() == "png" }.count
        let expected = FullCoatState.allCases.count * Facing.coatDirections.count
        if pngCount > expected + 10 {
            findings.append(ValidationFinding(
                severity: .warning,
                message: "Archive contains \(pngCount) PNGs; a full coat needs \(expected)."
            ))
        }

        return findings
    }

    /// Extract a validated zip into a staging directory.
    static func extractZip(
        at archiveURL: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archiveURL.path, "-d", destination.path]

        // The listing chatter is unused; a Pipe nobody drains would deadlock.
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError.zipExtractionFailed
        }
    }

    /// Walk an extracted archive and report its symlinks.
    ///
    /// This is the half of zip safety that a listing cannot do. `unzip -l`
    /// prints a symlink as an ordinary row, so a link is only distinguishable
    /// once it is on disk — and a link is how an archive reaches outside the
    /// staging directory without any entry path containing "..": install
    /// copies the coat folder, and a link pointing at `~/.ssh` would be copied
    /// along with it, or followed by anything later reading the coat.
    ///
    /// A link that stays inside the extracted tree is merely unexpected in a
    /// folder of PNGs; one that resolves outside it is an error.
    static func checkExtractedTree(
        at root: URL,
        fileManager: FileManager = .default
    ) -> [ValidationFinding] {
        // The staging root normally lives under /var/folders, itself a symlink
        // to /private/var, so containment has to be judged against the
        // resolved path or every entry looks like an escape.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let displayRoot = root.standardizedFileURL.path

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return [ValidationFinding(
                severity: .error,
                message: "Could not read the extracted archive."
            )]
        }

        var findings: [ValidationFinding] = []
        for case let url as URL in enumerator {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard isLink else { continue }

            let path = url.standardizedFileURL.path
            let name = path.hasPrefix(displayRoot + "/")
                ? String(path.dropFirst(displayRoot.count + 1))
                : url.lastPathComponent
            let target = url.resolvingSymlinksInPath().standardizedFileURL.path

            if target == resolvedRoot || target.hasPrefix(resolvedRoot + "/") {
                findings.append(ValidationFinding(
                    severity: .warning,
                    message: "Symlink: \(name) — points inside the coat folder; installing copies the link, not the file."
                ))
            } else {
                findings.append(ValidationFinding(
                    severity: .error,
                    message: "Symlink escapes the archive: \"\(name)\" points to \(target)."
                ))
            }
        }
        return findings
    }

    /// Find the coat folder inside an extracted zip. The user may have zipped the
    /// folder directly, or the folder's contents. Returns the folder URL.
    static func findCoatFolder(
        in extractionRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        // First check if the extraction root itself is a coat folder.
        if fileManager.fileExists(atPath: extractionRoot.appendingPathComponent(requiredSprite).path) {
            return extractionRoot
        }

        // Otherwise look for a single subdirectory that is a coat.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: extractionRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let dirs = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if dirs.count == 1,
           fileManager.fileExists(atPath: dirs[0].appendingPathComponent(requiredSprite).path) {
            return dirs[0]
        }

        return nil
    }

    // MARK: - Installation

    /// Copy a validated coat folder atomically into the coats directory.
    /// Writes to a temporary name first, then renames into place.
    static func installCoat(
        from staging: URL,
        coatsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let coatID = staging.lastPathComponent
        let destination = coatsDirectory.appendingPathComponent(coatID, isDirectory: true)
        let tempDest = coatsDirectory.appendingPathComponent(".\(coatID).tmp", isDirectory: true)

        // Clean up any stale temp.
        try? fileManager.removeItem(at: tempDest)

        // Ensure coats directory exists.
        try fileManager.createDirectory(at: coatsDirectory, withIntermediateDirectories: true)

        // Copy to temp location.
        try fileManager.copyItem(at: staging, to: tempDest)

        // Atomically replace the destination.
        if fileManager.fileExists(atPath: destination.path) {
            let old = coatsDirectory.appendingPathComponent(".\(coatID).old", isDirectory: true)
            try? fileManager.removeItem(at: old)
            do {
                try fileManager.moveItem(at: destination, to: old)
            } catch {
                try? fileManager.removeItem(at: tempDest)
                throw error
            }
            do {
                try fileManager.moveItem(at: tempDest, to: destination)
                try? fileManager.removeItem(at: old)
            } catch {
                // Rollback: move old back.
                try? fileManager.moveItem(at: old, to: destination)
                try? fileManager.removeItem(at: tempDest)
                throw error
            }
        } else {
            try fileManager.moveItem(at: tempDest, to: destination)
        }

        return destination
    }

    // MARK: - Export

    /// Export a coat folder as a portable zip.
    static func exportCoat(
        from folder: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        // `zip -r` *updates* an archive that already exists, so exporting over
        // a previous export would merge the two coats rather than replace one
        // with the other — and NSSavePanel's "Replace?" only promises the
        // former file is gone. Make that true.
        try? fileManager.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", destination.path, "."]
        process.currentDirectoryURL = folder

        // Per-file "adding: …" output is unused; a Pipe nobody drains would deadlock.
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError.zipCreationFailed
        }
    }

    // MARK: - Internals

    private static func readManifest(
        in folder: URL,
        fileManager: FileManager
    ) -> CoatManifest? {
        let url = folder.appendingPathComponent("coat.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CoatManifest.self, from: data)
    }

    private static func spriteFileNames(
        in folder: URL,
        fileManager: FileManager
    ) -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        return contents.filter { ($0 as NSString).pathExtension.lowercased() == "png" }
    }

    private static func parseSprites(_ filenames: [String]) -> Set<String> {
        Set(filenames)
    }

    private static func validateFilename(_ filename: String) -> ValidationFinding? {
        let name = (filename as NSString).deletingPathExtension
        let parts = name.split(separator: "_", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return ValidationFinding(
                severity: .warning,
                message: "Unexpected filename format: \(filename) — expected <state>_<direction>.png"
            )
        }
        let state = String(parts[0])
        if !allowedStates.contains(state) {
            return nil // silently skip — user may have extra sprites
        }
        return nil
    }

    private static func validateImage(
        at url: URL,
        filename: String
    ) -> [ValidationFinding] {
        var findings: [ValidationFinding] = []

        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?
        else {
            findings.append(ValidationFinding(
                severity: .error,
                message: "\(filename): cannot read image data."
            ))
            return findings
        }

        if type != "public.png" {
            findings.append(ValidationFinding(
                severity: .error,
                message: "\(filename): not a PNG (got \(type))."
            ))
            return findings
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            findings.append(ValidationFinding(
                severity: .error,
                message: "\(filename): cannot decode PNG."
            ))
            return findings
        }

        let w = image.width, h = image.height
        if w != canvasSize || h != canvasSize {
            findings.append(ValidationFinding(
                severity: .warning,
                message: "\(filename): \(w)×\(h) — expected \(canvasSize)×\(canvasSize). Consider adding a \"scales\" override in coat.json."
            ))
        }

        guard let alphaInfo = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let hasAlpha = alphaInfo[kCGImagePropertyHasAlpha] as? Bool
        else {
            // Can't determine — not a fatal error.
            return findings
        }

        if !hasAlpha {
            findings.append(ValidationFinding(
                severity: .warning,
                message: "\(filename): no alpha channel — expect a solid background rectangle, not a transparent sprite."
            ))
        }

        return findings
    }

    /// Where `parseZipList` is in `unzip -l`'s output.
    private enum ZipListPosition {
        /// Before the `  Length      Date    Time    Name` header.
        case beforeHeader
        /// On the rule directly under the header.
        case onHeaderRule
        /// On the entry rows themselves.
        case inListing
    }

    private static func parseZipList(_ output: String) -> [String] {
        var entries: [String] = []
        var nameColumn = 0
        var position = ZipListPosition.beforeHeader

        for line in output.components(separatedBy: "\n") {
            switch position {
            case .beforeHeader:
                guard line.hasPrefix("  Length"),
                      let nameHeading = line.range(of: "Name")
                else { continue }
                nameColumn = line.distance(from: line.startIndex, to: nameHeading.lowerBound)
                position = .onHeaderRule

            case .onHeaderRule:
                // The rule under the header and the one that closes the
                // listing both begin "---------", so this one is consumed by
                // position rather than matched — matching it as a terminator
                // is what used to end the parse before a single entry was read.
                position = .inListing

            case .inListing:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("---") { return entries }
                if let entry = zipEntryName(in: line, nameColumn: nameColumn) {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    /// Take the entry name out of one `unzip -l` row.
    ///
    /// Names may contain spaces, so the Name column recorded from the header
    /// is authoritative — rejoining whitespace-split fields collapses runs of
    /// spaces and yields a path that does not match what was extracted, which
    /// matters when the result is fed to a safety check. A row whose size
    /// field is wide enough to push past that column falls back to splitting,
    /// which loses interior spaces but is better than dropping the entry.
    private static func zipEntryName(in line: String, nameColumn: Int) -> String? {
        if nameColumn > 0,
           let start = line.index(line.startIndex, offsetBy: nameColumn, limitedBy: line.endIndex),
           start < line.endIndex,
           line[line.index(before: start)].isWhitespace {
            let name = String(line[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }

        let parts = line
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        return parts.dropFirst(3).joined(separator: " ")
    }
}

enum ValidationError: Error, Equatable {
    case zipListingFailed
    case zipExtractionFailed
    case zipCreationFailed
    case unsafeArchive
    case noCoatFolderFound
    case stagingFailed
}
