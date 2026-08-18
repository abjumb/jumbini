import Foundation
import Testing
@testable import Jumbini

@Test func everySignalHeActsOnSaysSomething() {
    for signal in SystemSignal.allCases {
        let caption = ReactionCaption.text(for: signal, acted: true)
        #expect(caption?.isEmpty == false, "\(signal) acted on but said nothing")
    }
}

@Test func theCaptionsAreTheOnesTheDesignAgreed() {
    #expect(ReactionCaption.text(for: .buildFinished, acted: true) == "Build's done!")
    #expect(ReactionCaption.text(for: .fansUp, acted: true) == "Your Mac's hot!")
    #expect(ReactionCaption.text(for: .batteryLow, acted: true) == "Battery's low…")
    #expect(ReactionCaption.text(for: .dndOn, acted: true) == "Focus on. Shh.")
    #expect(ReactionCaption.text(for: .idleBegan, acted: true) == "You've been gone a while…")
    #expect(ReactionCaption.text(for: .idleEnded, acted: true) == "You're back!")
    #expect(ReactionCaption.text(for: .batteryNormal, acted: true) == "Charging again!")
    #expect(ReactionCaption.text(for: .dndOff, acted: true) == "Focus off!")
}

@Test func newsHeWasTooBusyForSaysSoInsteadOfNothing() {
    // The brain parks these (deferSignal) and comes back to them. Saying so
    // beats leaving the user wondering why nothing happened.
    for signal in [SystemSignal.buildFinished, .fansUp, .batteryLow, .dndOn, .idleBegan] {
        #expect(ReactionCaption.text(for: signal, acted: false) == "Busy — one sec!", "\(signal)")
    }
}

@Test func theAllClearSignalsStaySilentUnlessTheyRousedHim() {
    // Preserves today's behavior: the charger going in is not news unless it
    // actually got him up.
    for signal in [SystemSignal.idleEnded, .batteryNormal, .dndOff] {
        #expect(ReactionCaption.text(for: signal, acted: false) == nil, "\(signal)")
    }
}

@Test func aLongerLineStaysUpLonger() {
    let short = SpeechBubble.hold(for: "You're back!")
    let long = SpeechBubble.hold(for: "You've been gone a while…")

    #expect(long > short, "a longer caption needs longer to read")
    #expect(short >= 1.4, "even the shortest line gets a beat")
}

@Test func theHoldIsCapped() {
    let epic = String(repeating: "a", count: 500)

    #expect(SpeechBubble.hold(for: epic) == 3.2, "he is not writing an essay")
}

@Test @MainActor func theBubbleBuildsAndCarriesItsText() {
    let bubble = SpeechBubble(text: "Build's done!")

    // `plateWidth`, not `calculateAccumulatedFrame()`: the node is still at
    // its 0.6 pop-in scale right after `init`, and the accumulated frame
    // would report 60% of the real size — see `SpeechBubble.plateWidth`.
    #expect(bubble.plateWidth > 0)
    // +2 for the 1pt stroke on each side of the plate.
    #expect(bubble.plateWidth <= SpeechBubble.maxWidth + 2)
}

@Test @MainActor func aLongerCaptionMakesAWiderPlateUpToTheCap() {
    // The old version of this test measured `calculateAccumulatedFrame()`
    // right after `init`, while the bubble is still at its 0.6 pop-in scale —
    // so a plate up to 303pt wide would still have measured under its
    // threshold. `plateWidth` is the real, unscaled width, so this is a
    // check that can actually fail: a bubble sized to a fixed width
    // regardless of its text (or scaled wrong some other way) would trip
    // the first assertion below.
    let short = SpeechBubble(text: "Hi!")
    let long = SpeechBubble(text: "You've been gone a while…")

    #expect(long.plateWidth > short.plateWidth,
            "the plate is sized to the text, not a fixed width")
    // Even the longest real caption in `ReactionCaption` stays inside the
    // cap. `maxWidth - padX * 2` is also `SKLabelNode.preferredMaxLayoutWidth`
    // (set in `init`), so the label itself already keeps `textSize.width`
    // from exceeding it — the `min(...)` around `width` is a second,
    // deliberately redundant guard for the day either of those two numbers
    // drifts out of sync.
    #expect(long.plateWidth <= SpeechBubble.maxWidth + 2)
}
