import XCTest
import GRDB
import SeshCore
import SeshStore
@testable import sesh

@MainActor
final class SharedAppModelTests: XCTestCase {
    private func setup() throws -> (AppDatabase, AppModel, Millis) {
        let database = try AppDatabase.inMemory()
        let repository = SeshRepository(database: database)
        try repository.setSetting(key: AppSettings.Key.autoStartBreak.rawValue, value: .bool(false))
        let start = Millis(Date().timeIntervalSince1970 * 1000) - 120_000
        let remote = RemoteTimer(phase: "running", sessionType: "focus", intention: "Old focus",
            category: "deep", targetMs: 1_500_000, remainingMs: 1_380_000, overflowMs: 0,
            startedAt: start, pausedAt: nil, updatedAt: start + 120_000, todoistTaskId: nil, deviceId: "mac")
        try DatabaseSyncStore(database: database).setRemoteTimer(remote)
        let model = AppModel(database: database, serverURL: URL(string: "http://127.0.0.1:9")!)
        return (database, model, start)
    }

    private func adoptNewSession(_ database: AppDatabase, oldStart: Millis) throws -> Millis {
        let newStart = oldStart + 90_000
        let remote = RemoteTimer(phase: "running", sessionType: "focus", intention: "New Mac session",
            category: "deep", targetMs: 1_500_000, remainingMs: 1_470_000, overflowMs: 0,
            startedAt: newStart, pausedAt: nil, updatedAt: newStart + 30_000, todoistTaskId: nil, deviceId: "mac")
        // In these tests the queued pause represents an acknowledged transition.
        try database.writer.write { try $0.execute(sql: "DELETE FROM outboxItem WHERE kind = 'timer.mirror'") }
        try DatabaseSyncStore(database: database).setRemoteTimer(remote)
        return newStart
    }

    func testFailedFinishNotesAndSaveDoNotReplaceNewerCanonicalSession() throws {
        let (database, model, start) = try setup()
        try database.writer.write {
            try $0.execute(sql: "CREATE TRIGGER fail_timer BEFORE UPDATE ON timerRow BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END")
        }
        model.finish(manual: true)
        XCTAssertNotNil(model.reflecting)
        XCTAssertNotNil(model.reflectionError)
        try database.writer.write { try $0.execute(sql: "DROP TRIGGER fail_timer") }
        let newStart = try adoptNewSession(database, oldStart: start)
        model.reload()
        model.editReflection(notes: "Retained after failure", rating: 5)
        XCTAssertEqual(try model.repository.loadTimer().startedAt, newStart)
        XCTAssertTrue(model.saveReflection())
        XCTAssertEqual(try model.repository.loadTimer().startedAt, newStart)
        XCTAssertEqual(model.timer.startedAt, newStart)
        let saved = try model.repository.sessions().first { $0.startedAt == start }
        XCTAssertEqual(saved?.notes, "Retained after failure")
        XCTAssertEqual(saved?.rating, 5)
    }

    func testNormalReflectionEditsAndSavePreserveNewSessionBeforeUIReload() throws {
        let (database, model, start) = try setup()
        model.finish(manual: true)
        let newStart = try adoptNewSession(database, oldStart: start)
        // Deliberately do not reload AppModel: exercise the stale UI window.
        model.editReflection(notes: "Canonical edit", rating: 4)
        XCTAssertEqual(model.timer.startedAt, newStart)
        XCTAssertEqual(try model.repository.loadTimer().startedAt, newStart)
        XCTAssertTrue(model.saveReflection())
        XCTAssertEqual(try model.repository.loadTimer().startedAt, newStart)
        XCTAssertEqual(try model.repository.sessions().first { $0.startedAt == start }?.notes, "Canonical edit")
    }

    func testOrdinarySaveWithoutUIReloadPreservesNewerSession() throws {
        let (database, model, start) = try setup()
        model.finish(manual: true)
        let newStart = try adoptNewSession(database, oldStart: start)
        XCTAssertTrue(model.saveReflection())
        XCTAssertEqual(try model.repository.loadTimer().startedAt, newStart)
        XCTAssertEqual(model.timer.startedAt, newStart)
    }
}
