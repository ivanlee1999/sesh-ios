import XCTest
@testable import SeshCore

/**
 The timer is the one thing that must survive the app being asleep, killed or
 offline, so these tests never advance a clock by ticking — they ask the state
 what it reads at an instant, which is exactly what the app does after being
 woken up an hour later.
 */
final class TimerStateTests: XCTestCase {
    let t0: Millis = 1_700_000_000_000
    let twentyFive = 25 * 60 * 1000

    private func running() -> TimerState {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Write the plan", category: "deep", targetMs: twentyFive, now: t0)
        return timer
    }

    func testRemainingIsDerivedFromTheClock() {
        let timer = running()
        XCTAssertEqual(timer.remainingMs(now: t0), twentyFive)
        XCTAssertEqual(timer.remainingMs(now: t0 + 60_000), twentyFive - 60_000)
    }

    func testSurvivesBeingAsleepForTheWholeSession() {
        // Nothing ticked in between; the answer still has to be right.
        let timer = running()
        XCTAssertEqual(timer.remainingMs(now: t0 + Millis(twentyFive)), 0)
        XCTAssertFalse(timer.isOvertime(now: t0 + Millis(twentyFive)))
    }

    func testRunsIntoOvertimeRatherThanStopping() {
        let timer = running()
        let later = t0 + Millis(twentyFive) + 90_000
        XCTAssertEqual(timer.remainingMs(now: later), -90_000)
        XCTAssertTrue(timer.isOvertime(now: later))
    }

    func testPauseHoldsTheRemainingTimeStill() {
        var timer = running()
        timer.pause(now: t0 + 60_000)
        let atPause = timer.remainingMs(now: t0 + 60_000)

        // Ten minutes pass with the timer paused; the dial must not have moved.
        XCTAssertEqual(timer.remainingMs(now: t0 + 660_000), atPause)
    }

    func testResumeContinuesFromWhereItStopped() {
        var timer = running()
        timer.pause(now: t0 + 60_000)
        timer.resume(now: t0 + 660_000)   // paused for ten minutes

        XCTAssertEqual(timer.phase, .running)
        XCTAssertNil(timer.pausedAt)
        // One minute was served before the pause; a further minute after it.
        XCTAssertEqual(timer.remainingMs(now: t0 + 720_000), twentyFive - 120_000)
    }

    func testPauseAndResumeAreIgnoredInTheWrongPhase() {
        var idle = TimerState()
        idle.pause(now: t0)
        XCTAssertEqual(idle.phase, .idle)

        var timer = running()
        timer.resume(now: t0 + 1_000)
        XCTAssertEqual(timer.phase, .running)
    }

    func testNaturalFinishCreditsAtLeastTheTarget() {
        // Coming back a moment late must not shorten a session that was served.
        let timer = running()
        let session = timer.draftSession(now: t0 + Millis(twentyFive) - 500, manual: false)
        XCTAssertEqual(session?.actualMs, twentyFive)
        XCTAssertEqual(session?.overflowMs, 0)
    }

    func testManualFinishCreditsAtLeastAMinute() {
        let timer = running()
        let session = timer.draftSession(now: t0 + 5_000, manual: true)
        XCTAssertEqual(session?.actualMs, 60_000)
    }

    func testOvertimeShowsUpAsOverflow() {
        let timer = running()
        let session = timer.draftSession(now: t0 + Millis(twentyFive) + 300_000, manual: true)
        XCTAssertEqual(session?.actualMs, twentyFive + 300_000)
        XCTAssertEqual(session?.overflowMs, 300_000)
    }

    func testSessionIdIsDerivedFromTheStart() {
        // The whole offline story rests on this: the server would give the same
        // id, so a session pushed later merges instead of duplicating.
        let timer = running()
        XCTAssertEqual(timer.draftSession(now: t0 + 60_000, manual: true)?.id, "manual-\(t0)")
        XCTAssertEqual(Session.id(startedAt: t0), "manual-\(t0)")
    }

    func testAnIdleTimerHasNoSessionToDraft() {
        XCTAssertNil(TimerState().draftSession(now: t0, manual: true))
    }

    func testChangingTheTopicDropsTheLinkedTasks() {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Review PR", category: "deep", targetMs: twentyFive, taskRefs: "things:abc", now: t0)
        timer.changeTopic("Something else entirely")

        XCTAssertNil(timer.taskRefs)
        XCTAssertEqual(timer.intention, "Something else entirely")
    }

    func testAbandonLeavesNothingBehind() {
        var timer = running()
        timer.abandon()
        XCTAssertTrue(timer.sameSessionState(as: .idle))
        XCTAssertEqual(timer.controlSessionStart, t0, "The conditional stop must identify the sitting it retired.")
        XCTAssertNil(timer.startedAt)
    }

    func testRestoresExactlyFromDisk() throws {
        var timer = running()
        timer.pause(now: t0 + 60_000)

        let data = try JSONEncoder().encode(timer)
        let restored = try JSONDecoder().decode(TimerState.self, from: data)

        XCTAssertEqual(restored, timer)
        XCTAssertEqual(restored.remainingMs(now: t0 + 900_000), timer.remainingMs(now: t0 + 900_000))
    }

    func testMirrorSpeaksTheServersDialect() {
        // The server stores a remaining figure plus the moment it was written,
        // and browsers rebuild the countdown from those two.
        let timer = running()
        let payload = timer.mirrorPayload(now: t0 + 60_000, deviceId: "iphone")

        XCTAssertEqual(payload["phase"]?.stringValue, "running")
        XCTAssertEqual(payload["sessionType"]?.stringValue, "focus")
        XCTAssertEqual(payload["remainingMs"]?.intValue, twentyFive - 60_000)
        XCTAssertEqual(payload["deviceId"]?.stringValue, "iphone")
        XCTAssertEqual(payload["category"]?.stringValue, "deep")
        XCTAssertEqual(payload["startedAt"]?.intValue, Int(t0))
    }

    func testMirrorSendsAbsentValuesAsNull() {
        // An idle timer has no start and no linked tasks, and the server has to
        // be told so explicitly — a key quietly missing would leave whatever it
        // held before in place.
        let payload = TimerState.idle.mirrorPayload(now: t0, deviceId: "iphone")
        XCTAssertEqual(payload["startedAt"], .null)
        XCTAssertEqual(payload["pausedAt"], .null)
        XCTAssertEqual(payload["todoistTaskId"], .null)
    }

    func testMirrorCarriesTheLinkedTasks() {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Review", category: "deep",
                    targetMs: twentyFive, taskRefs: "things:abc,123", now: t0)
        XCTAssertEqual(timer.mirrorPayload(now: t0, deviceId: "iphone")["todoistTaskId"]?.stringValue, "things:abc,123")
    }

    func testMirrorReportsReflectionAsPaused() {
        // The poster is this app's own state; to every other device the timer
        // has simply stopped.
        var timer = running()
        timer.beginReflection(now: t0 + 60_000, manual: true)
        XCTAssertEqual(timer.mirrorPayload(now: t0, deviceId: "iphone")["phase"]?.stringValue, "paused")
    }

    func testMirrorEncodesAsTheServerExpects() throws {
        // It has to survive JSON encoding as a plain object, because that is
        // what it becomes inside a sync op.
        let timer = running()
        let data = try JSONEncoder().encode(timer.mirrorPayload(now: t0, deviceId: "iphone"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["phase"] as? String, "running")
        XCTAssertEqual(json["targetMs"] as? Int, twentyFive)
        XCTAssertTrue(json["pausedAt"] is NSNull)
    }

    func testTargetDateIsWhereTheNotificationGoes() {
        let timer = running()
        let target = try? XCTUnwrap(timer.targetDate(now: t0))
        XCTAssertEqual(target?.timeIntervalSince1970 ?? 0, Double(t0 + Millis(twentyFive)) / 1000, accuracy: 0.001)
        XCTAssertNil(TimerState().targetDate(now: t0))
    }

    func testBreakSessionsKeepTheirKind() {
        var timer = TimerState()
        timer.start(kind: .rest, intention: "", category: "deep", targetMs: 5 * 60 * 1000, now: t0)
        XCTAssertEqual(timer.draftSession(now: t0 + 300_000, manual: false)?.type, .rest)
        // The wire spells it "break"; Swift cannot.
        XCTAssertEqual(SessionKind.rest.rawValue, "break")
    }
    func testReflectionFreezesAtPauseAndSurvivesDisk() throws {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Plan", category: "deep", targetMs: 1_500_000, now: t0)
        timer.pause(now: t0 + 120_000)
        timer.beginReflection(now: t0 + 900_000, manual: true)
        XCTAssertEqual(timer.reflection?.endedAt, t0 + 120_000)
        XCTAssertEqual(timer.reflection?.actualMs, 120_000)
        let restored = try JSONDecoder().decode(TimerState.self, from: JSONEncoder().encode(timer))
        XCTAssertEqual(restored, timer)
        timer.beginReflection(now: t0 + 1_000_000, manual: true)
        XCTAssertEqual(timer.reflection, restored.reflection)
        timer.returnFromReflection()
        XCTAssertEqual(timer.phase, .paused)
        timer.resume(now: t0 + 1_200_000)
        XCTAssertEqual(timer.elapsedMs(now: t0 + 1_260_000), 180_000)
    }

    func testUnchangedTopicKeepsTaskLinks() {
        var timer = TimerState(intention: "Plan", taskRefs: "things:one")
        timer.changeTopic("Plan")
        XCTAssertEqual(timer.taskRefs, "things:one")
    }

    func testBackAndFinishRetainsEditsAndRecomputesTheBoundary() throws {
        var timer = running()
        timer.beginReflection(now: t0 + 120_000, manual: true)
        timer.reflection?.notes = "Keep this thought"
        timer.reflection?.rating = 3
        timer.reflection?.intention = "Revised topic"
        timer.reflection?.todoistTaskId = "things:new"
        let id = timer.reflection?.id
        timer.returnFromReflection()
        XCTAssertNil(timer.reflection)
        XCTAssertEqual(timer.phase, .paused)
        timer = try JSONDecoder().decode(TimerState.self, from: JSONEncoder().encode(timer))
        timer.resume(now: t0 + 180_000)
        timer.beginReflection(now: t0 + 240_000, manual: true)
        XCTAssertEqual(timer.reflection?.id, id)
        XCTAssertEqual(timer.reflection?.notes, "Keep this thought")
        XCTAssertEqual(timer.reflection?.rating, 3)
        XCTAssertEqual(timer.reflection?.intention, "Revised topic")
        XCTAssertEqual(timer.reflection?.todoistTaskId, "things:new")
        XCTAssertEqual(timer.reflection?.endedAt, t0 + 240_000)
        XCTAssertEqual(timer.elapsedMs(now: t0 + 600_000), 180_000)
    }

    func testAutoStartBreakKeepsFocusDraftWithoutExtendingItsTime() throws {
        var timer = running()
        timer.beginReflection(now: t0 + 120_000, manual: true, breakTargetMs: 300_000)
        XCTAssertEqual(timer.phase, .running)
        XCTAssertEqual(timer.kind, .rest)
        XCTAssertEqual(timer.startedAt, t0 + 120_000)
        XCTAssertEqual(timer.reflection?.type, .focus)
        XCTAssertEqual(timer.reflection?.endedAt, t0 + 120_000)
        timer.beginReflection(now: t0 + 180_000, manual: true)
        XCTAssertEqual(timer.reflection?.actualMs, 120_000)
        let restored = try JSONDecoder().decode(TimerState.self, from: JSONEncoder().encode(timer))
        XCTAssertEqual(restored, timer)
    }

    func testBuildOneTimerDecodesWithoutDraftFields() throws {
        let data = try JSONEncoder().encode(running())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "reflection")
        json.removeValue(forKey: "retainedReflection")
        let restored = try JSONDecoder().decode(TimerState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.reflection)
        XCTAssertNil(restored.retainedReflection)
        XCTAssertEqual(restored.phase, .running)
    }

}
