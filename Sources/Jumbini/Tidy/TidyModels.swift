import Foundation

enum TidyKind: String, Codable, CaseIterable, Equatable {
    case image, screenshot, document, archive, installer, video, audio, other
}

enum TidyMatchMode: String, Codable, Equatable {
    case all, any
}

enum TidyCondition: Codable, Equatable {
    case kind(TidyKind)
    case filenameContains(String)
    case extensions([String])
    case modifiedMoreThanDays(Int)
    case largerThanMB(Double)

    private enum CodingKeys: String, CodingKey {
        case type, kind, value, values
    }

    private enum ConditionType: String, Codable {
        case kind, filenameContains, extensions, modifiedMoreThanDays, largerThanMB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ConditionType.self, forKey: .type) {
        case .kind:
            self = .kind(try container.decode(TidyKind.self, forKey: .kind))
        case .filenameContains:
            self = .filenameContains(try container.decode(String.self, forKey: .value))
        case .extensions:
            self = .extensions(try container.decode([String].self, forKey: .values))
        case .modifiedMoreThanDays:
            self = .modifiedMoreThanDays(try container.decode(Int.self, forKey: .value))
        case .largerThanMB:
            self = .largerThanMB(try container.decode(Double.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .kind(let kind):
            try container.encode(ConditionType.kind, forKey: .type)
            try container.encode(kind, forKey: .kind)
        case .filenameContains(let value):
            try container.encode(ConditionType.filenameContains, forKey: .type)
            try container.encode(value, forKey: .value)
        case .extensions(let values):
            try container.encode(ConditionType.extensions, forKey: .type)
            try container.encode(values, forKey: .values)
        case .modifiedMoreThanDays(let value):
            try container.encode(ConditionType.modifiedMoreThanDays, forKey: .type)
            try container.encode(value, forKey: .value)
        case .largerThanMB(let value):
            try container.encode(ConditionType.largerThanMB, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct TidyRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var isEnabled = true
    var match: TidyMatchMode
    var conditions: [TidyCondition]
    var destination: String
}

struct TidyRuleSet: Codable, Equatable {
    var schemaVersion = 1
    var rules: [TidyRule]

    static let defaults = TidyRuleSet(rules: [
        TidyRule(name: "Screenshots", match: .all, conditions: [.kind(.screenshot)], destination: "Screenshots"),
        TidyRule(name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"),
        TidyRule(name: "Installers", match: .any, conditions: [.extensions(["dmg", "pkg"])], destination: "Installers"),
        TidyRule(name: "Archives", match: .all, conditions: [.kind(.archive)], destination: "Archives"),
    ])
}

struct TidyItemMetadata: Codable, Equatable {
    var name: String
    var pathExtension: String
    var contentTypeIdentifier: String?
    var modifiedAt: Date
    var byteCount: Int64
    var isPackage: Bool
}

enum TidySafety {
    static let maximumMoves = 50
}

struct TidyFileID: Codable, Hashable, Equatable {
    let device: UInt64
    let inode: UInt64
}

enum TidySkipReason: String, Codable, Equatable {
    case unmatched, recent, alias, symbolicLink, ordinaryDirectory
    case openByAnotherProcess, unreadableMetadata
}

struct TidyPlannedMove: Identifiable, Equatable {
    let id: UUID
    let source: URL
    let destination: URL
    let sourceID: TidyFileID
    let modifiedAt: Date
    let ruleID: UUID
    let ruleName: String
}

struct TidySkippedItem: Identifiable, Equatable {
    let id: UUID
    let source: URL
    let reason: TidySkipReason
}

enum TidyPlanRow: Identifiable, Equatable {
    case movable(TidyPlannedMove)
    case skipped(TidySkippedItem)

    var id: UUID {
        switch self {
        case .movable(let move):
            return move.id
        case .skipped(let item):
            return item.id
        }
    }
}

struct TidyPlan: Equatable {
    let root: URL
    let movable: [TidyPlannedMove]
    let skipped: [TidySkippedItem]

    var exceedsCap: Bool {
        movable.count > TidySafety.maximumMoves
    }
}

enum TidyPlanError: Error, Equatable {
    case unsafeRoot(URL)
    case unsafeDestination(String)
    case duplicateRuleID(UUID)
    case enumerationFailed(String)
}

struct TidyPassResult: Equatable {
    let passID: UUID
    let moves: [TidyCompletedMove]
    let skipped: [TidySkippedItem]
    let failures: [String]
    let didHitCap: Bool
    let wasHalted: Bool
}

struct TidyUndoResult: Equatable {
    let restoredCount: Int
}

enum TidyUndoError: Error, Equatable {
    case unavailable
    case sourceOccupied(URL)
    case destinationChanged(URL)
    case rollbackFailed(String)
}

enum TidyExecutionError: Error, Equatable {
    case unsafeRoot(URL)
    case pathOutsideRoot(URL)
    case identityUnavailable(URL)
    case deviceMismatch(source: URL, destinationParent: URL)
}
