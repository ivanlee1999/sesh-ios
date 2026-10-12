import XCTest
@testable import SeshCore

final class WatchProtocolTests: XCTestCase {
    let start: Millis = 1_000_000
    func command(_ action: WatchCommand.Action, _ offset: Millis = 0) -> WatchCommand {
        .init(action: action, at: start + offset, sessionStart: start, minutes: 1)
    }

    func testOfflineRelaunchPauseAndResumeUseClock() throws {
        var document = WatchDocument()
        try document.perform(command(.start))
        try document.perform(command(.pause, 10_000))
        let data = try JSONEncoder().encode(document)
        document = try JSONDecoder().decode(WatchDocument.self, from: data)
        XCTAssertEqual(document.timer.remainingMs(now: start + 100_000), 50_000)
        try document.perform(command(.resume, 100_000))
        XCTAssertEqual(document.timer.remainingMs(now: start + 110_000), 40_000)
        XCTAssertEqual(document.pending.count, 3)
    }

    func testFinishDoesNotSaveBeforeReflection() throws {
        var timer = TimerState.idle
        var preferences = WatchPreferences()
        _ = try WatchReducer.apply(command(.start), timer: &timer, preferences: &preferences)
        XCTAssertNil(try WatchReducer.apply(command(.finish, 70_000), timer: &timer, preferences: &preferences))
        XCTAssertEqual(timer.kind, .rest)
        XCTAssertNotNil(timer.reflection)
        var edit = command(.editReflection, 71_000); edit.notes = "Kept"; edit.rating = 4
        _ = try WatchReducer.apply(edit, timer: &timer, preferences: &preferences)
        let session = try WatchReducer.apply(command(.save, 72_000), timer: &timer, preferences: &preferences)
        XCTAssertEqual(session?.notes, "Kept")
        XCTAssertEqual(session?.rating, 4)
        XCTAssertEqual(session?.actualMs, 70_000)
        XCTAssertNil(timer.reflection)
        XCTAssertThrowsError(try WatchReducer.apply(command(.save, 73_000), timer: &timer, preferences: &preferences))
    }

    func testTimerTargetIsOvertimeWithoutAutomaticCompletion() throws {
        var document = WatchDocument()
        try document.perform(command(.start))
        XCTAssertEqual(document.timer.phase, .running)
        XCTAssertEqual(document.timer.remainingMs(now: start + 90_000), -30_000)
        XCTAssertNil(document.timer.reflection)
    }

    func testStaleWidgetDesiredActionCannotToggleOrAffectNextSession() throws {
        var document = WatchDocument()
        try document.perform(command(.start))
        try document.perform(command(.pause, 1000))
        XCTAssertThrowsError(try document.perform(command(.pause, 2000)))
        var stale = command(.resume, 3000); stale.sessionStart = start - 1
        XCTAssertThrowsError(try document.perform(stale))
        XCTAssertEqual(document.timer.phase, .paused)
    }

    func testDelayedSnapshotCannotResurrectTimer() {
        var document = WatchDocument()
        document.receive(.init(revision: 10))
        var timer = TimerState.idle
        timer.start(kind: .focus, intention: "", category: "deep", targetMs: 60_000, now: start)
        document.receive(.init(revision: 9, timer: timer))
        XCTAssertEqual(document.timer.phase, .idle)
    }

    func testContextCannotManufactureConflictBeforeReceipt() throws {
        var document = WatchDocument()
        document.receive(.init(revision: 1))
        let first = command(.start)
        try document.perform(first)
        var incoming = WatchSnapshot(revision: 2, timer: document.timer)
        document.receive(incoming)
        XCTAssertNil(document.conflict)
        XCTAssertEqual(document.pending.count, 1)
        incoming.accepted = [first.id]
        document.receive(incoming)
        XCTAssertTrue(document.pending.isEmpty)
        XCTAssertEqual(document.snapshot.revision, 2)
    }

    func testPartialAcknowledgementKeepsActionsMadeInFlight() throws {
        var document = WatchDocument()
        document.receive(.init(revision: 1))
        let first = command(.start)
        try document.perform(first)
        let running = document.timer
        let second = command(.pause, 5000)
        try document.perform(second)
        document.receive(.init(revision: 2, timer: running, accepted: [first.id]))
        XCTAssertNil(document.conflict)
        XCTAssertEqual(document.timer.phase, .paused)
        XCTAssertEqual(document.pending, [second])
        XCTAssertEqual(document.snapshot.revision, 2)
    }

    func testCompetingStartPreservesWatchWorkForExplicitRecovery() throws {
        var document = WatchDocument()
        document.receive(.init(revision: 1))
        try document.perform(command(.start))
        try document.perform(command(.finish, 65_000))
        try document.perform(command(.save, 66_000))
        var phone = TimerState.idle
        phone.start(kind: .focus, intention: "Phone", category: "deep", targetMs: 60_000, now: start + 1)
        document.receive(.init(revision: 2, timer: phone, conflict: true))
        XCTAssertNotNil(document.conflict)
        XCTAssertThrowsError(try document.perform(command(.pause, 70_000)))
        document.keepPhone(now: start + 80_000)
        XCTAssertEqual(document.timer, phone)
        XCTAssertEqual(document.recovered.filter { $0.type.isFocus }.count, 1)
        XCTAssertTrue(document.pending.isEmpty)
    }

    func testSavedOfflineSessionSurvivesPartialReceiptThenConflict() throws {
        var document = WatchDocument()
        document.receive(.init(revision: 1))
        document.preferences.autoStartBreak = false
        let first = command(.start)
        try document.perform(first)
        let running = document.timer
        try document.perform(command(.finish, 70_000))
        try document.perform(command(.save, 71_000))
        document.receive(.init(revision: 3, timer: running, accepted: [first.id], conflict: true))
        document.keepPhone(now: start + 90_000)
        XCTAssertEqual(document.recovered.count, 1)
        XCTAssertEqual(document.recovered.first?.actualMs, 70_000)
    }

    func testConflictRecoveryCreditsTimeUntilResolution() throws {
        var document = WatchDocument()
        document.receive(.init(revision: 1))
        try document.perform(command(.start))
        document.receive(.init(revision: 2, conflict: true))
        document.keepPhone(now: start + 25 * 60_000)
        XCTAssertEqual(document.recovered.first?.actualMs, 25 * 60_000)
    }

    func testWatchCannotOwnAlarmsWithoutPermission() throws {
        var document = WatchDocument()
        try document.perform(command(.start))
        XCTAssertFalse(document.watchOwnsAlerts)
        document.alertsAuthorized = true
        try document.perform(command(.pause, 1000))
        XCTAssertTrue(document.watchOwnsAlerts)
    }

    func testInvalidDurationDoesNotChangeDocument() throws {
        var document = WatchDocument()
        var invalid = command(.start); invalid.minutes = 0
        XCTAssertThrowsError(try document.perform(invalid))
        XCTAssertEqual(document, WatchDocument())
    }

    func testLargeUnicodeReflectionIsBoundedBeforePersistence() throws {
        var document = WatchDocument()
        try document.perform(command(.start))
        try document.perform(command(.finish, 70_000))
        var edit = command(.editReflection, 71_000)
        edit.notes = String(repeating: "🧠", count: 50_000)
        try document.perform(edit)
        XCTAssertEqual(document.pending.last?.notes.count, 10_000)
        XCTAssertLessThan(try JSONEncoder().encode(document.pending.last!).count, 50_000)
        XCTAssertEqual(document.timer.reflection?.notes.count, 10_000)
    }

    func testExplicitRecoveryImportPersistsThroughPartialAcknowledgement() throws {
        var document = WatchDocument()
        let first = Session(id: Session.id(startedAt: start), category: "deep", startedAt: start, endedAt: start + 60_000)
        let second = Session(id: Session.id(startedAt: start + 1), category: "deep", startedAt: start + 1, endedAt: start + 60_001)
        document.recovered = [first, second]
        document.importingRecovery = true
        var receipt = WatchSnapshot()
        receipt.recoveredIDs = [first.id]
        document.receive(receipt)
        document = try JSONDecoder().decode(WatchDocument.self, from: JSONEncoder().encode(document))
        XCTAssertTrue(document.importingRecovery)
        XCTAssertEqual(document.recovered, [second])
        receipt.recoveredIDs = [second.id]
        document.receive(receipt)
        XCTAssertFalse(document.importingRecovery)
        XCTAssertTrue(document.recovered.isEmpty)
    }
}
