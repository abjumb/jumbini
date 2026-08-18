import Foundation
import Testing
@testable import Jumbini

// What the user reads when a tidy fails.
//
// This existed in three places that disagreed, so the tests worth having are the
// ones that pin agreement: every case says something, the sentences a user is
// most likely to hit say the right thing, and a foreign error still falls back to
// the text macOS wrote rather than to a Swift enum dump.

private let file = URL(fileURLWithPath: "/tmp/Tidy/holiday snap.png")
private let folder = URL(fileURLWithPath: "/tmp/Tidy/Images", isDirectory: true)

// MARK: - Nothing is silent

@Test func everyCoordinatorErrorSaysSomething() {
    let cases: [TidyCoordinatorError] = [
        .folderRequired, .previewRequired, .staleBookmark, .recoveryBlocked("a detail"),
    ]
    for error in cases {
        #expect(!TidyFailureText.message(for: error).isEmpty, "\(error) said nothing")
    }
}

@Test func everyUndoErrorSaysSomething() {
    let cases: [TidyUndoError] = [
        .unavailable, .sourceOccupied(file), .destinationChanged(file), .rollbackFailed("a detail"),
    ]
    for error in cases {
        #expect(!TidyFailureText.message(for: error).isEmpty, "\(error) said nothing")
    }
}

@Test func everyExecutionErrorSaysSomething() {
    // These four had no wording at all before this type existed — they reached
    // the user as "The operation couldn't be completed. (Jumbini.
    // TidyExecutionError error 3.)" — so this is the regression that matters.
    let cases: [TidyExecutionError] = [
        .unsafeRoot(folder),
        .pathOutsideRoot(file),
        .identityUnavailable(file),
        .deviceMismatch(source: file, destinationParent: folder),
    ]
    for error in cases {
        let message = TidyFailureText.message(for: error)
        #expect(!message.isEmpty, "\(error) said nothing")
        #expect(!message.contains("Jumbini."), "\(error) leaked a type name: \(message)")
        #expect(!message.contains("error 3"), "\(error) leaked an error code: \(message)")
    }
}

// MARK: - The sentences a user actually hits

@Test func theHighTrafficSentencesAreTheAgreedOnes() {
    #expect(
        TidyFailureText.message(for: TidyCoordinatorError.staleBookmark)
            == "macOS withdrew access to that folder. Choose it again."
    )
    #expect(
        TidyFailureText.message(for: TidyCoordinatorError.previewRequired)
            == "Take a look at the preview before Jumba moves anything."
    )
    #expect(
        TidyFailureText.message(for: TidyExecutionError.deviceMismatch(
            source: file, destinationParent: folder
        )) == "holiday snap.png would have to move to a different disk, so Jumba stopped."
    )
}

@Test func executionFailuresNameTheFileAndSayThePassStopped() {
    // They describe the PASS, not the file: each aborts the whole run, so the
    // files after this one were never considered. Reading them as per-file skips
    // would be a lie.
    for error: TidyExecutionError in [.pathOutsideRoot(file), .identityUnavailable(file)] {
        let message = TidyFailureText.message(for: error)
        #expect(message.hasPrefix("holiday snap.png "), "should lead with the name: \(message)")
        #expect(message.hasSuffix("so Jumba stopped."), "should say the pass stopped: \(message)")
    }
}

// MARK: - Errors from outside Tidy

@Test func aForeignErrorKeepsTheTextMacOSWrote() {
    let foreign = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadNoSuchFileError,
        userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened."]
    )

    #expect(TidyFailureText.message(for: foreign) == "The file couldn’t be opened.")
}

@Test func theSameErrorReadsTheSameWhicheverPathAsks() {
    // The bug that started this: the idle path published String(describing:) and
    // the manual path published the polished mapping, so one withdrawn grant was
    // described two different ways. Both now ask the same question.
    let error: any Error = TidyCoordinatorError.staleBookmark

    #expect(
        TidyFailureText.message(for: error)
            == TidyFailureText.message(for: TidyCoordinatorError.staleBookmark)
    )
    #expect(!TidyFailureText.message(for: error).contains("staleBookmark"))
}

// MARK: - The notice wrapper

@Test func aFailureNoticeCarriesTheSentenceUnwrapped() {
    // `.failed` used to prepend "Jumba stopped: ", which turned an instruction
    // into a non-sequitur and could not work on the Settings panel surface where
    // there is no prefix. `isFailure` replaced it as the bad-news signal.
    let sentence = "Take a look at the preview before Jumba moves anything."
    let notice = TidyNotice.failed(sentence)

    #expect(notice.message == sentence)
    #expect(notice.isFailure)
    #expect(!TidyNotice.completed(moved: 3, skipped: 0, capped: false).isFailure)
    #expect(!TidyNotice.undone(2).isFailure)
    #expect(!TidyNotice.halted(moved: 1).isFailure)
}
