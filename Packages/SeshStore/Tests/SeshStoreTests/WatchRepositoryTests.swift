import XCTest
import GRDB
import SeshCore
@testable import SeshStore

final class WatchRepositoryTests: XCTestCase {
    let start: Millis = 1_000_000
    func command(_ action: WatchCommand.Action, _ offset: Millis = 0) -> WatchCommand {
        .init(action: action, at: start + offset, sessionStart: start, minutes: 1)
    }
    func repository() throws -> SeshRepository {
        try SeshRepository(database: .inMemory(), clock: { 2_000_000 })
    }

    func testDuplicateDeliveryAfterReconnectCreatesOneCompletion() throws {
        let repo = try repository()
        let revision = try repo.watchSnapshot().revision
        let batch = WatchBatch(revision: revision, commands: [command(.start), command(.finish, 70_000), command(.save, 71_000)])
        let first = try repo.receiveWatch(batch, deviceId: "phone")
        let second = try repo.receiveWatch(batch, deviceId: "phone")
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(first.timer, second.timer)
        XCTAssertEqual(second.accepted.count, 3)
        XCTAssertEqual(try repo.sessions().count, 1)
        let completions = try repo.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outboxItem WHERE kind = 'session.complete'")
        }
        XCTAssertEqual(completions, 1)
    }

    func testPhoneEndRejectsStaleOfflineStartEvenWhenIdleAgain() throws {
        let repo = try repository()
        let baseline = try repo.watchSnapshot()
        var phone = TimerState.idle
        phone.start(kind: .focus, intention: "Phone", category: "deep", targetMs: 60_000, now: start + 100)
        try repo.saveTimer(phone, deviceId: "phone")
        _ = try repo.watchSnapshot()
        try repo.saveTimer(.idle, deviceId: "phone")
        let result = try repo.receiveWatch(.init(revision: baseline.revision, commands: [command(.start)]), deviceId: "phone")
        XCTAssertTrue(result.conflict)
        XCTAssertEqual(try repo.loadTimer(), .idle)
        XCTAssertTrue(result.accepted.isEmpty)
    }

    func testReorderedBatchIsRejectedAtomically() throws {
        let repo = try repository()
        let baseline = try repo.watchSnapshot()
        let result = try repo.receiveWatch(.init(revision: baseline.revision, commands: [command(.pause, 5000), command(.start)]), deviceId: "phone")
        XCTAssertTrue(result.conflict)
        XCTAssertEqual(try repo.loadTimer(), .idle)
        XCTAssertEqual(try repo.sessions().count, 0)
    }

    func testActionsSentBeforePreviousReceiptReconcilePrefix() throws {
        let repo = try repository()
        let baseline = try repo.watchSnapshot()
        let first = command(.start)
        _ = try repo.receiveWatch(.init(revision: baseline.revision, commands: [first]), deviceId: "phone")
        let second = command(.pause, 5000)
        let result = try repo.receiveWatch(.init(revision: baseline.revision, commands: [first, second]), deviceId: "phone")
        XCTAssertFalse(result.conflict)
        XCTAssertEqual(result.timer.phase, .paused)
        XCTAssertEqual(result.accepted, [first.id, second.id])
    }

    func testStorageFailureRollsBackTimerHistoryAndReceipts() throws {
        let repo = try repository()
        let baseline = try repo.watchSnapshot()
        try repo.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_watch_receipt BEFORE INSERT ON watchReceipt BEGIN SELECT RAISE(ABORT, 'disk failure'); END")
        }
        let batch = WatchBatch(revision: baseline.revision, commands: [command(.start), command(.finish, 70_000), command(.save, 71_000)])
        XCTAssertThrowsError(try repo.receiveWatch(batch, deviceId: "phone"))
        XCTAssertEqual(try repo.loadTimer(), .idle)
        XCTAssertTrue(try repo.sessions().isEmpty)
        try repo.writer.write { try $0.execute(sql: "DROP TRIGGER reject_watch_receipt") }
        XCTAssertFalse(try repo.receiveWatch(batch, deviceId: "phone").conflict)
        XCTAssertEqual(try repo.sessions().count, 1)
    }

    func testRecoveryImportIsIdempotentAndPreservesActiveTimer() throws {
        let repo = try repository()
        var timer = TimerState.idle
        timer.start(kind: .focus, intention: "Phone", category: "deep", targetMs: 60_000, now: start)
        try repo.saveTimer(timer, deviceId: "phone")
        let baseline = try repo.watchSnapshot()
        let session = Session(id: Session.id(startedAt: start + 1), category: "deep", actualMs: 60_000, startedAt: start + 1, endedAt: start + 60_001)
        let batch = WatchBatch(revision: baseline.revision, commands: [], recovered: [session])
        _ = try repo.receiveWatch(batch, deviceId: "phone")
        _ = try repo.receiveWatch(batch, deviceId: "phone")
        XCTAssertEqual(try repo.loadTimer(), timer)
        XCTAssertEqual(try repo.sessions().count, 1)
    }

    func testDeniedWatchAlertsRetainPhoneFallbackAndRevocationRelinquishes() throws {
        let repo = try repository()
        let baseline = try repo.watchSnapshot()
        let first = command(.start)
        let result = try repo.receiveWatch(.init(revision: baseline.revision, commands: [first], watchCanAlert: false), deviceId: "phone")
        XCTAssertFalse(result.alertsOnWatch)
        let second = command(.pause, 1000)
        let owned = try repo.receiveWatch(.init(revision: result.revision, commands: [second], watchCanAlert: true), deviceId: "phone")
        XCTAssertTrue(owned.alertsOnWatch)
        XCTAssertTrue(try repo.watchSnapshot().alertsOnWatch)
        let revoked = try repo.receiveWatch(.init(revision: owned.revision, commands: [], watchCanAlert: false), deviceId: "phone")
        XCTAssertFalse(revoked.alertsOnWatch)
    }

    func testLostReceiptThenRevokedPermissionRestoresFallbackOnDuplicateBatch() throws {
        let repo = try repository()
        let baseline = try repo.watchSnapshot()
        let first = command(.start)
        _ = try repo.receiveWatch(.init(revision: baseline.revision, commands: [first], watchCanAlert: true), deviceId: "phone")
        let result = try repo.receiveWatch(.init(revision: baseline.revision, commands: [first], watchCanAlert: false), deviceId: "phone")
        XCTAssertFalse(result.alertsOnWatch)
        XCTAssertEqual(result.accepted, [first.id])
    }

    func testReceiptPersistsAcrossRepositoryRecreation() throws {
        let database = try AppDatabase.inMemory()
        let repo = SeshRepository(database: database)
        let baseline = try repo.watchSnapshot()
        let first = command(.start)
        _ = try repo.receiveWatch(.init(revision: baseline.revision, commands: [first]), deviceId: "phone")
        let restored = SeshRepository(database: database)
        let result = try restored.receiveWatch(.init(revision: baseline.revision, commands: [first]), deviceId: "phone")
        XCTAssertEqual(result.accepted, [first.id])
        XCTAssertFalse(result.conflict)
    }
}
