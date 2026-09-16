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
        XCTAssertEqual(timer, .idle)
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

        XCTAssertEqual(payload["phase"] as? String, "running")
        XCTAssertEqual(payload["sessionType"] as? String, "focus")
        XCTAssertEqual(payload["remainingMs"] as? Int, twentyFive - 60_000)
        XCTAssertEqual(payload["deviceId"] as? String, "iphone")
        XCTAssertEqual(payload["category"] as? String, "deep")
    }

    func testMirrorReportsTheReflectPosterAsIdle() {
        // The poster is this app's own state; to every other device the timer
        // has simply stopped.
        var timer = running()
        timer.phase = .reflect
        XCTAssertEqual(timer.mirrorPayload(now: t0, deviceId: "iphone")["phase"] as? String, "idle")
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
}
