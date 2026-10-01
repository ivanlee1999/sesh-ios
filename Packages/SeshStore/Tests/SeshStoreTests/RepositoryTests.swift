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

    func testOnlyTheNewestTimerPositionIsWorthSending() throws {
        // Otherwise every pause and resume would leave a stale countdown queued.
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Deep", category: "deep", targetMs: 1_500_000, now: now)
        try repository.saveTimer(timer, deviceId: "iphone")
        timer.pause(now: now + 1000)
        try repository.saveTimer(timer, deviceId: "iphone")
        timer.resume(now: now + 2000)
        try repository.saveTimer(timer, deviceId: "iphone")

        let mirrors = try outbox().filter { $0.kind == SyncOpKind.timerMirror.rawValue }
        XCTAssertEqual(mirrors.count, 1)
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

}
