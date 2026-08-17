import Foundation
import Testing
@testable import Jumbini

// What the Tidy submenu offers, decided without AppKit.
//
// The menu is where someone starts a pass, undoes one, or revokes the folder
// grant, so which of those are *available* is policy, not presentation: an
// enabled "Undo Last Tidy" after the undo was consumed would offer to move files
// back that are already back.

@Suite struct TidyMenuTests {
    @Test func unconfiguredMenuOffersSetupWithoutUndo() {
        let menu = TidyMenuState(
            folderConfigured: false, undoCount: 0,
            idleEnabled: false, idleAvailable: false
        )
        #expect(menu.primaryTitle == "Set Up Tidy…")
        #expect(menu.canUndo == false)
        #expect(menu.canForgetFolder == false)
    }

    @Test func configuredMenuShowsUndoCount() {
        let menu = TidyMenuState(
            folderConfigured: true, undoCount: 12,
            idleEnabled: false, idleAvailable: true
        )
        #expect(menu.primaryTitle == "Tidy Up…")
        #expect(menu.undoTitle == "Undo Last Tidy (12)")
    }

    @Test func undoWithoutAPassIsNamedPlainlyAndDisabled() {
        let menu = TidyMenuState(
            folderConfigured: true, undoCount: 0,
            idleEnabled: false, idleAvailable: true
        )
        #expect(menu.undoTitle == "Undo Last Tidy")
        #expect(menu.canUndo == false)
        #expect(menu.canForgetFolder)
    }

    @Test func idleIsCheckedOnlyWhenItIsBothAvailableAndOn() {
        let unavailable = TidyMenuState(
            folderConfigured: true, undoCount: 0,
            idleEnabled: true, idleAvailable: false
        )
        #expect(unavailable.idleIsChecked == false)
        #expect(unavailable.canToggleIdle == false)

        let on = TidyMenuState(
            folderConfigured: true, undoCount: 0,
            idleEnabled: true, idleAvailable: true
        )
        #expect(on.idleIsChecked)
        #expect(on.canToggleIdle)
    }

    @Test func aRunningPassLocksTheActionsThatWouldCollideWithIt() {
        let menu = TidyMenuState(
            folderConfigured: true, undoCount: 4,
            idleEnabled: false, idleAvailable: true, isRunning: true
        )
        #expect(menu.canTidy == false)
        #expect(menu.canUndo == false)
        #expect(menu.canForgetFolder == false)
    }

    @Test func anIdlePassCanAlwaysBeStartedOrSetUp() {
        #expect(TidyMenuState(
            folderConfigured: false, undoCount: 0,
            idleEnabled: false, idleAvailable: false
        ).canTidy)
        #expect(TidyMenuState(
            folderConfigured: true, undoCount: 0,
            idleEnabled: false, idleAvailable: true
        ).canTidy)
    }

    @Test func coordinatorStateMapsStraightOntoTheMenu() {
        let state = TidyCoordinator.State(
            folder: URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true),
            rules: .defaults,
            preferences: TidyPreferences(
                needsPreview: false, recencyMinutes: 5, idleEnabled: true,
                idleMinutes: 10, completedManualPass: true
            ),
            isRunning: false,
            undoCount: 3,
            blockingError: nil
        )

        let menu = TidyMenuState(state: state)

        #expect(menu.primaryTitle == "Tidy Up…")
        #expect(menu.undoTitle == "Undo Last Tidy (3)")
        #expect(menu.canUndo)
        #expect(menu.canForgetFolder)
        #expect(menu.idleIsChecked)
    }

    /// A stale bookmark leaves rules and history intact but no usable folder, so
    /// the menu has to go back to offering setup rather than offering to tidy a
    /// folder Tidy can no longer reach.
    @Test func aBlockedCoordinatorFallsBackToSetup() {
        let state = TidyCoordinator.State(
            folder: nil,
            rules: .defaults,
            preferences: TidyPreferences(
                needsPreview: true, recencyMinutes: 5, idleEnabled: false,
                idleMinutes: 10, completedManualPass: true
            ),
            isRunning: false,
            undoCount: 2,
            blockingError: "The selected folder permission must be renewed."
        )

        let menu = TidyMenuState(state: state)

        #expect(menu.primaryTitle == "Set Up Tidy…")
        #expect(menu.canUndo == false)
        #expect(menu.canForgetFolder == false)
        #expect(menu.canToggleIdle == false)
    }
}
