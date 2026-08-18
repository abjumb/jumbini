import Foundation

/// What the user reads when a tidy fails.
///
/// This is the only place that turns a Tidy error into a sentence. It used to be
/// three places, and they disagreed: `AppDelegate` held a polished mapping the
/// manual paths used, the coordinator published `String(describing:)` straight to
/// the popover on the idle path, and a third `String(describing:)` reached the
/// Settings panel's status label — where it stays on screen in red rather than
/// fading. So one withdrawn folder grant could say "macOS withdrew access to that
/// folder. Choose it again." in one place, "Jumba stopped: staleBookmark" in
/// another, and "The selected folder permission must be renewed." in a third.
///
/// The switches below are exhaustive on purpose. The mapping this replaces was a
/// chain of `as?` casts, which has no exhaustiveness at all — that is exactly how
/// all four `TidyExecutionError` cases went without any wording and surfaced as
/// "The operation couldn't be completed. (Jumbini.TidyExecutionError error 3.)".
/// Add a case to any of these three enums now and this file stops compiling.
enum TidyFailureText {
    /// The sentence for `error`, whatever kind it is.
    static func message(for error: Error) -> String {
        if let coordinatorError = error as? TidyCoordinatorError {
            return message(for: coordinatorError)
        }
        if let undoError = error as? TidyUndoError {
            return message(for: undoError)
        }
        if let executionError = error as? TidyExecutionError {
            return message(for: executionError)
        }
        // Anything from outside Tidy — FileManager and friends. For a real
        // NSError this is genuinely the better text, and the case that made it
        // look bad (TidyExecutionError falling through) is handled above now.
        return (error as NSError).localizedDescription
    }

    /// Every one of these is something the user can act on, so none is worth an
    /// alert — they go in the same popover the results do.
    static func message(for error: TidyCoordinatorError) -> String {
        switch error {
        case .folderRequired:
            return "Choose a folder for Jumba to tidy first."
        case .previewRequired:
            return "Take a look at the preview before Jumba moves anything."
        case .staleBookmark:
            return "macOS withdrew access to that folder. Choose it again."
        case .recoveryBlocked(let detail):
            // Still a raw description today. Giving TidyRecoveryError its own
            // wording is a separate change; see the note on `handleOperationError`.
            return detail
        }
    }

    static func message(for error: TidyUndoError) -> String {
        switch error {
        case .unavailable:
            return "There is nothing left to undo."
        case .sourceOccupied(let url):
            return "Something else is at \(url.lastPathComponent) now, so Jumba put nothing back."
        case .destinationChanged(let url):
            return "\(url.lastPathComponent) changed since the tidy, so Jumba put nothing back."
        case .rollbackFailed(let detail):
            return detail
        }
    }

    /// These describe the PASS, not the file: every one of them is a safety guard
    /// that aborts the whole run rather than risk a wrong move, so "Jumba stopped"
    /// is what actually happened. Reading them as per-file skips would be a lie —
    /// the files after this one were never considered.
    static func message(for error: TidyExecutionError) -> String {
        switch error {
        case .unsafeRoot:
            return "That folder isn't somewhere Jumba can tidy safely."
        case .pathOutsideRoot(let url):
            return "\(url.lastPathComponent) leads outside the folder you chose, so Jumba stopped."
        case .identityUnavailable(let url):
            return "\(url.lastPathComponent) changed since the preview, so Jumba stopped."
        case .deviceMismatch(let source, _):
            return "\(source.lastPathComponent) would have to move to a different disk, so Jumba stopped."
        }
    }
}
