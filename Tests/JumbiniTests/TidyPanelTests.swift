import AppKit
import Foundation
import Testing
@testable import Jumbini

// The three Tidy panels are the only place a user sees what Tidy is about to do
// to their files, so the parts that decide *what is shown* and *what comes back
// out* are tested here rather than left to the eye: a preview row that reports
// the wrong destination, or a confirmation that returns rows the user unticked,
// is a file in the wrong place.

@Suite @MainActor struct TidySettingsPanelTests {
    @Test func rulesRenderInTheirStoredOrderWithDestinations() {
        let panel = TidySettingsPanel()
        panel.render(state: .fixture())

        #expect(panel.ruleRowNames == ["Screenshots", "Images", "Installers", "Archives"])
        #expect(panel.ruleRowDestinations == ["Screenshots", "Images", "Installers", "Archives"])
    }

    @Test func conditionSummariesReadAsSentencesNotEnumCases() {
        let all = TidyRule(
            name: "Big old exports", match: .all,
            conditions: [
                .kind(.image), .filenameContains("export"),
                .modifiedMoreThanDays(30), .largerThanMB(2.5),
            ],
            destination: "Exports"
        )
        let any = TidyRule(
            name: "Installers", match: .any,
            conditions: [.extensions(["dmg", "pkg"])], destination: "Installers"
        )

        #expect(TidyRuleSummary.text(for: all)
            == "All of: images, name contains “export”, older than 30 days, larger than 2.5 MB")
        #expect(TidyRuleSummary.text(for: any) == "Any of: extension dmg or pkg")
    }

    @Test func reorderingARuleReportsTheWholeReorderedSet() {
        let panel = TidySettingsPanel()
        var reported: [TidyRuleSet] = []
        panel.onRulesChanged = { reported.append($0) }
        panel.render(state: .fixture())

        panel.moveRule(at: 2, by: -1)

        #expect(panel.ruleRowNames == ["Screenshots", "Installers", "Images", "Archives"])
        #expect(reported.last?.rules.map(\.name) == ["Screenshots", "Installers", "Images", "Archives"])
    }

    @Test func reorderingPastAnEdgeChangesNothingAndReportsNothing() {
        let panel = TidySettingsPanel()
        var reported: [TidyRuleSet] = []
        panel.onRulesChanged = { reported.append($0) }
        panel.render(state: .fixture())

        panel.moveRule(at: 0, by: -1)
        panel.moveRule(at: 3, by: 1)

        #expect(panel.ruleRowNames == ["Screenshots", "Images", "Installers", "Archives"])
        #expect(reported.isEmpty)
    }

    @Test func removingARuleDropsOnlyThatRow() {
        let panel = TidySettingsPanel()
        var reported: [TidyRuleSet] = []
        panel.onRulesChanged = { reported.append($0) }
        panel.render(state: .fixture())

        panel.removeRule(at: 1)

        #expect(panel.ruleRowNames == ["Screenshots", "Installers", "Archives"])
        #expect(reported.last?.rules.map(\.name) == ["Screenshots", "Installers", "Archives"])
    }

    @Test func disablingARuleKeepsItInPlace() {
        let panel = TidySettingsPanel()
        var reported: [TidyRuleSet] = []
        panel.onRulesChanged = { reported.append($0) }
        panel.render(state: .fixture())

        panel.setRuleEnabled(false, at: 0)

        #expect(reported.last?.rules.map(\.name) == ["Screenshots", "Images", "Installers", "Archives"])
        #expect(reported.last?.rules[0].isEnabled == false)
    }

    @Test func editingARuleHandsBackTheRuleThatWasClicked() {
        let panel = TidySettingsPanel()
        var edited: TidyRule?
        panel.onEditRule = { edited = $0 }
        let state = TidyCoordinator.State.fixture()
        panel.render(state: state)

        panel.editRule(at: 2)

        #expect(edited == state.rules.rules[2])
    }

    @Test func addingARuleAsksTheDelegateRatherThanInventingOne() {
        let panel = TidySettingsPanel()
        var addRequests = 0
        panel.onAddRule = { addRequests += 1 }
        panel.render(state: .fixture())

        panel.addRule()

        #expect(addRequests == 1)
        #expect(panel.ruleRowNames.count == 4)
    }

    @Test func recencyNeverFallsBelowOneMinute() {
        let panel = TidySettingsPanel()
        var reported: [Int] = []
        panel.onRecencyChanged = { reported.append($0) }
        panel.render(state: .fixture())

        panel.setRecencyMinutes(0)
        panel.setRecencyMinutes(-30)
        panel.setRecencyMinutes(12)

        #expect(reported == [1, 1, 12])
        #expect(panel.recencyMinutes == 12)
    }

    @Test func idleMinutesNeverFallBelowOneMinute() {
        let panel = TidySettingsPanel()
        var reported: [Int] = []
        panel.onIdleMinutesChanged = { reported.append($0) }
        panel.render(state: .fixture())

        panel.setIdleMinutes(0)
        panel.setIdleMinutes(20)

        #expect(reported == [1, 20])
        #expect(panel.idleMinutes == 20)
    }

    @Test func idleStaysUnavailableUntilOneManualPassHasSucceeded() {
        let panel = TidySettingsPanel()

        panel.render(state: .fixture(needsPreview: true, completedManualPass: false))
        #expect(panel.idleIsAvailable == false)

        panel.render(state: .fixture(needsPreview: false, completedManualPass: false))
        #expect(panel.idleIsAvailable == false)

        panel.render(state: .fixture(needsPreview: false, completedManualPass: true))
        #expect(panel.idleIsAvailable)
    }

    @Test func idleCannotBeSwitchedOnWhileItIsUnavailable() {
        let panel = TidySettingsPanel()
        var reported: [Bool] = []
        panel.onIdleChanged = { reported.append($0) }
        panel.render(state: .fixture(needsPreview: true, completedManualPass: false))

        panel.setIdleEnabled(true)

        #expect(reported.isEmpty)
        #expect(panel.idleIsEnabled == false)
    }

    @Test func overviewShowsTheChosenFolderAndOffersToForgetIt() {
        let panel = TidySettingsPanel()
        var forgetRequests = 0
        var chooseRequests = 0
        panel.onForgetFolder = { forgetRequests += 1 }
        panel.onChooseFolder = { chooseRequests += 1 }

        panel.render(state: .fixture(folder: nil))
        #expect(panel.folderSummary == "No folder chosen yet.")
        #expect(panel.canForgetFolder == false)

        let folder = URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true)
        panel.render(state: .fixture(folder: folder))
        #expect(panel.folderSummary == "/Users/someone/Desktop")
        #expect(panel.canForgetFolder)

        panel.chooseFolder()
        panel.forgetFolder()
        #expect(chooseRequests == 1)
        #expect(forgetRequests == 1)
    }

    @Test func aBlockingErrorIsShownRatherThanSwallowed() {
        let panel = TidySettingsPanel()
        panel.render(state: .fixture(blockingError: "The selected folder permission must be renewed."))

        #expect(panel.statusText == "The selected folder permission must be renewed.")
    }

    @Test func aPendingPreviewIsAnnouncedOnTheOverview() {
        let panel = TidySettingsPanel()
        panel.render(state: .fixture(needsPreview: true))

        #expect(panel.statusText == "Jumba will show you a preview before anything moves.")
    }
}

@Suite @MainActor struct TidyRuleEditorPanelTests {
    @Test func editingLoadsEveryFieldFromTheRule() {
        let panel = TidyRuleEditorPanel()
        let rule = TidyRule(
            name: "Installers", match: .any,
            conditions: [.extensions(["dmg", "pkg"]), .largerThanMB(2.5)],
            destination: "Installers"
        )

        panel.edit(rule)

        #expect(panel.draft.name == "Installers")
        #expect(panel.draft.match == .any)
        #expect(panel.draft.destination == "Installers")
        #expect(panel.draft.conditions == rule.conditions)
        #expect(panel.conditionFieldText(at: 0) == "dmg, pkg")
        #expect(panel.conditionFieldText(at: 1) == "2.5")
    }

    @Test func theMatchPopupMapsBothWays() {
        let panel = TidyRuleEditorPanel()
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))
        #expect(panel.matchModeTitles == ["All conditions", "Any condition"])
        #expect(panel.selectedMatchTitle == "All conditions")

        panel.setMatchMode(.any)
        #expect(panel.selectedMatchTitle == "Any condition")
        #expect(panel.draft.match == .any)
    }

    @Test func changingAConditionTypeSwapsInThatTypesOwnControl() {
        let panel = TidyRuleEditorPanel()
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        panel.setConditionType(.filenameContains, at: 0)
        panel.setConditionText("invoice", at: 0)
        #expect(panel.draft.conditions == [.filenameContains("invoice")])

        panel.setConditionType(.modifiedMoreThanDays, at: 0)
        panel.setConditionText("30", at: 0)
        #expect(panel.draft.conditions == [.modifiedMoreThanDays(30)])

        panel.setConditionType(.extensions, at: 0)
        panel.setConditionText(" ZIP , .tar ", at: 0)
        #expect(panel.draft.conditions == [.extensions(["zip", "tar"])])
    }

    @Test func kindConditionsUseAPopupOfEveryKind() {
        let panel = TidyRuleEditorPanel()
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        #expect(panel.conditionKindTitles(at: 0) == TidyKind.allCases.map(\.displayName))
        panel.setConditionKind(.archive, at: 0)
        #expect(panel.draft.conditions == [.kind(.archive)])
    }

    @Test func conditionsCanBeAddedAndRemoved() {
        let panel = TidyRuleEditorPanel()
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        panel.addCondition()
        #expect(panel.draft.conditions.count == 2)
        panel.removeCondition(at: 0)
        #expect(panel.draft.conditions.count == 1)
    }

    @Test func savingRejectsAnEmptyConditionList() {
        let panel = TidyRuleEditorPanel()
        var saved: [TidyRule] = []
        panel.onSave = { saved.append($0) }
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        panel.removeCondition(at: 0)
        panel.save()

        #expect(saved.isEmpty)
        #expect(panel.validationMessage == "Add at least one condition.")
    }

    @Test func savingRejectsAnEscapingDestination() {
        let panel = TidyRuleEditorPanel()
        var saved: [TidyRule] = []
        panel.onSave = { saved.append($0) }
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        panel.setDestination("../Outside")
        panel.save()

        #expect(saved.isEmpty)
        #expect(panel.validationMessage
            == "Use one folder name inside the chosen folder — no slashes and no leading dot.")
    }

    @Test func savingRejectsANonPositiveThreshold() {
        let panel = TidyRuleEditorPanel()
        var saved: [TidyRule] = []
        panel.onSave = { saved.append($0) }
        panel.edit(TidyRule(
            name: "Old files", match: .all,
            conditions: [.modifiedMoreThanDays(30)], destination: "Old"
        ))

        panel.setConditionText("0", at: 0)
        panel.save()

        #expect(saved.isEmpty)
        #expect(panel.validationMessage == "Every threshold must be greater than zero.")
    }

    @Test func savingRejectsAnEmptyNameOrText() {
        let panel = TidyRuleEditorPanel()
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        panel.setName("   ")
        panel.save()
        #expect(panel.validationMessage == "Give the rule a name.")
    }

    @Test func aValidRuleSavesWithItsIdentityIntact() {
        let panel = TidyRuleEditorPanel()
        var saved: [TidyRule] = []
        panel.onSave = { saved.append($0) }
        let rule = TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        )
        panel.edit(rule)

        panel.setDestination("Pictures")
        panel.save()

        #expect(saved.count == 1)
        #expect(saved.first?.id == rule.id)
        #expect(saved.first?.destination == "Pictures")
        #expect(panel.validationMessage == nil)
    }

    @Test func cancellingReportsWithoutSaving() {
        let panel = TidyRuleEditorPanel()
        var cancels = 0
        var saved: [TidyRule] = []
        panel.onCancel = { cancels += 1 }
        panel.onSave = { saved.append($0) }
        panel.edit(TidyRule(
            name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"
        ))

        panel.cancel()

        #expect(cancels == 1)
        #expect(saved.isEmpty)
    }
}

@Suite @MainActor struct TidyPreviewPanelTests {
    @Test func previewConfirmationReturnsOnlyCheckedRows() {
        let plan = TidyPlan.fixture(moveCount: 3)
        let panel = TidyPreviewPanel()
        var confirmed: Set<UUID>?
        panel.onConfirm = { confirmed = $0 }
        panel.show(plan: plan)
        panel.setSelected(false, for: plan.movable[1].id)
        panel.confirmForTesting()

        #expect(confirmed == [plan.movable[0].id, plan.movable[2].id])
    }

    @Test func everyMovableRowStartsChecked() {
        let plan = TidyPlan.fixture(moveCount: 4)
        let panel = TidyPreviewPanel()
        panel.show(plan: plan)

        #expect(panel.selectedIDs == Set(plan.movable.map(\.id)))
    }

    @Test func rowsSpellOutBothFullPathsForVoiceOver() {
        let plan = TidyPlan.fixture(moveCount: 1)
        let move = plan.movable[0]
        let panel = TidyPreviewPanel()
        panel.show(plan: plan)

        let label = panel.rowAccessibilityLabels.first
        #expect(label == "Move \(move.source.path) to \(move.destination.path)")
        #expect(panel.sourcePathTexts == [move.source.path])
        #expect(panel.destinationPathTexts == [move.destination.path])
    }

    @Test func skippedRowsExplainThemselvesAndCannotBeChosen() {
        let root = URL(fileURLWithPath: "/tmp/JumbiniPreview", isDirectory: true)
        let skipped = [
            TidySkippedItem(id: UUID(), source: root.appendingPathComponent("fresh.png"), reason: .recent),
            TidySkippedItem(id: UUID(), source: root.appendingPathComponent("link"), reason: .symbolicLink),
            TidySkippedItem(id: UUID(), source: root.appendingPathComponent("notes.xyz"), reason: .unmatched),
            TidySkippedItem(id: UUID(), source: root.appendingPathComponent("open.key"), reason: .openByAnotherProcess),
        ]
        let panel = TidyPreviewPanel()
        var confirmed: Set<UUID>?
        panel.onConfirm = { confirmed = $0 }
        panel.show(plan: TidyPlan(root: root, movable: [], skipped: skipped))

        #expect(panel.skipReasonTexts == [
            "Changed too recently",
            "Symbolic link",
            "No rule matched",
            "Open in another app",
        ])
        panel.setSelected(true, for: skipped[0].id)
        panel.confirmForTesting()
        #expect(confirmed == [])
    }

    @Test func aPlanOverTheCapSaysExactlyWhereJumbaStops() {
        let panel = TidyPreviewPanel()

        panel.show(plan: .fixture(moveCount: TidySafety.maximumMoves))
        #expect(panel.capMessage == nil)

        panel.show(plan: .fixture(moveCount: TidySafety.maximumMoves + 1))
        #expect(panel.capMessage == "Jumba will stop after 50 files for safety.")
    }

    @Test func anEmptyPlanSaysSoAndCannotBeConfirmed() {
        let panel = TidyPreviewPanel()
        panel.show(plan: TidyPlan(
            root: URL(fileURLWithPath: "/tmp/JumbiniPreview", isDirectory: true),
            movable: [], skipped: []
        ))

        #expect(panel.summaryText == "Nothing to tidy in this folder.")
        #expect(panel.canConfirm == false)
    }

    @Test func unticking_everyRowLeavesNothingToConfirm() {
        let plan = TidyPlan.fixture(moveCount: 2)
        let panel = TidyPreviewPanel()
        panel.show(plan: plan)

        for move in plan.movable {
            panel.setSelected(false, for: move.id)
        }

        #expect(panel.canConfirm == false)
        #expect(panel.summaryText == "2 files ready to move · 0 selected")
    }

    @Test func cancellingReportsAndMovesNothing() {
        let plan = TidyPlan.fixture(moveCount: 2)
        let panel = TidyPreviewPanel()
        var cancels = 0
        var confirmed: Set<UUID>?
        panel.onCancel = { cancels += 1 }
        panel.onConfirm = { confirmed = $0 }
        panel.show(plan: plan)

        panel.cancelForTesting()

        #expect(cancels == 1)
        #expect(confirmed == nil)
    }

    @Test func showingASecondPlanForgetsTheFirst() {
        let panel = TidyPreviewPanel()
        let first = TidyPlan.fixture(moveCount: 3)
        panel.show(plan: first)
        panel.setSelected(false, for: first.movable[0].id)

        let second = TidyPlan.fixture(moveCount: 2)
        panel.show(plan: second)

        #expect(panel.selectedIDs == Set(second.movable.map(\.id)))
        #expect(panel.rowAccessibilityLabels.count == 2)
    }
}

extension TidyCoordinator.State {
    static func fixture(
        folder: URL? = URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true),
        rules: TidyRuleSet = .defaults,
        needsPreview: Bool = false,
        completedManualPass: Bool = true,
        idleEnabled: Bool = false,
        blockingError: String? = nil
    ) -> TidyCoordinator.State {
        TidyCoordinator.State(
            folder: folder,
            rules: rules,
            preferences: TidyPreferences(
                needsPreview: needsPreview,
                recencyMinutes: 5,
                idleEnabled: idleEnabled,
                idleMinutes: 10,
                completedManualPass: completedManualPass
            ),
            isRunning: false,
            undoCount: 0,
            blockingError: blockingError
        )
    }
}
