import XCTest
import SeshCore
import SeshStore
@testable import sesh

@MainActor
final class LiveActivityTests: XCTestCase {
    private let now: Millis = 1_800_000_000_000
    private func timer(_ start: Millis? = nil) -> TimerState {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Canonical work", category: "deep", targetMs: 60_000, now: start ?? now)
        return timer
    }
    private func projection(_ timer: TimerState, at: Millis? = nil) -> LiveActivityPresentation {
        LiveActivityPresentation(timer: timer, accentHex: "#E99B78", now: at ?? now)!
    }
    private func controller(_ driver: FakeLiveActivityDriver) -> LiveActivityController {
        LiveActivityController(driver: driver, defaults: nil)
    }

    func testRelaunchRecoversMatchingActivityAndEndsDuplicatesAndOtherSittings() async {
        let d = FakeLiveActivityDriver(); let a = projection(timer())
        d.seed(id: "a", a); d.seed(id: "duplicate", a); d.seed(id: "old", projection(timer(now - 20_000)))
        let c = controller(d)
        c.reconcile(state: timer(), accentHex: "#E99B78", now: now); await c.waitUntilSettled()
        XCTAssertEqual(d.records.map(\.id), ["a"])
        XCTAssertEqual(Set(d.ended), ["duplicate", "old"])
        XCTAssertTrue(d.requested.isEmpty)
        // Repeated pulls and time passing must not consume Watch update budget.
        c.reconcile(state: timer(), accentHex: "#E99B78", now: now + 5_000); await c.waitUntilSettled()
        XCTAssertTrue(d.updated.isEmpty)
    }

    func testIdleRelaunchEndsExistingSystemActivity() async {
        let d = FakeLiveActivityDriver(); d.seed(id: "old", projection(timer()))
        let c = controller(d); c.reconcile(state: .idle, accentHex: "#E99B78", now: now)
        await c.waitUntilSettled(); XCTAssertTrue(d.records.isEmpty)
    }

    func testPausedRemoteSessionCreatesWithFixedRemainingAndExactIdentity() async {
        let d = FakeLiveActivityDriver(); let c = controller(d)
        var a = timer(); a.pause(now: now + 10_000)
        c.reconcile(state: a, accentHex: "#E99B78", now: now + 30_000); await c.waitUntilSettled()
        XCTAssertEqual(d.records.first?.sessionStart, now)
        XCTAssertEqual(d.records.first?.content.pausedRemaining, 50)
        c.reconcile(state: a, accentHex: "#E99B78", now: now + 40_000); await c.waitUntilSettled()
        XCTAssertTrue(d.updated.isEmpty)
    }

    func testBackgroundAdoptionDefersCreationThenUnchangedForegroundRetries() async {
        let d = FakeLiveActivityDriver(); d.canStart = false; let c = controller(d)
        c.reconcile(state: timer(), accentHex: "#E99B78", now: now); await c.waitUntilSettled()
        XCTAssertTrue(d.records.isEmpty)
        d.canStart = true
        c.reconcile(state: timer(), accentHex: "#E99B78", now: now); await c.waitUntilSettled()
        XCTAssertEqual(d.requested, [now])
    }

    func testDelayedEndOfAUsesLatestCAndNeverCreatesObsoleteB() async {
        let d = FakeLiveActivityDriver(); d.seed(id: "a", projection(timer())); d.holdEnd = true
        let c = controller(d)
        c.reconcile(state: timer(now + 100), accentHex: "#E99B78", now: now + 100)
        await d.waitForOperation()
        c.reconcile(state: timer(now + 200), accentHex: "#E99B78", now: now + 200)
        d.release(); await c.waitUntilSettled()
        XCTAssertEqual(d.requested, [now + 200])
        XCTAssertEqual(d.records.first?.sessionStart, now + 200)
    }

    func testDelayedPauseUpdateSettlesToLatestResumeWithoutDuplicate() async {
        let d = FakeLiveActivityDriver(); let a = timer(); d.seed(id: "a", projection(a)); d.holdUpdate = true
        let c = controller(d); var paused = a; paused.pause(now: now + 10_000)
        c.reconcile(state: paused, accentHex: "#E99B78", now: now + 10_000); await d.waitForOperation()
        var resumed = paused; resumed.resume(now: now + 20_000)
        c.reconcile(state: resumed, accentHex: "#E99B78", now: now + 20_000)
        d.release(); await c.waitUntilSettled()
        XCTAssertEqual(d.records.first?.content, projection(resumed, at: now + 20_000).content)
        XCTAssertNil(d.records.first?.content.pausedRemaining)
        XCTAssertTrue(d.requested.isEmpty)
    }

    func testUserDismissalIsRespectedUntilNewSession() async {
        let d = FakeLiveActivityDriver(); let c = controller(d)
        c.reconcile(state: timer(), accentHex: "#E99B78", now: now); await c.waitUntilSettled()
        d.onDismiss?(now); d.storage.removeAll()
        c.reconcile(state: timer(), accentHex: "#E99B78", now: now + 5_000); await c.waitUntilSettled()
        XCTAssertEqual(d.requested, [now])
        c.reconcile(state: timer(now + 100), accentHex: "#E99B78", now: now + 100); await c.waitUntilSettled()
        XCTAssertEqual(d.requested, [now, now + 100])
    }

    func testLegacyRecoveredContentReceivesMissingStaleDeadline() async {
        let d = FakeLiveActivityDriver(); let a = projection(timer())
        d.storage = [.init(id: "legacy", sessionStart: now, content: a.content, staleDate: nil)]
        let c = controller(d); c.reconcile(state: timer(), accentHex: "#E99B78", now: now)
        await c.waitUntilSettled()
        XCTAssertEqual(d.updated, ["legacy"])
        XCTAssertEqual(d.records.first?.staleDate, a.staleDate)
    }

    func testStandaloneAppModelControlsReconcileWithoutSyncAssistance() async throws {
        let d = FakeLiveActivityDriver(); let c = controller(d)
        let model = AppModel(database: try AppDatabase.inMemory(), serverURL: URL(string: "http://127.0.0.1:3039")!, liveActivity: c)
        model.authState = .signedOut
        model.start(kind: .focus, minutes: 1); await c.waitUntilSettled()
        XCTAssertEqual(d.records.count, 1)
        let identity = d.records.first?.sessionStart
        model.pause(); await c.waitUntilSettled()
        XCTAssertNotNil(d.records.first?.content.pausedRemaining)
        model.resume(); await c.waitUntilSettled()
        XCTAssertEqual(d.records.first?.sessionStart, identity)
        XCTAssertNil(d.records.first?.content.pausedRemaining)
        model.abandon(); await c.waitUntilSettled()
        XCTAssertTrue(d.records.isEmpty)
    }

    func testCanonicalDeadlineOvertimeAndUnicodePayloadAreBounded() throws {
        var a = timer(); a.intention = String(repeating: "👩🏽‍💻", count: 10_000)
        let running = projection(a, at: now + 80_000)
        XCTAssertEqual(running.content.endDate.timeIntervalSince1970, Double(now + 60_000) / 1000)
        XCTAssertEqual(running.staleDate, running.content.endDate)
        XCTAssertLessThan(try JSONEncoder().encode(running.content).count, 4096)
        XCTAssertLessThanOrEqual(running.content.title.utf8.count, 512)
        a.pause(now: now + 80_000)
        let paused = projection(a, at: now + 100_000)
        XCTAssertEqual(paused.content.pausedRemaining, -20)
        XCTAssertNil(paused.staleDate)
        XCTAssertEqual(SeshActivityAttributes.clock(-20), "+0:20")
        XCTAssertEqual(SeshActivityAttributes.clock(1.1), "0:02")
    }
}

@MainActor
private final class FakeLiveActivityDriver: LiveActivityDriving {
    var isEnabled = true
    var canStart = true
    var onDismiss: ((Millis) -> Void)?
    var storage: [LiveActivityRecord] = []
    var records: [LiveActivityRecord] { storage }
    var requested: [Millis] = []
    var updated: [String] = []
    var ended: [String] = []
    var holdEnd = false, holdUpdate = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var operationWaiter: CheckedContinuation<Void, Never>?
    private var operationStarted = false
    func seed(id: String, _ p: LiveActivityPresentation) { storage.append(.init(id: id, sessionStart: p.sessionStart, content: p.content, staleDate: p.staleDate)) }
    func request(_ p: LiveActivityPresentation) throws { requested.append(p.sessionStart); seed(id: UUID().uuidString, p) }
    func update(id: String, presentation: LiveActivityPresentation) async {
        if holdUpdate { holdUpdate = false; await suspend() }
        updated.append(id)
        if let i = storage.firstIndex(where: { $0.id == id }) { storage[i] = .init(id: id, sessionStart: presentation.sessionStart, content: presentation.content, staleDate: presentation.staleDate) }
    }
    func end(id: String) async {
        if holdEnd { holdEnd = false; await suspend() }
        ended.append(id); storage.removeAll { $0.id == id }
    }
    private func suspend() async {
        await withCheckedContinuation { continuation in
            blocked = continuation; operationStarted = true
            operationWaiter?.resume(); operationWaiter = nil
        }
    }
    func waitForOperation() async {
        if operationStarted { return }
        await withCheckedContinuation { operationWaiter = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}
