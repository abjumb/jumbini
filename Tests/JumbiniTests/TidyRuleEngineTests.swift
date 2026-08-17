import Foundation
import Testing
@testable import Jumbini

@Suite struct TidyRuleEngineTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        name: String = "report.pdf",
        pathExtension: String = "pdf",
        contentTypeIdentifier: String? = "com.adobe.pdf",
        modifiedAt: Date = Date(timeIntervalSince1970: 900_000),
        byteCount: Int64 = 2_000_000,
        isPackage: Bool = false
    ) -> TidyItemMetadata {
        TidyItemMetadata(
            name: name,
            pathExtension: pathExtension,
            contentTypeIdentifier: contentTypeIdentifier,
            modifiedAt: modifiedAt,
            byteCount: byteCount,
            isPackage: isPackage
        )
    }

    @Test func firstMatchingRuleWins() {
        let item = TidyItemMetadata(
            name: "client-export-final.png",
            pathExtension: "png",
            contentTypeIdentifier: "public.png",
            modifiedAt: Date(timeIntervalSince1970: 0),
            byteCount: 2_000_000,
            isPackage: false
        )
        let first = TidyRule(
            name: "Client exports", match: .all,
            conditions: [.filenameContains("export")], destination: "Client"
        )
        let second = TidyRule(
            name: "Final files", match: .all,
            conditions: [.filenameContains("final")], destination: "Final"
        )

        #expect(TidyRuleEngine.firstMatch(
            for: item, rules: [first, second], now: Date(timeIntervalSince1970: 1_000_000)
        )?.id == first.id)
    }

    @Test func unmatchedItemHasNoRule() {
        let item = TidyItemMetadata(
            name: "notes.xyz", pathExtension: "xyz",
            contentTypeIdentifier: nil, modifiedAt: .distantPast,
            byteCount: 12, isPackage: false
        )
        #expect(TidyRuleEngine.firstMatch(for: item, rules: TidyRuleSet.defaults.rules, now: .now) == nil)
    }

    @Test func allRequiresEveryCondition() {
        let rule = TidyRule(
            name: "Large reports", match: .all,
            conditions: [.filenameContains("report"), .largerThanMB(3)], destination: "Reports"
        )
        #expect(TidyRuleEngine.firstMatch(for: item(), rules: [rule], now: now) == nil)
    }

    @Test func anyRequiresOneCondition() {
        let rule = TidyRule(
            name: "Media", match: .any,
            conditions: [.filenameContains("invoice"), .extensions(["pdf"])], destination: "Media"
        )
        #expect(TidyRuleEngine.firstMatch(for: item(), rules: [rule], now: now)?.id == rule.id)
    }

    @Test func disabledRuleNeverMatches() {
        var rule = TidyRule(
            name: "Reports", match: .all, conditions: [.extensions(["pdf"])], destination: "Reports"
        )
        rule.isEnabled = false
        #expect(TidyRuleEngine.firstMatch(for: item(), rules: [rule], now: now) == nil)
    }

    @Test func filenameContainsIsCaseInsensitive() {
        let rule = TidyRule(
            name: "Invoices", match: .all, conditions: [.filenameContains("INVOICE")], destination: "Invoices"
        )
        #expect(TidyRuleEngine.firstMatch(for: item(name: "march-invoice.pdf"), rules: [rule], now: now)?.id == rule.id)
    }

    @Test func extensionsNormalizeDotsAndCase() {
        let rule = TidyRule(
            name: "Images", match: .all, conditions: [.extensions([".PNG"])], destination: "Images"
        )
        #expect(TidyRuleEngine.firstMatch(for: item(name: "photo.PNG", pathExtension: ".PNG"), rules: [rule], now: now)?.id == rule.id)
    }

    @Test func modifiedAgeUsesInjectedClock() {
        let rule = TidyRule(
            name: "Old files", match: .all, conditions: [.modifiedMoreThanDays(2)], destination: "Old"
        )
        let exactlyTwoDaysOld = item(modifiedAt: now.addingTimeInterval(-2 * 86_400))
        let olderThanTwoDays = item(modifiedAt: now.addingTimeInterval(-2 * 86_400 - 1))
        #expect(TidyRuleEngine.firstMatch(for: exactlyTwoDaysOld, rules: [rule], now: now) == nil)
        #expect(TidyRuleEngine.firstMatch(for: olderThanTwoDays, rules: [rule], now: now)?.id == rule.id)
    }

    @Test func sizeUsesDecimalMegabytes() {
        let rule = TidyRule(
            name: "Large files", match: .all, conditions: [.largerThanMB(1.5)], destination: "Large"
        )
        #expect(TidyRuleEngine.firstMatch(for: item(byteCount: 1_500_000), rules: [rule], now: now) == nil)
        #expect(TidyRuleEngine.firstMatch(for: item(byteCount: 1_500_001), rules: [rule], now: now)?.id == rule.id)
    }

    @Test(arguments: [
        (TidyKind.image, "photo.png", "png", "public.png"),
        (TidyKind.screenshot, "Screenshot 2026-08-17.png", "png", "public.png"),
        (TidyKind.document, "report.pdf", "pdf", "com.adobe.pdf"),
        (TidyKind.archive, "backup.zip", "zip", "public.zip-archive"),
        (TidyKind.installer, "Jumbini.dmg", "dmg", "public.disk-image"),
        (TidyKind.video, "clip.mov", "mov", "com.apple.quicktime-movie"),
        (TidyKind.audio, "song.mp3", "mp3", "public.mp3")
    ]) func kindConditionsMatchRecognizedMetadata(
        kind: TidyKind, name: String, pathExtension: String, typeIdentifier: String
    ) {
        let rule = TidyRule(name: "Kind", match: .all, conditions: [.kind(kind)], destination: "Matched")
        #expect(TidyRuleEngine.firstMatch(
            for: item(name: name, pathExtension: pathExtension, contentTypeIdentifier: typeIdentifier), rules: [rule], now: now
        )?.id == rule.id)
    }

    @Test func packagesDoNotMatchRules() {
        let rule = TidyRule(name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images")
        #expect(TidyRuleEngine.firstMatch(for: item(name: "Photo.app", pathExtension: "app", contentTypeIdentifier: "public.png", isPackage: true), rules: [rule], now: now) == nil)
    }

    @Test func emptyConditionsDoNotMatch() {
        let rule = TidyRule(name: "Empty", match: .all, conditions: [], destination: "Nowhere")
        #expect(TidyRuleEngine.firstMatch(for: item(), rules: [rule], now: now) == nil)
    }

    @Test func defaultPresetOrderIsSafe() {
        #expect(TidyRuleSet.defaults.rules.map(\.name) == ["Screenshots", "Images", "Installers", "Archives"])
        #expect(TidySafety.maximumMoves == 50)
    }

    @Test func conditionsUseHandEditableDiscriminatedJSON() throws {
        let encoded = try JSONEncoder().encode(TidyCondition.extensions(["dmg", "pkg"]))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["type"] as? String == "extensions")
        #expect(json["values"] as? [String] == ["dmg", "pkg"])
        #expect(try JSONDecoder().decode(TidyCondition.self, from: encoded) == .extensions(["dmg", "pkg"]))
    }
}
