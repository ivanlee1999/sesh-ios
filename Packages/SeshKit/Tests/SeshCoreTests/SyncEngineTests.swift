import XCTest
@testable import SeshCore

// ── Doubles ─────────────────────────────────────────────────────────────

final class FakeStore: SyncStore, @unchecked Sendable {
    var device = "test-iphone"
    var storedCursor = 0
    var outbox: [OutboxRecord] = []
    var applied: [SyncChanges] = []
    var remaps: [(from: String, to: String)] = []
    var deferrals: [(opId: String, attempts: Int, nextAttemptAt: Millis)] = []
    var removed: [String] = []
    var remoteTimer: RemoteTimer?
    var now: Millis = 1_700_000_000_000

    func deviceId() throws -> String { device }
    func cursor() throws -> Int { storedCursor }
    func setCursor(_ cursor: Int) throws { storedCursor = cursor }

    func dueOps(now: Millis, limit: Int) throws -> [OutboxRecord] {
        Array(outbox.prefix(limit))
    }

    func removeOp(_ opId: String) throws {
        removed.append(opId)
        outbox.removeAll { $0.opId == opId }
    }

    func deferOp(_ opId: String, attempts: Int, nextAttemptAt: Millis, error: String?) throws {
        deferrals.append((opId, attempts, nextAttemptAt))
        // Modelled the way a real store would: still queued, just not due yet.
        outbox.removeAll { $0.opId == opId }
    }

    func apply(_ changes: SyncChanges) throws { applied.append(changes) }
    func remapCategory(from oldSlug: String, to newSlug: String) throws { remaps.append((oldSlug, newSlug)) }
    func setRemoteTimer(_ timer: RemoteTimer?) throws { remoteTimer = timer }
}

final class ScriptedTransport: SyncTransport, @unchecked Sendable {
    var responses: [Result<SyncResponse, Error>] = []
    var requests: [SyncRequest] = []
    var taskCalls: [(TaskCommand, String)] = []
    var taskResults: [Result<Void, Error>] = []

    func sync(_ request: SyncRequest) async throws -> SyncResponse {
        requests.append(request)
        guard !responses.isEmpty else { return .empty(cursor: request.cursor) }
        return try responses.removeFirst().get()
    }

    func runTaskCommand(_ command: TaskCommand, opId: String) async throws {
        taskCalls.append((command, opId))
        guard !taskResults.isEmpty else { return }
        try taskResults.removeFirst().get()
    }
}

extension SyncResponse {
    static func empty(cursor: Int, hasMore: Bool = false, results: [OpResult] = [], timer: RemoteTimer? = nil) -> SyncResponse {
        SyncResponse(
            results: results,
            changes: SyncChanges(sessions: [], categories: [], settings: []),
            cursor: cursor,
            hasMore: hasMore,
            timer: timer,
            serverTime: 1_700_000_000_000
        )
    }
}

extension OpResult {
    static func make(_ opId: String, _ status: OpStatus, category: RemoteCategory? = nil, error: String? = nil) -> OpResult {
        OpResult(opId: opId, status: status, error: error, category: category, sessionCount: nil)
    }
}

private func dataOp(_ opId: String, category: String = "deep") -> OutboxRecord {
    OutboxRecord(opId: opId, op: .data(SyncOp(opId: opId, kind: .sessionComplete, payload: [
        "id": .string("manual-1"),
        "category": .string(category),
    ])))
}

// ── Tests ───────────────────────────────────────────────────────────────

final class SyncEngineTests: XCTestCase {
    private func engine(_ store: FakeStore, _ transport: ScriptedTransport) -> SyncEngine {
        SyncEngine(store: store, transport: transport, clock: { 1_700_000_000_000 })
    }

    func testPushesQueuedWorkAndAdvancesTheCursor() async {
        let store = FakeStore()
        store.outbox = [dataOp("op-1")]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 42, results: [.make("op-1", .applied)]))]

        let outcome = await engine(store, transport).run()

        XCTAssertEqual(transport.requests.first?.ops.count, 1)
        XCTAssertEqual(transport.requests.first?.deviceId, "test-iphone")
        XCTAssertEqual(store.storedCursor, 42)
        XCTAssertEqual(store.removed, ["op-1"])
        XCTAssertEqual(outcome.pushed, 1)
    }

    func testAnOpAlreadyAppliedIsNotSentForever() async {
        // A reply lost to a dropped connection: the op landed, we just never
        // heard. The server says so and the queue lets go of it.
        let store = FakeStore()
        store.outbox = [dataOp("op-1")]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1, results: [.make("op-1", .duplicate)]))]

        await engine(store, transport).run()

        XCTAssertEqual(store.removed, ["op-1"])
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testAnEditThatLostIsDroppedBecauseTheWinnerIsInThePull() async {
        let store = FakeStore()
        store.outbox = [dataOp("op-1")]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1, results: [.make("op-1", .stale)]))]

        await engine(store, transport).run()
        XCTAssertEqual(store.removed, ["op-1"])
    }

    func testRepointsRowsWhenTheServerNamesADifferentCategory() async {
        // The slug was renamed while this phone was offline. Everything pointing
        // at the old one has to move, including the ops still queued behind it.
        let store = FakeStore()
        store.outbox = [dataOp("op-1", category: "deep")]
        let winner = RemoteCategory(
            id: "cat-1", name: "deep-work", label: "Deep Work", color: "#c0522d",
            sortOrder: 0, isDefault: true, updatedAt: nil, deletedAt: nil
        )
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1, results: [
            .make("op-1", .rejected, category: winner, error: "A category with this name already exists"),
        ]))]

        await engine(store, transport).run()

        XCTAssertEqual(store.remaps.count, 1)
        XCTAssertEqual(store.remaps.first?.from, "deep")
        XCTAssertEqual(store.remaps.first?.to, "deep-work")
    }

    func testDoesNotRemapWhenTheNameDidNotActuallyChange() async {
        let store = FakeStore()
        store.outbox = [dataOp("op-1", category: "deep")]
        let same = RemoteCategory(
            id: "cat-1", name: "deep", label: "Deep", color: "#000000",
            sortOrder: 0, isDefault: false, updatedAt: nil, deletedAt: nil
        )
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1, results: [.make("op-1", .rejected, category: same)]))]

        await engine(store, transport).run()
        XCTAssertTrue(store.remaps.isEmpty)
    }

    func testAppliesChangesAndRemembersTheRemoteTimer() async {
        let store = FakeStore()
        let timer = RemoteTimer(
            phase: "running", sessionType: "focus", intention: "Elsewhere", category: "deep",
            targetMs: 1_500_000, remainingMs: 900_000, overflowMs: 0,
            startedAt: 1_700_000_000_000, pausedAt: nil, updatedAt: 1_700_000_000_000,
            todoistTaskId: nil, deviceId: "laptop"
        )
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 7, timer: timer))]

        await engine(store, transport).run()

        XCTAssertEqual(store.applied.count, 1)
        XCTAssertEqual(store.remoteTimer?.deviceId, "laptop")
        XCTAssertTrue(store.remoteTimer?.belongsToAnotherDevice("test-iphone") ?? false)
    }

    func testKeepsPagingWhileTheServerSaysThereIsMore() async {
        let store = FakeStore()
        let transport = ScriptedTransport()
        transport.responses = [
            .success(.empty(cursor: 10, hasMore: true)),
            .success(.empty(cursor: 20, hasMore: true)),
            .success(.empty(cursor: 30, hasMore: false)),
        ]

        let outcome = await engine(store, transport).run()

        XCTAssertEqual(outcome.pagesPulled, 3)
        XCTAssertEqual(store.storedCursor, 30)
        // Each round resumes from where the last one stopped.
        XCTAssertEqual(transport.requests.map(\.cursor), [0, 10, 20])
    }

    func testStopsRatherThanLoopingForever() async {
        let store = FakeStore()
        let transport = ScriptedTransport()
        transport.responses = (0..<50).map { _ in .success(.empty(cursor: 1, hasMore: true)) }

        let outcome = await engine(store, transport).run(maxRounds: 3)
        XCTAssertEqual(outcome.pagesPulled, 3)
    }

    func testGoingOfflineMidRunLosesNothing() async {
        let store = FakeStore()
        store.outbox = [dataOp("op-1")]
        let transport = ScriptedTransport()
        transport.responses = [.failure(APIError.offline)]

        let outcome = await engine(store, transport).run()

        XCTAssertFalse(outcome.signedOut)
        XCTAssertEqual(store.removed, [], "an unanswered op must stay queued")
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertNotNil(outcome.lastError)
    }

    func testBeingSignedOutStopsTheRunAndSaysSo() async {
        let store = FakeStore()
        let transport = ScriptedTransport()
        transport.responses = [.failure(APIError.unauthorized)]

        let outcome = await engine(store, transport).run()

        XCTAssertTrue(outcome.signedOut)
        XCTAssertTrue(store.applied.isEmpty)
    }

    // ── Task commands ───────────────────────────────────────────────────

    func testSendsTaskCommandsWithTheirOpIdAsTheIdempotencyKey() async {
        // Without this a retry after a lost reply adds the minutes twice.
        let store = FakeStore()
        store.outbox = [OutboxRecord(opId: "task-1", op: .task(
            TaskCommand(kind: .addDuration, provider: .things, taskId: "abc", minutes: 25)
        ))]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1))]

        await engine(store, transport).run()

        XCTAssertEqual(transport.taskCalls.count, 1)
        XCTAssertEqual(transport.taskCalls.first?.1, "task-1")
        XCTAssertEqual(transport.taskCalls.first?.0.minutes, 25)
        XCTAssertEqual(store.removed, ["task-1"])
    }

    func testATransientTaskFailureIsKeptAndBackedOff() async {
        let store = FakeStore()
        store.outbox = [OutboxRecord(opId: "task-1", op: .task(
            TaskCommand(kind: .complete, provider: .todoist, taskId: "123")
        ), attempts: 2)]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1))]
        transport.taskResults = [.failure(APIError.server(status: 502, message: "Bad gateway"))]

        let outcome = await engine(store, transport).run()

        XCTAssertEqual(store.removed, [])
        XCTAssertEqual(store.deferrals.count, 1)
        XCTAssertEqual(store.deferrals.first?.attempts, 3)
        XCTAssertGreaterThan(store.deferrals.first?.nextAttemptAt ?? 0, 1_700_000_000_000)
        XCTAssertEqual(outcome.deferred, 1)
    }

    func testARefusedTaskCommandIsDroppedRatherThanRetriedForever() async {
        // A task deleted in Things will 404 for as long as anyone cares to ask.
        let store = FakeStore()
        store.outbox = [OutboxRecord(opId: "task-1", op: .task(
            TaskCommand(kind: .complete, provider: .things, taskId: "gone")
        ))]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1))]
        transport.taskResults = [.failure(APIError.server(status: 404, message: "Not found"))]

        let outcome = await engine(store, transport).run()

        XCTAssertEqual(store.removed, ["task-1"])
        XCTAssertEqual(outcome.dropped, 1)
    }

    func testDataOpsAreNotSentDownTheTaskPath() async {
        let store = FakeStore()
        store.outbox = [dataOp("op-1")]
        let transport = ScriptedTransport()
        transport.responses = [.success(.empty(cursor: 1, results: [.make("op-1", .applied)]))]

        await engine(store, transport).run()
        XCTAssertTrue(transport.taskCalls.isEmpty)
    }
}

final class MergePolicyTests: XCTestCase {
    func testACleanRowAlwaysTakesTheServersCopy() {
        XCTAssertEqual(
            Merge.decide(local: LocalRowState(updatedAt: 100, dirty: false), remoteUpdatedAt: 50, remoteDeleted: false),
            .takeRemote
        )
    }

    func testAnUnsentNewerEditSurvivesThePull() {
        // The case that would otherwise silently discard work typed on a plane.
        XCTAssertEqual(
            Merge.decide(local: LocalRowState(updatedAt: 200, dirty: true), remoteUpdatedAt: 100, remoteDeleted: false),
            .keepLocal
        )
    }

    func testAnUnsentOlderEditGivesWay() {
        XCTAssertEqual(
            Merge.decide(local: LocalRowState(updatedAt: 50, dirty: true), remoteUpdatedAt: 100, remoteDeleted: false),
            .takeRemote
        )
    }

    func testAnUnknownRowIsSimplyTaken() {
        XCTAssertEqual(Merge.decide(local: nil, remoteUpdatedAt: 100, remoteDeleted: false), .takeRemote)
    }

    func testATombstoneForARowWeNeverHadIsNothingToDo() {
        XCTAssertEqual(Merge.decide(local: nil, remoteUpdatedAt: 100, remoteDeleted: true), .deleteLocal)
    }

    func testADeletionElsewhereRemovesACleanRow() {
        XCTAssertEqual(
            Merge.decide(local: LocalRowState(updatedAt: 10, dirty: false), remoteUpdatedAt: 100, remoteDeleted: true),
            .deleteLocal
        )
    }

    func testANewerUnsentEditOutlivesADeletionItHadNotHeardAbout() {
        // Editing a session on a plane, not knowing it was deleted at home, is
        // the more recent intention; it revives the row when it lands.
        XCTAssertEqual(
            Merge.decide(local: LocalRowState(updatedAt: 500, dirty: true), remoteUpdatedAt: 100, remoteDeleted: true),
            .keepLocal
        )
    }

    func testEqualTimestampsLetTheServerWin() {
        // Arbitrary, but it has to be decided somewhere, and the server is the
        // one copy both devices can see.
        XCTAssertEqual(
            Merge.decide(local: LocalRowState(updatedAt: 100, dirty: true), remoteUpdatedAt: 100, remoteDeleted: false),
            .takeRemote
        )
    }
}

final class BackoffTests: XCTestCase {
    let now: Millis = 1_000_000

    func testWaitsLongerEachTime() {
        let first = Backoff.nextAttempt(after: 1, now: now)
        let second = Backoff.nextAttempt(after: 2, now: now)
        let third = Backoff.nextAttempt(after: 3, now: now)

        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(third, second)
    }

    func testNeverWaitsLongerThanTheCeiling() {
        XCTAssertEqual(Backoff.nextAttempt(after: 50, now: now), now + Backoff.ceiling)
    }

    func testAlwaysWaitsAtLeastTheBaseDelay() {
        XCTAssertGreaterThanOrEqual(Backoff.nextAttempt(after: 0, now: now), now + Backoff.base)
    }

    func testStaysQuietUntilItHasTriedProperly() {
        XCTAssertFalse(Backoff.shouldSurface(attempts: 3))
        XCTAssertTrue(Backoff.shouldSurface(attempts: 8))
    }
}
