import XCTest
import GRDB
@testable import SeshCore
@testable import SeshStore

/**
 The store, against a real SQLite database in memory.

 The rule being checked throughout: a change is written locally *and* queued for
 the server in the same transaction. If those ever came apart, a session could
 be saved and never sent — or sent and never saved, which is worse, because the
 phone would show an hour that exists nowhere else.
 */
final class RepositoryTests: XCTestCase {
    private var database: AppDatabase!
    private var repository: SeshRepository!
    private let now: Millis = 1_700_000_000_000

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        repository = SeshRepository(database: database, clock: { [now] in now })
    }

    private func outbox() throws -> [OutboxRecordRow] {
        try database.writer.read { db in try OutboxRecordRow.order(Column("createdAt")).fetchAll(db) }
    }

    private func session(id: String = "manual-1", category: String = "deep") -> Session {
        Session(id: id, intention: "Write the plan", category: category, type: .focus,
                targetMs: 1_500_000, actualMs: 1_500_000, startedAt: 1, endedAt: 1_500_001)
    }

    func testSavingASessionQueuesItInTheSameBreath() throws {
        try repository.save(session())

        let stored = try database.writer.read { db in try SessionRecord.fetchOne(db, key: "manual-1") }
        XCTAssertEqual(stored?.intention, "Write the plan")
        XCTAssertTrue(stored?.dirty ?? false)

        let queued = try outbox()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.kind, SyncOpKind.sessionComplete.rawValue)
    }

    func testSavingAgainIsAnEditRatherThanASecondSitting() throws {
        // Editing an already saved session must not credit its time twice.
        try repository.save(session())
        try repository.save(session())

        let count = try database.writer.read { db in try SessionRecord.fetchCount(db) }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try outbox().map(\.kind), [SyncOpKind.sessionComplete.rawValue, SyncOpKind.sessionUpsert.rawValue])
    }

    func testEditingASessionOnlyTouchesWhatAPersonCanEdit() throws {
        try repository.save(session())
        try repository.updateSession(id: "manual-1", intention: "Renamed", rating: 5)

        let stored = try XCTUnwrap(try database.writer.read { db in try SessionRecord.fetchOne(db, key: "manual-1") })
        XCTAssertEqual(stored.intention, "Renamed")
        XCTAssertEqual(stored.rating, 5)
        XCTAssertEqual(stored.actualMs, 1_500_000, "timings are not the client's to revise")
    }

    func testDeletingRemovesItHereAndTellsTheServer() throws {
        try repository.save(session())
        try repository.deleteSession(id: "manual-1")

        let stored = try database.writer.read { db in try SessionRecord.fetchOne(db, key: "manual-1") }
        XCTAssertNil(stored)
        XCTAssertEqual(try outbox().last?.kind, SyncOpKind.sessionDelete.rawValue)
    }

    func testTheTimerSurvivesBeingKilled() throws {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Deep", category: "deep", targetMs: 1_500_000, now: now)
        try repository.saveTimer(timer, deviceId: "iphone")

        XCTAssertEqual(try repository.loadTimer(), timer)
    }

    func testTimerControlsRetainTheirCausalChain() throws {
        // Every transition is guarded against the preceding accepted transition.
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Deep", category: "deep", targetMs: 1_500_000, now: now)
        try repository.saveTimer(timer, deviceId: "iphone")
        timer.pause(now: now + 1000)
        try repository.saveTimer(timer, deviceId: "iphone")
        timer.resume(now: now + 2000)
        try repository.saveTimer(timer, deviceId: "iphone")

        let mirrors = try outbox().filter { $0.kind == SyncOpKind.timerMirror.rawValue }
        XCTAssertEqual(mirrors.count, 3)
        let ops = try mirrors.map { try JSONDecoder().decode(SyncOp.self, from: Data($0.payload.utf8)) }
        XCTAssertEqual(ops[0].payload["expectedUpdatedAt"], .number(0))
        XCTAssertEqual(ops[0].payload["expectedStartedAt"], .null)
        XCTAssertEqual(ops[1].payload["afterTimerOpId"], .string(ops[0].opId))
        XCTAssertEqual(ops[2].payload["afterTimerOpId"], .string(ops[1].opId))
        XCTAssertTrue(mirrors.allSatisfy { $0.coalesceKey == nil })
    }

    func testRenamingACategoryCarriesItsSessions() throws {
        let category = try repository.saveCategory(label: "Deep Work", color: "#c0522d")
        try repository.save(session(category: category.name))

        try repository.saveCategory(id: category.id, label: "Deep Focus", color: "#c0522d")

        let stored = try XCTUnwrap(try database.writer.read { db in try SessionRecord.fetchOne(db, key: "manual-1") })
        XCTAssertEqual(stored.category, "deep-focus")
    }

    func testSlugsMatchTheServers() {
        XCTAssertEqual(SeshRepository.slugify("Deep Work"), "deep-work")
        XCTAssertEqual(SeshRepository.slugify("  Deep  Work! "), "deep-work")
        XCTAssertEqual(SeshRepository.slugify("Admin"), "admin")
    }

    func testACategoryInUseCanBeCounted() throws {
        // A label the seed does not already hold, so this stays a test about
        // counting rather than about the unique constraint below.
        let category = try repository.saveCategory(label: "Admin", color: "#6E86B0")
        try repository.save(session(category: category.name))
        XCTAssertEqual(try repository.sessionCount(forCategory: category.name), 1)
    }

    /**
     A phone with no server still has categories.

     Everything filed a session under the empty string before this, because
     categories only ever arrived by syncing — which made the app unusable on
     its own, and the slugs have to be the server's so signing in later agrees
     rather than duplicates.
     */
    func testAFreshDatabaseComesWithTheServersCategories() throws {
        let seeded = try repository.categories()
        XCTAssertEqual(seeded.map(\.name), ["deep", "writing", "study", "reading", "design"])
        XCTAssertEqual(seeded.first?.label, "Deep Work")
        XCTAssertEqual(seeded.first?.color, "#BE6E45")
        // Not an edit anyone made, so there is nothing to push.
        XCTAssertTrue(seeded.allSatisfy { !$0.dirty })
        XCTAssertTrue(try outbox().isEmpty)
    }

    func testASecondCategoryCannotTakeAnExistingName() throws {
        XCTAssertThrowsError(try repository.saveCategory(label: "Writing", color: "#6E86B0")) { error in
            guard let refusal = error as? SeshRepository.CategoryNameTaken else {
                return XCTFail("Expected a name clash, got \(error)")
            }
            XCTAssertEqual(refusal.label, "Writing")
        }
    }

    func testRenamingACategoryToItsOwnNameIsNotAClash() throws {
        let deep = try repository.categories()[0]
        // Recolouring keeps the label, so the row finds itself and must not be
        // refused for already existing.
        let saved = try repository.saveCategory(id: deep.id, label: deep.label, color: "#123456")
        XCTAssertEqual(saved.color, "#123456")
        XCTAssertEqual(saved.name, "deep")
    }

    func testSettingsRoundTripThroughTheirOwnKeys() throws {
        try repository.setSetting(key: "focusDuration", value: .number(45))
        try repository.setSetting(key: "darkMode", value: .bool(true))

        let settings = try repository.settings()
        XCTAssertEqual(settings.focusDuration, 45)
        XCTAssertTrue(settings.darkMode)
        // Untouched keys keep their defaults rather than being blanked.
        XCTAssertEqual(settings.breakDuration, AppSettings.defaults.breakDuration)
    }

    func testCompletingATaskHidesItAndQueuesTheCommand() throws {
        try repository.replaceTaskCache(
            provider: .things,
            tasks: [ExternalTask(id: "abc", provider: .things, content: "Review the PR")],
            status: nil, error: nil
        )
        try repository.completeTask(ref: "things:abc")

        XCTAssertTrue(try repository.cachedTasks().isEmpty)
        XCTAssertEqual(try outbox().last?.kind, OutboxKind.task.rawValue)
    }

    func testATodoTypedOfflineShowsUpImmediately() throws {
        try repository.createTask(title: "Buy milk", when: "today")

        let tasks = try repository.cachedTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.content, "Buy milk")
        XCTAssertEqual(try outbox().count, 1)
    }

    func testRefreshingDoesNotUndoWorkStillInFlight() throws {
        try repository.createTask(title: "Buy milk", when: "today")
        // A refresh arrives before the create has reached Things.
        try repository.replaceTaskCache(
            provider: .things,
            tasks: [ExternalTask(id: "other", provider: .things, content: "Something else")],
            status: nil, error: nil
        )

        let titles = try repository.cachedTasks().map(\.content).sorted()
        XCTAssertEqual(titles, ["Buy milk", "Something else"])
    }
    func testReflectionCompletionIsAtomicAndExactlyOnce() throws {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Plan", category: "deep", targetMs: 1_500_000, now: now)
        timer.beginReflection(now: now + 120_000, manual: true)
        timer.reflection?.notes = "Next step"
        timer.reflection?.rating = 5
        timer.reflection?.todoistTaskId = "things:one"
        try repository.saveTimer(timer, deviceId: "iphone", mirror: false)
        XCTAssertEqual(try repository.loadTimer(), timer)
        let draft = try XCTUnwrap(timer.reflection)
        var cleared = timer
        cleared.abandon()
        XCTAssertTrue(try repository.save(draft, replacingTimer: cleared, deviceId: "iphone", requiringReflection: true))
        XCTAssertFalse(try repository.save(draft, replacingTimer: cleared, deviceId: "iphone", requiringReflection: true))
        XCTAssertEqual(try outbox().filter { $0.kind == SyncOpKind.sessionComplete.rawValue }.count, 1)
        let stored = try XCTUnwrap(try database.writer.read { try SessionRecord.fetchOne($0, key: draft.id) })
        XCTAssertEqual(stored.notes, "Next step")
        XCTAssertEqual(stored.rating, 5)
        XCTAssertEqual(stored.taskRefs, "things:one")
        XCTAssertNil(try repository.loadTimer().reflection)
    }

    func testCompletionWaitsForFinalTaskSelectionWithEitherBreakSetting() throws {
        for autoStartBreak in [false, true] {
            let db = try AppDatabase.inMemory()
            let store = SeshRepository(database: db, clock: { [now] in now })
            var timer = TimerState()
            timer.start(kind: .focus, intention: "Old task", category: "deep",
                        targetMs: 1_500_000, taskRefs: "things:old", now: now)
            timer.beginReflection(now: now + 120_000, manual: true,
                                  breakTargetMs: autoStartBreak ? 300_000 : nil)
            try store.saveTimer(timer, deviceId: "iphone")
            XCTAssertEqual(try store.sessions().count, 0)
            XCTAssertEqual(try db.writer.read { try OutboxRecordRow.fetchAll($0).map(\.kind) },
                           [SyncOpKind.timerMirror.rawValue])
            timer.reflection?.notes = "Final note"
            timer.reflection?.rating = 5
            timer.reflection?.todoistTaskId = "things:new,123"
            try store.saveTimer(timer, deviceId: "iphone", mirror: false)
            timer = try store.loadTimer()
            let draft = try XCTUnwrap(timer.reflection)
            var next = timer
            next.reflection = nil
            if next.phase == .reflect { next.abandon() }
            XCTAssertTrue(try store.save(draft, replacingTimer: next, deviceId: "iphone", requiringReflection: true))
            XCTAssertFalse(try store.save(draft, replacingTimer: next, deviceId: "iphone", requiringReflection: true))
            let complete = try db.writer.read {
                try OutboxRecordRow.filter(Column("kind") == SyncOpKind.sessionComplete.rawValue).fetchAll($0)
            }
            XCTAssertEqual(complete.count, 1)
            let payload = try JSONDecoder().decode(SyncOp.self, from: Data(try XCTUnwrap(complete.first).payload.utf8)).payload
            XCTAssertEqual(payload["todoistTaskId"]?.stringValue, "things:new,123")
            XCTAssertEqual(payload["notes"]?.stringValue, "Final note")
            XCTAssertEqual(try store.sessions().first?.rating, 5)
            XCTAssertEqual(try store.loadTimer().phase, autoStartBreak ? .running : .idle)
            XCTAssertNil(try store.loadTimer().reflection)
        }
    }

    func testFailedFinalSaveRollsBackAndCanRetry() throws {
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Plan", category: "deep", targetMs: 1_500_000, now: now)
        timer.beginReflection(now: now + 120_000, manual: true)
        timer.reflection?.notes = "Do not lose me"
        try repository.saveTimer(timer, deviceId: "iphone", mirror: false)
        let draft = try XCTUnwrap(timer.reflection)
        try database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failCompletion BEFORE INSERT ON outboxItem
                WHEN NEW.kind = 'session.complete'
                BEGIN SELECT RAISE(ABORT, 'Simulated disk failure'); END
                """)
        }
        XCTAssertThrowsError(try repository.save(draft, replacingTimer: .idle, deviceId: "iphone", requiringReflection: true))
        XCTAssertEqual(try repository.loadTimer().reflection?.notes, "Do not lose me")
        XCTAssertTrue(try repository.sessions().isEmpty)
        XCTAssertTrue(try outbox().isEmpty)
        try database.writer.write { try $0.execute(sql: "DROP TRIGGER failCompletion") }
        XCTAssertTrue(try repository.save(draft, replacingTimer: .idle, deviceId: "iphone", requiringReflection: true))
        XCTAssertEqual(try repository.sessions().count, 1)
        XCTAssertEqual(try outbox().filter { $0.kind == SyncOpKind.sessionComplete.rawValue }.count, 1)
    }

    func testReflectionAndBackDraftSurviveReopeningDiskDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var disk: AppDatabase? = try AppDatabase.onDisk(folder: folder)
        var store: SeshRepository? = SeshRepository(database: try XCTUnwrap(disk))
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Plan", category: "deep", targetMs: 1_500_000, now: now)
        timer.beginReflection(now: now + 120_000, manual: true)
        timer.reflection?.notes = "Survive relaunch"
        timer.reflection?.rating = 3
        try store?.saveTimer(timer, deviceId: "iphone", mirror: false)
        store = nil
        disk = nil
        disk = try AppDatabase.onDisk(folder: folder)
        store = SeshRepository(database: try XCTUnwrap(disk))
        timer = try XCTUnwrap(store).loadTimer()
        XCTAssertEqual(timer.reflection?.notes, "Survive relaunch")
        timer.returnFromReflection()
        try store?.saveTimer(timer, deviceId: "iphone", mirror: false)
        store = nil
        disk = nil
        disk = try AppDatabase.onDisk(folder: folder)
        store = SeshRepository(database: try XCTUnwrap(disk))
        timer = try XCTUnwrap(store).loadTimer()
        timer.beginReflection(now: now + 240_000, manual: true)
        XCTAssertEqual(timer.reflection?.notes, "Survive relaunch")
        XCTAssertEqual(timer.reflection?.rating, 3)
    }

    private func remote(phase: String = "running", start: Millis? = 1_700_000_000_000,
                        remaining: Int = 1_499_000, updated: Millis = 1_700_000_001_000) -> RemoteTimer {
        RemoteTimer(phase: phase, sessionType: "focus", intention: "Mac work", category: "deep",
                    targetMs: 1_500_000, remainingMs: remaining, overflowMs: 0,
                    startedAt: start, pausedAt: phase == "paused" ? updated : nil,
                    updatedAt: updated, todoistTaskId: "things:mac", deviceId: "mac")
    }

    func testSharedTimerAdoptsWithoutOutboxAndKeepsIdentityDeadlineOnWatch() throws {
        let sync = DatabaseSyncStore(database: database, clock: { [now] in now + 10_000 })
        let shared = remote()
        try sync.setRemoteTimer(shared)
        let local = try repository.loadTimer()
        XCTAssertEqual(local.startedAt, shared.startedAt)
        XCTAssertEqual(local.remainingMs(now: now + 10_000), 1_490_000)
        XCTAssertEqual(local.taskRefs, "things:mac")
        XCTAssertEqual(try repository.pendingCount(), 0)
        let snapshot = try repository.watchSnapshot()
        XCTAssertEqual(snapshot.timer, local)
        try sync.setRemoteTimer(shared)
        XCTAssertEqual(try repository.watchSnapshot().revision, snapshot.revision,
                       "Receiving the same snapshot must not invalidate queued Watch controls")
    }

    func testPausedRemoteDoesNotLoseTimeWhenReceivedMuchLater() throws {
        let sync = DatabaseSyncStore(database: database, clock: { [now] in now + 100_000 })
        try sync.setRemoteTimer(remote(phase: "paused", remaining: 1_490_000, updated: now + 10_000))
        let local = try repository.loadTimer()
        XCTAssertEqual(local.phase, .paused)
        XCTAssertEqual(local.remainingMs(now: now + 100_000), 1_490_000)
        XCTAssertEqual(local.remainingMs(now: now + 200_000), 1_490_000)
    }

    func testPendingControlKeepsLocalTimerButPersistsRemoteBaseline() throws {
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote())
        var local = try repository.loadTimer()
        local.pause(now: now + 2000)
        try repository.saveTimer(local, deviceId: "phone")
        let newer = remote(start: now + 5000, updated: now + 5000)
        try sync.setRemoteTimer(newer)
        XCTAssertEqual(try repository.loadTimer(), local)
        XCTAssertEqual(try repository.remoteTimer(), newer)
        let op = try XCTUnwrap(outbox().first)
        let payload = try JSONDecoder().decode(SyncOp.self, from: Data(op.payload.utf8)).payload
        XCTAssertEqual(payload["expectedUpdatedAt"], .number(Double(now + 1000)))
        XCTAssertEqual(payload["expectedStartedAt"], .number(Double(now)))
    }

    func testRejectedControlRecoversLocalDraftAndAdoptsRemoteAfterRemovingOp() throws {
        let sync = DatabaseSyncStore(database: database)
        var local = TimerState()
        local.start(kind: .focus, intention: "Offline work", category: "deep", targetMs: 1000, now: now)
        local.beginReflection(now: now + 2000, manual: true)
        local.reflection?.notes = "Keep this note"
        try repository.saveTimer(local, deviceId: "phone")
        let op = try XCTUnwrap(outbox().first)
        try sync.recordTimerConflict(op.opId)
        try sync.removeOp(op.opId)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        XCTAssertEqual(try repository.timerConflict(), local)
        XCTAssertEqual(try repository.loadTimer().intention, "Mac work")
        XCTAssertEqual(try repository.loadTimer().reflection?.notes, "Keep this note")
        try sync.recordTimerConflict("later-refusal")
        XCTAssertEqual(try repository.timerConflict(), local)
        try repository.resolveTimerConflict()
        XCTAssertNil(try repository.timerConflict())
        XCTAssertEqual(try repository.recoveredTimer(), local)
        XCTAssertEqual(try repository.loadTimer().intention, "Mac work")
    }

    func testRemoteIdleClosesLiveTimerAndRetainsReflection() throws {
        let sync = DatabaseSyncStore(database: database)
        var local = remote().localTimer()
        local.beginReflection(now: now + 2000, manual: true)
        local.reflection?.notes = "Final note"
        try repository.saveTimer(local, deviceId: "phone", mirror: false)
        try sync.setRemoteTimer(remote(phase: "idle", start: nil, remaining: 0))
        XCTAssertEqual(try repository.loadTimer().phase, .idle)
        XCTAssertNil(try repository.loadTimer().startedAt)
        XCTAssertEqual(try repository.loadTimer().reflection?.notes, "Final note")
        XCTAssertEqual(try repository.pendingCount(), 0)
    }

    func testSamePausedRemotePreservesOpenReflection() throws {
        let sync = DatabaseSyncStore(database: database)
        var local = remote().localTimer()
        local.beginReflection(now: now + 2000, manual: true)
        local.reflection?.notes = "Still editing"
        try repository.saveTimer(local, deviceId: "phone", mirror: false)
        try sync.setRemoteTimer(remote(phase: "paused", remaining: 1_498_000, updated: now + 2000))
        XCTAssertEqual(try repository.loadTimer().phase, .reflect)
        XCTAssertEqual(try repository.loadTimer().reflection?.notes, "Still editing")
    }

    func testDelayedPredecessorPreventsLaterControlFromBeingSentEarly() throws {
        var local = remote().localTimer()
        try repository.saveTimer(local, deviceId: "phone")
        local.pause(now: now + 2000)
        try repository.saveTimer(local, deviceId: "phone")
        let rows = try outbox()
        let sync = DatabaseSyncStore(database: database)
        try sync.deferOp(rows[0].opId, attempts: 1, nextAttemptAt: now + 10_000, error: "offline")
        XCTAssertTrue(try sync.dueOps(now: now, limit: 100).isEmpty)
        XCTAssertEqual(try sync.dueOps(now: now + 10_000, limit: 100).map(\.opId), rows.map(\.opId))
    }

    func testLegacyMirrorUpgradeUsesConservativeGuard() throws {
        var legacyPayload = remote().localTimer().mirrorPayload(now: now, deviceId: "old-phone")
        legacyPayload.removeValue(forKey: "expectedUpdatedAt")
        legacyPayload.removeValue(forKey: "expectedStartedAt")
        let op = SyncOp(kind: .timerMirror, payload: legacyPayload)
        try database.writer.write { db in
            try OutboxRecordRow(opId: op.opId, kind: op.kind.rawValue,
                payload: String(decoding: try JSONEncoder().encode(op), as: UTF8.self), coalesceKey: "timer",
                createdAt: now, attempts: 0, nextAttemptAt: 0, lastError: nil).insert(db)
        }
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        let item = try XCTUnwrap(sync.dueOps(now: now, limit: 100).first)
        guard case .data(let guarded) = item.op else { return XCTFail("Expected mirror") }
        XCTAssertEqual(guarded.payload["expectedUpdatedAt"], .number(0))
        XCTAssertEqual(guarded.payload["expectedStartedAt"], .null)
        XCTAssertEqual(guarded.payload["recordedAt"], .number(Double(now)))
    }

    func testCompletionThenMirrorFormsCausalChainAtSameTimestamp() throws {
        var timer = remote().localTimer()
        timer.beginReflection(now: now + 1000, manual: true)
        let draft = try XCTUnwrap(timer.reflection)
        try repository.saveTimer(timer, deviceId: "phone", mirror: false)
        var next = TimerState.idle
        next.reflection = nil
        XCTAssertTrue(try repository.save(draft, replacingTimer: next, deviceId: "phone", requiringReflection: true))
        let rows = try outbox()
        XCTAssertEqual(rows.map(\.kind), ["session.complete", "timer.mirror"])
        let ops = try rows.map { try JSONDecoder().decode(SyncOp.self, from: Data($0.payload.utf8)) }
        XCTAssertEqual(ops[1].payload["afterTimerOpId"], .string(ops[0].opId))
    }

    func testConflictRecoveryPersistsAcrossDiskReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try AppDatabase.onDisk(folder: folder)
        let repo = SeshRepository(database: db)
        let timer = remote().localTimer()
        try repo.saveTimer(timer, deviceId: "phone")
        let op = try XCTUnwrap(db.writer.read { try OutboxRecordRow.fetchOne($0) })
        try DatabaseSyncStore(database: db).recordTimerConflict(op.opId)
        let reopened = try AppDatabase.onDisk(folder: folder)
        let restored = try XCTUnwrap(SeshRepository(database: reopened).timerConflict())
        XCTAssertEqual(restored.startedAt, timer.startedAt)
        XCTAssertEqual(restored.phase, timer.phase)
        XCTAssertNotNil(restored.reflection, "Running recovery must have a frozen journal boundary")
    }

    func testRejectedSaveKeepsCompletedNotesInRecoveryAndLocalHistory() throws {
        var timer = remote().localTimer()
        timer.beginReflection(now: now + 1000, manual: true)
        timer.reflection?.notes = "Completed offline"
        let draft = try XCTUnwrap(timer.reflection)
        try repository.saveTimer(timer, deviceId: "phone", mirror: false)
        _ = try repository.save(draft, replacingTimer: .idle, deviceId: "phone", requiringReflection: true)
        let complete = try XCTUnwrap(outbox().first(where: { $0.kind == "session.complete" }))
        try DatabaseSyncStore(database: database).recordTimerConflict(complete.opId)
        XCTAssertEqual(try repository.timerConflict()?.reflection?.notes, "Completed offline")
        XCTAssertEqual(try repository.sessions().first?.notes, "Completed offline")
        XCTAssertEqual(try repository.loadTimer().phase, .idle)
        XCTAssertNil(try repository.loadTimer().startedAt)
    }

    func testAcknowledgementGapRetainsDurablePredecessor() throws {
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote())
        var timer = try repository.loadTimer()
        timer.pause(now: now + 2000)
        try repository.saveTimer(timer, deviceId: "phone")
        let accepted = try XCTUnwrap(outbox().first)
        try sync.removeOp(accepted.opId)
        // A Watch action arrives before the engine saves response.timer.
        timer.resume(now: now + 3000)
        try repository.saveTimer(timer, deviceId: "phone")
        let queued = try XCTUnwrap(outbox().first)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(queued.payload.utf8))
        XCTAssertEqual(op.payload["afterTimerOpId"], .string(accepted.opId))
        try sync.setRemoteTimer(remote(phase: "paused", remaining: 1_498_000, updated: now + 2000))
        XCTAssertEqual(try repository.loadTimer(), timer, "Snapshot must not overwrite the newer pending resume")
    }

    func testSavingReflectionAfterRemoteResumeCannotResurrectSameSitting() throws {
        let sync = DatabaseSyncStore(database: database)
        var timer = remote().localTimer()
        timer.beginReflection(now: now + 1000, manual: true)
        try repository.saveTimer(timer, deviceId: "phone", mirror: false)
        try sync.setRemoteTimer(remote(updated: now + 2000))
        let adopted = try repository.loadTimer()
        XCTAssertEqual(adopted.phase, .running)
        let draft = try XCTUnwrap(adopted.reflection)
        var next = adopted
        next.reflection = nil
        _ = try repository.save(draft, replacingTimer: next, deviceId: "phone", requiringReflection: true)
        XCTAssertEqual(try repository.loadTimer().phase, .idle)
        XCTAssertNil(try repository.loadTimer().startedAt)
        let mirror = try XCTUnwrap(outbox().last)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(mirror.payload.utf8))
        XCTAssertEqual(op.payload["phase"], .string("idle"))
        XCTAssertEqual(op.payload["startedAt"], .null)
    }

    func testSuccessiveConflictsKeepEveryDismissedRecovery() throws {
        let sync = DatabaseSyncStore(database: database)
        let first = remote().localTimer()
        try repository.saveTimer(first, deviceId: "phone")
        let firstOp = try XCTUnwrap(outbox().first)
        try sync.recordTimerConflict(firstOp.opId)
        try sync.removeOp(firstOp.opId)
        try repository.resolveTimerConflict()
        let second = remote(start: now + 10_000, updated: now + 10_000).localTimer()
        try repository.saveTimer(second, deviceId: "phone")
        let secondOp = try XCTUnwrap(outbox().first)
        try sync.recordTimerConflict(secondOp.opId)
        XCTAssertEqual(try repository.recoveredTimers().map(\.startedAt), [second.startedAt, first.startedAt])
        XCTAssertEqual(try repository.timerConflict()?.startedAt, second.startedAt)
        try repository.resolveTimerConflict()
        XCTAssertEqual(try repository.recoveredTimers().map(\.startedAt), [second.startedAt, first.startedAt])
    }

    func testWatchMessagesSeparatePhoneReceiptFromServerAcknowledgement() throws {
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote())
        XCTAssertEqual(try repository.watchSnapshot().syncMessage, "Shared session")
        let snapshot = try repository.watchSnapshot()
        let command = WatchCommand(action: .pause, at: now + 2000, sessionStart: now)
        let response = try repository.receiveWatch(WatchBatch(revision: snapshot.revision, commands: [command]), deviceId: "phone")
        XCTAssertEqual(response.syncMessage, "Waiting to sync with server.")
        let op = try XCTUnwrap(outbox().first)
        try sync.recordTimerConflict(op.opId)
        XCTAssertEqual(try repository.watchSnapshot().syncMessage, "Shared session changed. Local work saved on iPhone.")
    }

    func testIdlePullPreservesUnsentSessionPreparation() throws {
        var preparation = TimerState.idle
        preparation.intention = "Outline the next chapter"
        preparation.category = "writing"
        preparation.taskRefs = "things:chapter,todoist:revision"
        try repository.saveTimer(preparation, deviceId: "phone", mirror: false)
        let sync = DatabaseSyncStore(database: database)
        let idle = remote(phase: "idle", start: nil, remaining: 0, updated: now + 5000)
        try sync.setRemoteTimer(idle)
        var expected = preparation
        expected.sharedBaseline = idle.localTimer().sharedBaseline
        XCTAssertEqual(try repository.loadTimer(), expected)
        XCTAssertEqual(try repository.remoteTimer(), idle, "Idle preparation must not prevent baseline refresh")
        XCTAssertEqual(try repository.pendingCount(), 0)
        try sync.setRemoteTimer(nil)
        XCTAssertEqual(try repository.loadTimer(), preparation)
    }

    func testRemoteIdleStillRetiresAnActiveLocalTimer() throws {
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote())
        XCTAssertEqual(try repository.loadTimer().phase, .running)
        try sync.setRemoteTimer(remote(phase: "idle", start: nil, remaining: 0, updated: now + 5000))
        XCTAssertEqual(try repository.loadTimer().phase, .idle)
        XCTAssertNil(try repository.loadTimer().startedAt)
        XCTAssertEqual(try repository.pendingCount(), 0)
    }

    func testLateVisibleControlKeepsItsCapturedBaselineInsteadOfNewerDatabaseSnapshot() throws {
        let sync = DatabaseSyncStore(database: database)
        let original = remote()
        try sync.setRemoteTimer(original)
        var visible = try repository.loadTimer()
        // The network has already stored B while the UI still displays A.
        let newer = remote(start: now + 5000, updated: now + 5000)
        try sync.setRemoteTimer(newer)
        visible.pause(now: now + 2000)
        try repository.saveTimer(visible, deviceId: "phone")
        let row = try XCTUnwrap(outbox().first)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(row.payload.utf8))
        XCTAssertEqual(op.payload["expectedUpdatedAt"], .number(Double(original.updatedAt)))
        XCTAssertEqual(op.payload["expectedStartedAt"], .number(Double(original.startedAt!)))
        XCTAssertNotEqual(op.payload["expectedUpdatedAt"], .number(Double(newer.updatedAt)))
    }

    func testLateReflectionSaveUsesPersistedActionBaselineInsteadOfNewerRemoteRow() throws {
        let sync = DatabaseSyncStore(database: database)
        let original = remote()
        try sync.setRemoteTimer(original)
        var visible = try repository.loadTimer()
        visible.beginReflection(now: now + 2000, manual: true)
        visible.reflection?.notes = "From the original sitting"
        let draft = try XCTUnwrap(visible.reflection)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        // App persists the user's action value before atomically saving it.
        try repository.saveTimer(visible, deviceId: "phone", mirror: false)
        _ = try repository.save(draft, replacingTimer: TimerState(sharedBaseline: visible.sharedBaseline),
                                deviceId: "phone", requiringReflection: true)
        let row = try XCTUnwrap(outbox().first)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(row.payload.utf8))
        XCTAssertEqual(op.kind, .sessionComplete)
        XCTAssertEqual(op.payload["expectedUpdatedAt"], .number(Double(original.updatedAt)))
        XCTAssertEqual(op.payload["expectedStartedAt"], .number(Double(original.startedAt!)))
    }

    func testIdlePreparationRefreshesBaselineForNextStartWithoutLosingFields() throws {
        var prepared = TimerState.idle
        prepared.intention = "Plan the day"
        prepared.category = "writing"
        try repository.saveTimer(prepared, deviceId: "phone", mirror: false)
        let idle = remote(phase: "idle", start: nil, remaining: 0, updated: now + 10_000)
        try DatabaseSyncStore(database: database).setRemoteTimer(idle)
        var next = try repository.loadTimer()
        XCTAssertEqual(next.sharedBaseline, idle.localTimer().sharedBaseline)
        XCTAssertEqual(next.intention, prepared.intention)
        next.start(kind: .focus, intention: next.intention, category: next.category, targetMs: 1000, now: now + 20_000)
        try repository.saveTimer(next, deviceId: "phone")
        let row = try XCTUnwrap(outbox().first)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(row.payload.utf8))
        XCTAssertEqual(op.payload["expectedUpdatedAt"], .number(Double(idle.updatedAt)))
        XCTAssertEqual(op.payload["expectedStartedAt"], .null)
    }

    func testDetachedReflectionSavePreservesCanonicalNewSittingAndSavesHistoryOnce() throws {
        var failed = remote().localTimer()
        failed.beginReflection(now: now + 2000, manual: true)
        failed.reflection?.notes = "Recovered from failed save"
        let draft = try XCTUnwrap(failed.reflection)
        let newer = remote(start: now + 5000, updated: now + 5000)
        try DatabaseSyncStore(database: database).setRemoteTimer(newer)
        let canonical = try repository.loadTimer()
        let result = try repository.saveDetachedReflection(draft, deviceId: "phone")
        XCTAssertEqual(result, canonical)
        XCTAssertEqual(try repository.loadTimer(), canonical)
        XCTAssertEqual(try repository.sessions().filter { $0.id == draft.id }.count, 1)
        XCTAssertEqual(try repository.sessions().first?.notes, "Recovered from failed save")
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(try XCTUnwrap(outbox().first).payload.utf8))
        XCTAssertEqual(op.payload["journalOnly"], .bool(true))
        XCTAssertNil(op.payload["afterTimerOpId"])
        XCTAssertNil(op.payload["expectedUpdatedAt"])
        _ = try repository.saveDetachedReflection(draft, deviceId: "phone")
        XCTAssertEqual(try outbox().filter { $0.kind == "session.complete" }.count, 1)
        XCTAssertTrue(try outbox().allSatisfy { $0.kind != "timer.mirror" })
    }

    func testDetachedReflectionSaveRetiresMatchingCanonicalSitting() throws {
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote())
        var reflected = try repository.loadTimer()
        reflected.beginReflection(now: now + 2000, manual: true)
        let draft = try XCTUnwrap(reflected.reflection)
        let result = try repository.saveDetachedReflection(draft, deviceId: "phone")
        XCTAssertEqual(result.phase, .idle)
        XCTAssertNil(result.startedAt)
        XCTAssertEqual(result.sharedBaseline, reflected.sharedBaseline)
        XCTAssertEqual(try outbox().map(\.kind), ["session.complete", "timer.mirror"])
    }

    func testDetachedReflectionSavePreservesUnrelatedCanonicalReflection() throws {
        var old = remote().localTimer()
        old.beginReflection(now: now + 2000, manual: true)
        let draft = try XCTUnwrap(old.reflection)
        var newer = remote(start: now + 5000, updated: now + 5000).localTimer()
        newer.beginReflection(now: now + 7000, manual: true)
        newer.reflection?.notes = "Other draft"
        try repository.saveTimer(newer, deviceId: "phone", mirror: false)
        let result = try repository.saveDetachedReflection(draft, deviceId: "phone")
        XCTAssertEqual(result, newer)
        XCTAssertEqual(result.reflection?.notes, "Other draft")
    }

    func testBaselineOnlyAcknowledgementKeepsWatchEpochAndAlertOwner() throws {
        let sync = DatabaseSyncStore(database: database)
        let paused = remote(phase: "paused", remaining: 1_490_000, updated: now + 10_000)
        try sync.setRemoteTimer(paused)
        let snapshot = try repository.watchSnapshot()
        try database.writer.write { db in try db.execute(sql: "UPDATE watchRevision SET alertsOnWatch = 1 WHERE id = 1") }
        // Same paused sitting and timing, newer accepted wire version only.
        let acknowledged = RemoteTimer(phase: paused.phase, sessionType: paused.sessionType,
            intention: paused.intention, category: paused.category, targetMs: paused.targetMs,
            remainingMs: paused.remainingMs, overflowMs: paused.overflowMs, startedAt: paused.startedAt,
            pausedAt: paused.pausedAt, updatedAt: paused.updatedAt + 1000,
            todoistTaskId: paused.todoistTaskId, deviceId: paused.deviceId)
        try sync.setRemoteTimer(acknowledged)
        let next = try repository.watchSnapshot()
        XCTAssertEqual(next.revision, snapshot.revision)
        XCTAssertTrue(next.alertsOnWatch)
        XCTAssertNotEqual(next.timer.sharedBaseline, snapshot.timer.sharedBaseline)
        let stored = try database.writer.read { try String.fetchOne($0, sql: "SELECT state FROM watchRevision WHERE id = 1") }
        let timer = try JSONDecoder().decode(TimerState.self, from: Data(try XCTUnwrap(stored).utf8))
        XCTAssertEqual(timer.sharedBaseline, next.timer.sharedBaseline)
    }

    func testStaleVisibleAIsNotAuthorizedByPendingFreshBControl() throws {
        let sync = DatabaseSyncStore(database: database)
        try sync.setRemoteTimer(remote())
        var stale = try repository.loadTimer()
        let newer = remote(start: now + 5000, updated: now + 5000)
        try sync.setRemoteTimer(newer)
        var fresh = try repository.loadTimer()
        fresh.pause(now: now + 6000)
        try repository.saveTimer(fresh, deviceId: "watch-phone")
        stale.pause(now: now + 2000)
        try repository.saveTimer(stale, deviceId: "phone")
        let ops = try outbox().map { try JSONDecoder().decode(SyncOp.self, from: Data($0.payload.utf8)) }
        XCTAssertEqual(ops.count, 2)
        XCTAssertNil(ops[1].payload["afterTimerOpId"], "A must not become authorized by B's receipt")
        XCTAssertEqual(ops[1].payload["expectedStartedAt"], .number(Double(now)))
        XCTAssertEqual(ops[1].payload["expectedUpdatedAt"], .number(Double(now + 1000)))
    }

    func testDetachedRetryAfterRefusedCompletionRemainsCreateCapableJournalOnly() throws {
        let sync = DatabaseSyncStore(database: database)
        var timer = remote().localTimer()
        timer.beginReflection(now: now + 2000, manual: true)
        timer.reflection?.notes = "Refused first save"
        let draft = try XCTUnwrap(timer.reflection)
        try repository.saveTimer(timer, deviceId: "phone", mirror: false)
        _ = try repository.save(draft, replacingTimer: TimerState(sharedBaseline: timer.sharedBaseline), deviceId: "phone", requiringReflection: true)
        for row in try outbox() {
            try sync.recordTimerConflict(row.opId)
            try sync.removeOp(row.opId)
        }
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        let canonical = try repository.loadTimer()
        _ = try repository.saveDetachedReflection(draft, deviceId: "phone")
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(try XCTUnwrap(outbox().first).payload.utf8))
        XCTAssertEqual(op.kind, .sessionComplete)
        XCTAssertEqual(op.payload["journalOnly"], .bool(true))
        XCTAssertNotNil(op.payload["actualMs"], "Retry must carry full create-capable timing payload")
        XCTAssertEqual(try repository.loadTimer(), canonical)
    }

    func testExplicitRecoveryDoesNotBlockSharedAdoptionOrAlterTimer() throws {
        let sync = DatabaseSyncStore(database: database)
        var recovery = remote().localTimer()
        recovery.beginReflection(now: now + 2000, manual: true)
        let draft = try XCTUnwrap(recovery.reflection)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        try repository.saveRecoveredSession(draft)
        try repository.saveRecoveredSession(draft)
        XCTAssertEqual(try repository.pendingCount(), 1)
        let updated = remote(start: now + 10_000, updated: now + 10_000)
        try sync.setRemoteTimer(updated)
        XCTAssertEqual(try repository.loadTimer().startedAt, updated.startedAt)
        XCTAssertEqual(try repository.watchSnapshot().syncMessage, "Shared session")
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(try XCTUnwrap(outbox().first).payload.utf8))
        XCTAssertEqual(op.payload["journalOnly"], .bool(true))
        XCTAssertNil(op.payload["expectedUpdatedAt"])
    }

    func testReflectionEditPreservesNewCanonicalTimerInsteadOfCachedTimer() throws {
        let sync = DatabaseSyncStore(database: database)
        var old = remote().localTimer()
        old.beginReflection(now: now + 2000, manual: true)
        try repository.saveTimer(old, deviceId: "phone", mirror: false)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        let before = try repository.loadTimer()
        var draft = try XCTUnwrap(old.reflection)
        draft.notes = "Edited from the old screen"
        let result = try repository.editReflection(draft)
        var expected = before
        expected.reflection = draft
        XCTAssertEqual(result, expected)
        XCTAssertEqual(try repository.loadTimer(), expected)
        XCTAssertEqual(try repository.pendingCount(), 0)
    }

    func testNormalReflectionSavePreservesCanonicalBWhenPassedStaleAState() throws {
        let sync = DatabaseSyncStore(database: database)
        var old = remote().localTimer()
        old.beginReflection(now: now + 2000, manual: true)
        let draft = try XCTUnwrap(old.reflection)
        try repository.saveTimer(old, deviceId: "phone", mirror: false)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        var expected = try repository.loadTimer()
        expected.reflection = nil
        var staleNext = old
        staleNext.abandon()
        XCTAssertTrue(try repository.save(draft, replacingTimer: staleNext, deviceId: "phone", requiringReflection: true))
        XCTAssertEqual(try repository.loadTimer(), expected)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(try XCTUnwrap(outbox().first).payload.utf8))
        XCTAssertEqual(op.payload["journalOnly"], .bool(true))
        XCTAssertEqual(try repository.pendingCount(), 1)
    }

    func testRepeatedRecoveryDoesNotOverwriteEditedHistory() throws {
        var old = remote().localTimer()
        old.beginReflection(now: now + 2000, manual: true)
        var draft = try XCTUnwrap(old.reflection)
        draft.notes = "Original recovery"
        try repository.saveRecoveredSession(draft)
        try repository.updateSession(id: draft.id, notes: "Edited later")
        try repository.saveRecoveredSession(draft)
        XCTAssertEqual(try repository.sessions().first?.notes, "Edited later")
    }

    func testWatchSaveEditsExistingHistoryWhilePreservingUnrelatedLiveTimer() throws {
        let sync = DatabaseSyncStore(database: database)
        var old = remote().localTimer()
        old.beginReflection(now: now + 2000, manual: true)
        let draft = try XCTUnwrap(old.reflection)
        try repository.save(draft)
        for op in try outbox() { try sync.removeOp(op.opId) }
        try repository.saveTimer(old, deviceId: "phone", mirror: false)
        try sync.setRemoteTimer(remote(start: now + 5000, updated: now + 5000))
        let snapshot = try repository.watchSnapshot()
        let commands = [
            WatchCommand(action: .editReflection, at: now + 6000, sessionStart: draft.startedAt, notes: "Watch edit preserved", rating: 5),
            WatchCommand(action: .save, at: now + 7000, sessionStart: draft.startedAt, notes: "Watch edit preserved", rating: 5),
        ]
        let result = try repository.receiveWatch(WatchBatch(revision: snapshot.revision, commands: commands), deviceId: "phone")
        XCTAssertEqual(result.timer.startedAt, now + 5000)
        XCTAssertNil(result.timer.reflection)
        XCTAssertEqual(try repository.sessions().first?.notes, "Watch edit preserved")
        XCTAssertEqual(try repository.sessions().first?.rating, 5)
        let ops = try outbox().map { try JSONDecoder().decode(SyncOp.self, from: Data($0.payload.utf8)) }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.kind, .sessionComplete)
        XCTAssertEqual(ops.first?.payload["journalOnly"], .bool(true))
        let replay = try repository.receiveWatch(WatchBatch(revision: snapshot.revision, commands: commands), deviceId: "phone")
        XCTAssertFalse(replay.conflict)
        XCTAssertEqual(try repository.pendingCount(), 1)
    }

    func testSameServerOriginStillCarriesStaleLocalSittingActionIdentity() throws {
        var stale = TimerState.idle
        stale.start(kind: .focus, intention: "A", category: "deep", targetMs: 1000, now: now)
        try repository.saveTimer(stale, deviceId: "phone")
        var fresh = stale
        fresh.abandon()
        try repository.saveTimer(fresh, deviceId: "phone")
        fresh.start(kind: .focus, intention: "B", category: "deep", targetMs: 1000, now: now + 5000)
        try repository.saveTimer(fresh, deviceId: "watch-phone")
        fresh.pause(now: now + 6000)
        try repository.saveTimer(fresh, deviceId: "watch-phone")
        stale.pause(now: now + 2000)
        try repository.saveTimer(stale, deviceId: "phone")
        let ops = try outbox().map { try JSONDecoder().decode(SyncOp.self, from: Data($0.payload.utf8)) }
        XCTAssertEqual(ops.last?.payload["actionSessionStart"], .number(Double(now)),
                       "Even a same-origin chain must retain the action's original sitting identity")
        XCTAssertNotEqual(ops.last?.payload["actionSessionStart"], ops[ops.count - 2].payload["startedAt"])
    }

    func testConsolidatedWatchStartBatchUsesInitialSnapshotActionIdentity() throws {
        let snapshot = try repository.watchSnapshot()
        let commands = [WatchCommand(action: .start, at: now, minutes: 1)]
        _ = try repository.receiveWatch(WatchBatch(revision: snapshot.revision, commands: commands), deviceId: "phone")
        let row = try XCTUnwrap(outbox().first)
        let op = try JSONDecoder().decode(SyncOp.self, from: Data(row.payload.utf8))
        XCTAssertEqual(op.payload["actionSessionStart"], .null)
        XCTAssertEqual(op.payload["startedAt"], .number(Double(now)))
    }

    func testWatchCompletionThenAutoBreakMirrorUsesResultingIdleIdentity() throws {
        try DatabaseSyncStore(database: database).setRemoteTimer(remote())
        let initial = try repository.watchSnapshot()
        XCTAssertTrue(initial.preferences.autoStartBreak)
        let commands = [
            WatchCommand(action: .finish, at: now + 2000, sessionStart: now),
            WatchCommand(action: .save, at: now + 3000, sessionStart: now, notes: "Finished focus"),
        ]
        let response = try repository.receiveWatch(WatchBatch(revision: initial.revision, commands: commands), deviceId: "phone")
        XCTAssertEqual(response.timer.kind, .rest)
        let ops = try outbox().map { try JSONDecoder().decode(SyncOp.self, from: Data($0.payload.utf8)) }
        let completion = try XCTUnwrap(ops.first(where: { $0.kind == .sessionComplete }))
        let mirror = try XCTUnwrap(ops.first(where: { $0.kind == .timerMirror }))
        XCTAssertNil(completion.payload["journalOnly"])
        XCTAssertEqual(mirror.payload["afterTimerOpId"], .string(completion.opId))
        XCTAssertEqual(mirror.payload["actionSessionStart"], .null,
                       "Completion retires focus before the break mirror is applied")
        XCTAssertEqual(mirror.payload["startedAt"], .number(Double(now + 2000)))
    }

}
