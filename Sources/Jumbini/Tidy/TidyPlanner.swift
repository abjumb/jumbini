import Darwin
import Foundation

protocol TidyOpenFileDetecting {
    func openPaths(under root: URL) -> Set<String>
}

struct SystemTidyOpenFileDetector: TidyOpenFileDetecting {
    func openPaths(under root: URL) -> Set<String> {
        let executable = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return []
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-Fn", "+d", root.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return []
            }
            return Set(text.split(whereSeparator: \.isNewline).compactMap { record in
                guard record.first == "n" else { return nil }
                let path = String(record.dropFirst())
                guard path.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL.path
            })
        } catch {
            return []
        }
    }
}

struct TidyPlanner {
    private static let metadataKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .contentTypeKey,
        .fileSizeKey,
        .isAliasFileKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
    ]

    private let openFiles: TidyOpenFileDetecting
    private let fileManager: FileManager

    init(
        openFiles: TidyOpenFileDetecting = SystemTidyOpenFileDetector(),
        fileManager: FileManager = .default
    ) {
        self.openFiles = openFiles
        self.fileManager = fileManager
    }

    func plan(
        root: URL,
        rules: [TidyRule],
        recencyMinutes: Int,
        now: Date
    ) throws -> TidyPlan {
        let resolvedRoot = try resolveRoot(root)
        let destinations = try resolvedDestinations(for: rules, under: resolvedRoot)
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: resolvedRoot,
                includingPropertiesForKeys: Array(Self.metadataKeys),
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            throw TidyPlanError.enumerationFailed(error.localizedDescription)
        }

        let openPaths = Set(openFiles.openPaths(under: resolvedRoot).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let recencyInterval = Double(max(recencyMinutes, 1)) * 60
        var reservedDestinations = Set<String>()
        var movable: [TidyPlannedMove] = []
        var skipped: [TidySkippedItem] = []

        for child in children {
            let source = child.standardizedFileURL
            let values: URLResourceValues
            do {
                values = try source.resourceValues(forKeys: Self.metadataKeys)
            } catch {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .unreadableMetadata))
                continue
            }

            if values.isSymbolicLink == true {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .symbolicLink))
                continue
            }
            if values.isAliasFile == true {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .alias))
                continue
            }

            let isPackage = values.isPackage == true
            if values.isDirectory == true && !isPackage {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .ordinaryDirectory))
                continue
            }

            guard let modifiedAt = values.contentModificationDate,
                  let sourceID = fileID(for: source),
                  let byteCount = values.fileSize ?? (isPackage ? 0 : nil) else {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .unreadableMetadata))
                continue
            }

            if now.timeIntervalSince(modifiedAt) < recencyInterval {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .recent))
                continue
            }
            if isOpen(source, isPackage: isPackage, openPaths: openPaths) {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .openByAnotherProcess))
                continue
            }

            let metadata = TidyItemMetadata(
                name: source.lastPathComponent,
                pathExtension: source.pathExtension,
                contentTypeIdentifier: values.contentType?.identifier,
                modifiedAt: modifiedAt,
                byteCount: Int64(byteCount),
                isPackage: isPackage
            )
            guard let rule = TidyRuleEngine.firstMatch(for: metadata, rules: rules, now: now),
                  let destinationDirectory = destinations[rule.id] else {
                skipped.append(TidySkippedItem(id: UUID(), source: source, reason: .unmatched))
                continue
            }

            let destination = availableDestination(
                for: source.lastPathComponent,
                in: destinationDirectory,
                reserved: &reservedDestinations
            )
            movable.append(TidyPlannedMove(
                id: UUID(), source: source, destination: destination,
                sourceID: sourceID, modifiedAt: modifiedAt,
                ruleID: rule.id, ruleName: rule.name
            ))
        }

        return TidyPlan(root: resolvedRoot, movable: movable, skipped: skipped)
    }

    static func validateDestination(_ destination: String) throws {
        guard !destination.isEmpty,
              destination != ".",
              destination != "..",
              !destination.hasPrefix("."),
              !destination.hasPrefix("/"),
              !destination.contains("/"),
              !destination.contains("\\") else {
            throw TidyPlanError.unsafeDestination(destination)
        }
    }

    private func resolveRoot(_ root: URL) throws -> URL {
        guard root.isFileURL else {
            throw TidyPlanError.unsafeRoot(root)
        }
        let resolvedPath = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TidyPlanError.unsafeRoot(root)
        }
        return resolved
    }

    private func resolvedDestinations(
        for rules: [TidyRule],
        under root: URL
    ) throws -> [UUID: URL] {
        var destinations: [UUID: URL] = [:]
        for rule in rules {
            guard destinations[rule.id] == nil else {
                throw TidyPlanError.duplicateRuleID(rule.id)
            }
            try Self.validateDestination(rule.destination)
            let resolved = root.appendingPathComponent(
                rule.destination, isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard contains(resolved, in: root) else {
                throw TidyPlanError.unsafeDestination(rule.destination)
            }
            destinations[rule.id] = resolved
        }
        return destinations
    }

    private func contains(_ url: URL, in root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private func fileID(for url: URL) -> TidyFileID? {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            return nil
        }
        return TidyFileID(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
    }

    private func isOpen(_ source: URL, isPackage: Bool, openPaths: Set<String>) -> Bool {
        let sourcePath = source.standardizedFileURL.path
        if openPaths.contains(sourcePath) {
            return true
        }
        return isPackage && openPaths.contains { $0.hasPrefix(sourcePath + "/") }
    }

    private func availableDestination(
        for sourceName: String,
        in directory: URL,
        reserved: inout Set<String>
    ) -> URL {
        let name = (sourceName as NSString).deletingPathExtension
        let pathExtension = (sourceName as NSString).pathExtension
        var suffix = 1

        while true {
            let candidateName: String
            if suffix == 1 {
                candidateName = sourceName
            } else if pathExtension.isEmpty {
                candidateName = "\(name) \(suffix)"
            } else {
                candidateName = "\(name) \(suffix).\(pathExtension)"
            }
            let candidate = directory.appendingPathComponent(candidateName).standardizedFileURL
            if !isOccupied(candidate),
               !reserved.contains(candidate.path) {
                reserved.insert(candidate.path)
                return candidate
            }
            suffix += 1
        }
    }

    private func isOccupied(_ url: URL) -> Bool {
        var information = stat()
        return Darwin.lstat(url.path, &information) == 0
    }
}
