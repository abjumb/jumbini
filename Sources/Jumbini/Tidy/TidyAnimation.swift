import CoreGraphics
import Foundation

/// One trip: Jumba trots somewhere plausible, puts something down, comes back.
///
/// A cue stands for one move or for a batch of them. It carries the move it is
/// acting out so the scene can work out where to go, and a duration so the whole
/// performance is bounded before a single `SKAction` is built.
struct TidyAnimationCue: Equatable {
    let moves: [TidyCompletedMove]
    let duration: TimeInterval

    var count: Int { moves.count }
    /// The move the trip is aimed at. A batch borrows the first one's path.
    var anchor: TidyCompletedMove? { moves.first }
}

/// How a finished pass becomes at most four trips.
///
/// Fifty moves as fifty trips would hold the screen for minutes and turn a
/// safety feature into a nuisance, so the first few are acted out one at a time
/// — enough to see what happened — and the rest become a single trip. None of
/// this can affect the filesystem: by the time a cue exists, every file has
/// already moved.
enum TidyAnimationBatcher {
    /// How many moves get their own trip before the rest are lumped together.
    static let individualCount = 3
    /// Hard ceiling for one individual trip.
    static let individualDuration: TimeInterval = 2.5
    /// Hard ceiling for the batched remainder, however many files it stands for.
    static let batchDuration: TimeInterval = 4

    static func cues(
        for moves: [TidyCompletedMove],
        reduceMotion: Bool,
        overlayVisible: Bool
    ) -> [TidyAnimationCue] {
        // Reduce Motion and a hidden or paused overlay both mean "no theatre".
        // Dropping the cues is the whole implementation — nothing downstream is
        // waiting on them, because nothing downstream ever was.
        guard !reduceMotion, overlayVisible, !moves.isEmpty else { return [] }

        let individual = moves.prefix(individualCount).map {
            TidyAnimationCue(moves: [$0], duration: individualDuration)
        }
        let remainder = Array(moves.dropFirst(individualCount))
        guard !remainder.isEmpty else { return individual }
        return individual + [
            TidyAnimationCue(
                moves: remainder,
                duration: min(batchDuration, 2 + Double(remainder.count) * 0.04)
            )
        ]
    }
}

/// Where Jumba trots to carry a file.
///
/// Deliberately not where the file's icon is: reading that would mean either
/// undocumented `.DS_Store` internals or an Accessibility grant, and Tidy asks
/// for neither. A stable hash of the path picks a plausible spot on a real
/// display instead, so the same file always sends him to the same place and the
/// result looks purposeful rather than random.
enum TidyAnimationRegion {
    /// Keeps him clear of the screen edges, where a dog is half off the display.
    static let displayInset: CGFloat = 80

    static func point(for move: TidyCompletedMove, layout: ScreenLayout) -> CGPoint {
        guard !layout.sceneFrames.isEmpty else { return .zero }
        let hash = fnv1a(move.source.path)
        let frame = layout.sceneFrames[Int(hash % UInt64(layout.sceneFrames.count))]

        // A display smaller than the inset would collapse to nothing, so the
        // usable rect never shrinks past its own centre.
        let insetX = min(displayInset, max(0, frame.width / 2 - 1))
        let insetY = min(displayInset, max(0, frame.height / 2 - 1))
        let usable = frame.insetBy(dx: insetX, dy: insetY)

        // Two independent slices of the same hash, so x and y do not march
        // together and put every file on one diagonal.
        let across = Double((hash >> 8) % 1_000) / 1_000
        let up = Double((hash >> 32) % 1_000) / 1_000
        return CGPoint(
            x: usable.minX + usable.width * CGFloat(across),
            y: usable.minY + usable.height * CGFloat(up)
        )
    }

    /// FNV-1a, written out rather than using `hashValue`, which is seeded per
    /// process — the same file would send him somewhere else after a relaunch.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }
}
