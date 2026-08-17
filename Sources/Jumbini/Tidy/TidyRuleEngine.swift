import Foundation
import UniformTypeIdentifiers

enum TidyRuleEngine {
    static func firstMatch(for item: TidyItemMetadata, rules: [TidyRule], now: Date) -> TidyRule? {
        guard !item.isPackage else { return nil }

        return rules.first { rule in
            rule.isEnabled && matches(rule, item: item, now: now)
        }
    }

    private static func matches(_ rule: TidyRule, item: TidyItemMetadata, now: Date) -> Bool {
        guard !rule.conditions.isEmpty else { return false }

        switch rule.match {
        case .all:
            return rule.conditions.allSatisfy { matches($0, item: item, now: now) }
        case .any:
            return rule.conditions.contains { matches($0, item: item, now: now) }
        }
    }

    private static func matches(_ condition: TidyCondition, item: TidyItemMetadata, now: Date) -> Bool {
        switch condition {
        case .kind(let expectedKind):
            return kind(of: item) == expectedKind
        case .filenameContains(let value):
            return item.name.range(of: value, options: .caseInsensitive) != nil
        case .extensions(let extensions):
            let itemExtension = normalizedExtension(item.pathExtension)
            return extensions.map(normalizedExtension).contains(itemExtension)
        case .modifiedMoreThanDays(let days):
            return now.timeIntervalSince(item.modifiedAt) > Double(days) * 86_400
        case .largerThanMB(let megabytes):
            return Double(item.byteCount) > megabytes * 1_000_000
        }
    }

    private static func kind(of item: TidyItemMetadata) -> TidyKind {
        let pathExtension = normalizedExtension(item.pathExtension)
        if pathExtension == "dmg" || pathExtension == "pkg" {
            return .installer
        }
        if item.name.hasPrefix("Screenshot ") || item.name.hasPrefix("Screen Shot ") {
            return .screenshot
        }

        guard let identifier = item.contentTypeIdentifier, let type = UTType(identifier) else {
            return .other
        }
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .archive) {
            return .archive
        }
        if type.conforms(to: .movie) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .rtf) {
            return .document
        }
        return .other
    }

    private static func normalizedExtension(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}
