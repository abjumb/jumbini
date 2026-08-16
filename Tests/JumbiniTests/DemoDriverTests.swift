import Testing
import Foundation
import CoreGraphics
@testable import Jumbini

// The DemoDriver class owns a Timer and a scene, so it can't run in a test
// process. Its decisions can: parsing a script and deciding which beats are
// due are both pure and clock-injected, which is what these cover.

// MARK: - Timeline

private func script(_ beats: [DemoBeat]) -> DemoScript {
    DemoScript(name: "t", duration: 10, showCursor: false, beats: beats)
}

@Test func timelineReleasesNothingBeforeTheFirstBeat() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .system(.fansUp)),
    ]))
    #expect(timeline.due(at: 0.0).isEmpty)
    #expect(timeline.due(at: 0.99).isEmpty)
}

@Test func timelineReleasesABeatOnceItsTimeArrives() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .system(.fansUp)),
    ]))
    #expect(timeline.due(at: 1.0) == [DemoBeat(at: 1.0, action: .system(.fansUp))])
}

@Test func timelineNeverReleasesTheSameBeatTwice() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .system(.fansUp)),
    ]))
    #expect(timeline.due(at: 1.5).count == 1)
    #expect(timeline.due(at: 2.0).isEmpty)
}

// A dropped frame or a slow launch means one tick can straddle several beats.
// They must all come out, in order, rather than the late ones being skipped.
@Test func timelineCatchesUpOnEveryBeatAStallSkippedOver() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .command(.sit)),
        DemoBeat(at: 2.0, action: .command(.spin)),
        DemoBeat(at: 3.0, action: .command(.zoomies)),
    ]))
    let due = timeline.due(at: 5.0)
    #expect(due.map(\.action) == [.command(.sit), .command(.spin), .command(.zoomies)])
}

@Test func timelineSortsBeatsThatArriveOutOfOrder() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 3.0, action: .command(.zoomies)),
        DemoBeat(at: 1.0, action: .command(.sit)),
    ]))
    #expect(timeline.due(at: 5.0).map(\.action) == [.command(.sit), .command(.zoomies)])
}

@Test func timelineIsFinishedOnlyAfterTheLastBeatIsOut() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .command(.sit)),
    ]))
    #expect(!timeline.isFinished)
    _ = timeline.due(at: 1.0)
    #expect(timeline.isFinished)
}

// MARK: - Parsing

@Test func parsesASystemBeat() throws {
    let json = """
    {"name":"thermal","duration":8.0,"showCursor":false,
     "beats":[{"at":0.5,"kind":"system","signal":"fansUp"}]}
    """
    let parsed = try DemoScript(json: Data(json.utf8))
    #expect(parsed.name == "thermal")
    #expect(parsed.duration == 8.0)
    #expect(parsed.showCursor == false)
    #expect(parsed.beats == [DemoBeat(at: 0.5, action: .system(.fansUp))])
}

@Test func parsesEveryPlainCommand() throws {
    let names = ["sit", "lieDown", "spin", "fetch", "spinForever", "zoomies", "relax"]
    let expected: [DogCommand] = [.sit, .lieDown, .spin, .fetch, .spinForever, .zoomies, .relax]
    for (name, command) in zip(names, expected) {
        let json = """
        {"name":"t","duration":1,"showCursor":false,
         "beats":[{"at":0,"kind":"command","command":"\(name)"}]}
        """
        let parsed = try DemoScript(json: Data(json.utf8))
        #expect(parsed.beats.first?.action == .command(command))
    }
}

@Test func parsesTricksAndToysByTheirQualifiedNames() throws {
    let json = """
    {"name":"t","duration":1,"showCursor":false,"beats":[
      {"at":0,"kind":"command","command":"trick:Shake"},
      {"at":1,"kind":"command","command":"toy:frisbee"}
    ]}
    """
    let parsed = try DemoScript(json: Data(json.utf8))
    #expect(parsed.beats.map(\.action) == [.command(.trick(.shake)), .command(.toy(.frisbee))])
}

@Test func parsesACursorBeat() throws {
    let json = """
    {"name":"t","duration":1,"showCursor":true,
     "beats":[{"at":2,"kind":"cursor","x":800,"y":400}]}
    """
    let parsed = try DemoScript(json: Data(json.utf8))
    #expect(parsed.showCursor)
    #expect(parsed.beats.first?.action == .cursor(CGPoint(x: 800, y: 400)))
}

// A typo that silently dropped a beat would surface as a clip where nothing
// happens — after the recording session is over. Fail at parse instead.
@Test func rejectsAnUnknownSignalRatherThanSkippingIt() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"system","signal":"fansUpp"}]}
    """
    #expect(throws: DemoParseError.unknownSignal("fansUpp")) {
        try DemoScript(json: Data(json.utf8))
    }
}

@Test func rejectsAnUnknownCommand() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"command","command":"rollover"}]}
    """
    #expect(throws: DemoParseError.unknownCommand("rollover")) {
        try DemoScript(json: Data(json.utf8))
    }
}

@Test func rejectsAnUnknownTrick() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"command","command":"trick:Backflip"}]}
    """
    #expect(throws: DemoParseError.unknownTrick("Backflip")) {
        try DemoScript(json: Data(json.utf8))
    }
}

@Test func rejectsAnUnknownBeatKind() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"teleport"}]}
    """
    #expect(throws: DemoParseError.unknownKind("teleport")) {
        try DemoScript(json: Data(json.utf8))
    }
}
