import XCTest
@testable import SeshCore

final class SharedTimerTests: XCTestCase {
    private func remote(phase: String = "running", start: Millis = 1_000_000,
                        remaining: Int = 120_000, pausedAt: Millis? = nil) -> RemoteTimer {
        RemoteTimer(phase: phase, sessionType: "focus", intention: "Mac session", category: "deep",
                    targetMs: 300_000, remainingMs: remaining, overflowMs: 0,
                    startedAt: start, pausedAt: pausedAt, updatedAt: 1_300_000,
                    todoistTaskId: "things:task", deviceId: "mac")
    }

    func testSharedRunningTimerKeepsIdentityAndDeadlineAfterPauses() {
        let server = remote()
        let local = server.localTimer()
        XCTAssertEqual(local.startedAt, server.startedAt)
        XCTAssertEqual(local.pausedTotalMs, 120_000)
        XCTAssertEqual(local.remainingMs(now: 1_350_000), server.remainingMs(now: 1_350_000))
        XCTAssertEqual(local.targetDate(now: 1_350_000), Date(timeIntervalSince1970: 1420))
        XCTAssertEqual(local.draftSession(now: 1_350_000, manual: true)?.id, "manual-1000000")
    }

    func testRemotePausedTimerDoesNotContinueCountingDown() {
        let server = remote(phase: "paused", pausedAt: 1_240_000)
        let local = server.localTimer()
        XCTAssertEqual(server.remainingMs(now: 9_000_000), 120_000)
        XCTAssertEqual(local.remainingMs(now: 9_000_000), 120_000)
        var resumed = local
        resumed.resume(now: 9_000_000)
        XCTAssertEqual(resumed.startedAt, server.startedAt)
        XCTAssertEqual(resumed.remainingMs(now: 9_030_000), 90_000)
    }

    func testIdleSnapshotRetiresTimer() {
        XCTAssertEqual(remote(phase: "idle").localTimer().phase, .idle)
    }

    func testOlderServerNeverReceivesConditionalTimerAction() async {
        let store = FakeStore()
        store.outbox = [OutboxRecord(opId: "pause", op: .data(SyncOp(opId: "pause", kind: .timerMirror,
            payload: ["expectedUpdatedAt": .number(1_300_000), "expectedStartedAt": .number(1_000_000)])))]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 0, timer: remote()))]
        let engine = SyncEngine(store: store, transport: transport)
        let outcome = await engine.run()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(transport.requests[0].ops.isEmpty)
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertTrue(outcome.lastError?.contains("Server update needed") == true)
        XCTAssertEqual(store.remoteTimer?.startedAt, 1_000_000)
    }

    func testNewServerNegotiatesThenReceivesConditionalAction() async {
        let store = FakeStore()
        store.outbox = [OutboxRecord(opId: "pause", op: .data(SyncOp(opId: "pause", kind: .timerMirror,
            payload: ["expectedUpdatedAt": .number(1_300_000), "expectedStartedAt": .number(1_000_000)])))]
        let transport = ScriptedTransport()
        transport.responses = [.success(SyncResponse(results: [], changes: .init(sessions: [], categories: [], settings: []),
            cursor: 0, hasMore: false, timer: remote(), serverTime: 1_300_000, timerProtocolVersion: 2)),
            .success(.empty(cursor: 0, results: [.make("pause", .applied)]))]
        _ = await SyncEngine(store: store, transport: transport).run()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests[0].ops.isEmpty)
        XCTAssertEqual(transport.requests[1].ops.first?.opId, "pause")
        XCTAssertTrue(store.outbox.isEmpty)
    }
}
