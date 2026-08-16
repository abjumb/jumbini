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

struct ValidationFinding: Identifiable, Equatable {
    let id = UUID()
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

    /// List zip contents and check for dangerous entries before extraction.
    /// Returns nil if the archive is unsafe; otherwise returns the entry paths.
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
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError.zipListingFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw ValidationError.zipListingFailed
        }

        return parseZipList(output)
    }

    /// Check a list of zip entry paths for traversal, symlinks, and other dangers.
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

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError.zipExtractionFailed
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", destination.path, "."]
        process.currentDirectoryURL = folder

        let pipe = Pipe()
        process.standardOutput = pipe
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

    private static func parseZipList(_ output: String) -> [String] {
        var entries: [String] = []
        let lines = output.components(separatedBy: "\n")
        var inListing = false
        for line in lines {
            if inListing {
                if line.hasPrefix("---") { break }
                // unzip -l output format: "  Length   Date   Time   Name"
                // The name starts at column 30.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                // Skip the total line count before the separator.
                if trimmed.allSatisfy({ $0 == "-" }) { break }
                // Extract filename: skip length/date/time columns.
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 4 {
                    let name = parts.dropFirst(3).joined(separator: " ")
                    entries.append(name)
                }
            } else if line.hasPrefix("  Length") {
                inListing = true
            }
        }
        return entries
    }
}

enum ValidationError: Error, Equatable {
    case zipListingFailed
    case zipExtractionFailed
    case zipCreationFailed
    case noCoatFolderFound
    case stagingFailed
}
