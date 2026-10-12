import Foundation
import GRDB
import SeshCore

/**
 The sync engine's view of the database.

 Everything the engine asks for happens in one transaction per call, so a run
 interrupted halfway — the app suspended, the phone out of battery — leaves the
 database in a state the next run can simply continue from.

 The conflict rules are not repeated here. They live in `Merge.decide`, and this
 type's job is to ask it once per row and do what it says.
 */
public final class DatabaseSyncStore: SyncStore, @unchecked Sendable {
    private let database: AppDatabase
    private let clock: @Sendable () -> Millis

    public init(database: AppDatabase, clock: @escaping @Sendable () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.database = database
        self.clock = clock
    }

    private var writer: any DatabaseWriter { database.writer }

    // ── Identity and position ───────────────────────────────────────────

    public func deviceId() throws -> String {
        try writer.read { db in
            try SyncStateRecord.fetchOne(db, key: 1)?.deviceId ?? ""
        }
    }

    public func cursor() throws -> Int {
        try writer.read { db in
            try SyncStateRecord.fetchOne(db, key: 1)?.cursor ?? 0
        }
    }

    public func setCursor(_ cursor: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE syncStateRow SET cursor = ?, lastPullAt = ?, lastError = NULL WHERE id = 1",
                arguments: [cursor, clock()]
            )
        }
    }

    public func recordSyncError(_ message: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE syncStateRow SET lastError = ? WHERE id = 1", arguments: [message])
        }
    }

    // ── The outbox ──────────────────────────────────────────────────────

    public func dueOps(now: Millis, limit: Int) throws -> [OutboxRecord] {
        try writer.write { db in
            let rows = try OutboxRecordRow
                .filter(Column("nextAttemptAt") <= now)
                .order(Column("createdAt"), Column("rowid"))
                .limit(limit)
                .fetchAll(db)

            var ready: [OutboxRecord] = []
            for row in rows {
                if let decoded = try Self.upgradeLegacyTimerOp(db, row: row) {
                    // A delayed predecessor must not be bypassed by a later
                    // action merely because its retry delay has not elapsed.
                    if case .data(let op) = decoded.op,
                       let predecessor = op.payload["afterTimerOpId"]?.stringValue,
                       try OutboxRecordRow.fetchOne(db, key: predecessor) != nil,
                       !ready.contains(where: { $0.opId == predecessor }) { continue }
                    ready.append(decoded)
                } else {
                    /*
                     A payload that will not decode can never be sent. Skipping
                     it quietly left it in the table for good: never sent, never
                     removed, and still counted on the Settings screen as
                     something waiting to sync, with no way to clear it.
                     */
                    try OutboxRecordRow.deleteOne(db, key: row.opId)
                }
            }
            return ready
        }
    }

    public func removeOp(_ opId: String) throws {
        try writer.write { db in
            if let row = try OutboxRecordRow.fetchOne(db, key: opId),
               row.kind == SyncOpKind.timerMirror.rawValue || row.kind == SyncOpKind.sessionComplete.rawValue,
               let item = Self.decode(row), case .data(let op) = item.op,
               op.payload["journalOnly"] != .bool(true) {
                let baseline = try Row.fetchOne(db, sql: "SELECT updatedAt, startedAt FROM timerOpBaseline WHERE opId = ?", arguments: [opId])
                let updatedAt: Millis = baseline?["updatedAt"] ?? 0
                let startedAt: Millis? = baseline?["startedAt"]
                try db.execute(sql: "INSERT OR REPLACE INTO sharedTimerAck (id, opId, updatedAt, startedAt) VALUES (1, ?, ?, ?)",
                               arguments: [opId, updatedAt, startedAt])
                try db.execute(sql: "DELETE FROM timerOpBaseline WHERE opId = ?", arguments: [opId])
            }
            _ = try OutboxRecordRow.deleteOne(db, key: opId)
        }
    }

    public func deferOp(_ opId: String, attempts: Int, nextAttemptAt: Millis, error: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE outboxItem SET attempts = ?, nextAttemptAt = ?, lastError = ? WHERE opId = ?",
                arguments: [attempts, nextAttemptAt, error, opId]
            )
        }
    }

    // ── Applying what came back ─────────────────────────────────────────

    public func apply(_ changes: SyncChanges) throws {
        try writer.write { db in
            for remote in changes.sessions {
                let local = try SessionRecord.fetchOne(db, key: remote.id)
                let decision = Merge.decide(
                    local: local.map { LocalRowState(updatedAt: $0.updatedAt, dirty: $0.dirty) },
                    remoteUpdatedAt: remote.updatedAt,
                    remoteDeleted: remote.deletedAt != nil
                )
                switch decision {
                case .keepLocal:
                    continue
                case .deleteLocal:
                    // Removed here rather than tombstoned: the server keeps the
                    // marker so other devices learn of it, and this one has now
                    // learned. Keeping our own copy of the gravestone would only
                    // mean filtering it out of every query forever.
                    _ = try SessionRecord.deleteOne(db, key: remote.id)
                case .takeRemote:
                    try SessionRecord(remote: remote).save(db)
                }
            }

            for remote in changes.categories {
                let local = try CategoryRecord.fetchOne(db, key: remote.id)
                let decision = Merge.decide(
                    local: local.map { LocalRowState(updatedAt: $0.updatedAt, dirty: $0.dirty) },
                    remoteUpdatedAt: remote.updatedAt ?? 0,
                    remoteDeleted: remote.deletedAt != nil
                )
                switch decision {
                case .keepLocal:
                    continue
                case .deleteLocal:
                    _ = try CategoryRecord.deleteOne(db, key: remote.id)
                case .takeRemote:
                    /*
                     A rename arrives as the same id under a new slug. Sessions
                     are filed by slug, so they have to follow it here exactly as
                     they did on the server — otherwise a year of history detaches
                     from its own category and shows up grey and nameless.
                     */
                    if let previous = local, previous.name != remote.name {
                        try Self.repointCategory(db, from: previous.name, to: remote.name)
                    }
                    /*
                     The same slug under a different id. That is what a phone
                     seeded with the default categories looks like the first
                     time it meets a server that seeded its own: both have a
                     `deep`, neither has the other's id, and `name` is unique,
                     so saving would fail the constraint and take the whole
                     page down with it. The server's copy is the one that
                     matters — sessions are filed by slug, so dropping the
                     local row detaches nothing.
                     */
                    try db.execute(
                        sql: "DELETE FROM category WHERE name = ? AND id <> ?",
                        arguments: [remote.name, remote.id]
                    )
                    try CategoryRecord(remote: remote).save(db)
                }
            }

            for remote in changes.settings {
                let local = try SettingRecord.fetchOne(db, key: remote.key)
                if let local, local.dirty, local.updatedAt > remote.updatedAt { continue }
                let encoded = (try? JSONEncoder().encode(remote.value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                try SettingRecord(key: remote.key, value: encoded, updatedAt: remote.updatedAt, dirty: false).save(db)
            }
        }
    }

    public func remapCategory(from oldSlug: String, to newSlug: String) throws {
        guard oldSlug != newSlug else { return }
        try writer.write { db in
            try Self.repointCategory(db, from: oldSlug, to: newSlug)
        }
    }

    /**
     Point everything that named the old slug at the new one.

     Takes an open `db` rather than opening its own, because it is called from
     inside `apply` — which is already in a transaction, and nesting a second
     write inside it would deadlock.

     The queue is rewritten as well as the rows. An op still carrying the old
     slug would be refused by the server for exactly the reason this rename
     arrived, and the next sync would spend its run learning the same thing
     again.
     */
    static func repointCategory(_ db: Database, from oldSlug: String, to newSlug: String) throws {
        guard oldSlug != newSlug else { return }
        try db.execute(sql: "UPDATE session SET category = ? WHERE category = ?", arguments: [newSlug, oldSlug])

        for row in try OutboxRecordRow.fetchAll(db) {
            guard let data = row.payload.data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var payload = object["payload"] as? [String: Any]
            else { continue }

            // A data op stores its SyncOpKind as the row kind; a category op
            // names its slug under "name", everything else under "category".
            let key = (row.kind == SyncOpKind.categoryUpsert.rawValue || row.kind == SyncOpKind.categoryDelete.rawValue)
                ? "name" : "category"
            guard payload[key] as? String == oldSlug else { continue }

            payload[key] = newSlug
            object["payload"] = payload
            if let updated = try? JSONSerialization.data(withJSONObject: object),
               let text = String(data: updated, encoding: .utf8) {
                try db.execute(sql: "UPDATE outboxItem SET payload = ? WHERE opId = ?", arguments: [text, row.opId])
            }
        }
    }

    public func recordTimerConflict(_ opId: String) throws {
        try writer.write { db in
            guard let failed = try OutboxRecordRow.fetchOne(db, key: opId),
                  let row = try TimerRecord.fetchOne(db, key: 1) else { return }
            var timer = try JSONDecoder().decode(TimerState.self, from: Data(row.state.utf8))
            if timer.reflection == nil {
                let completion = failed.kind == SyncOpKind.sessionComplete.rawValue ? failed :
                    try OutboxRecordRow.fetchOne(db, sql: "SELECT * FROM outboxItem WHERE kind = 'session.complete' ORDER BY rowid DESC LIMIT 1")
                if let completion, let item = Self.decode(completion), case .data(let op) = item.op,
                   let sessionID = op.payload["id"]?.stringValue,
                   let session = try SessionRecord.fetchOne(db, key: sessionID) {
                    timer.reflection = session.session
                }
            }
            // Repeated refusals in a causal chain keep one copy; a later
            // unrelated conflict must never overwrite an older saved draft.
            if let previous = try String.fetchOne(db, sql: "SELECT state FROM timerRecovery WHERE notice = 1 ORDER BY id DESC LIMIT 1") {
                var prior = try JSONDecoder().decode(TimerState.self, from: Data(previous.utf8))
                if timer.reflection == nil, timer.isActive { prior.reflection = nil }
                if prior == timer { return }
            }
            if timer.isActive, timer.reflection == nil {
                timer.reflection = timer.draftSession(now: clock(), manual: true)
            }
            let recovery = String(decoding: try JSONEncoder().encode(timer), as: UTF8.self)
            try db.execute(sql: "INSERT OR IGNORE INTO timerRecovery (state, notice, opId, savedAt) VALUES (?, 1, ?, ?)",
                           arguments: [recovery, opId, clock()])
        }
    }

    public func setRemoteTimer(_ timer: RemoteTimer?) throws {
        let payload = try timer.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try writer.write { db in
            // Baseline is persisted even with unsent controls. Each queued
            // operation already carries the version it actually acted against.
            try db.execute(sql: "UPDATE remoteTimerRow SET payload = ?, seenAt = ? WHERE id = 1",
                           arguments: [payload, clock()])
            try db.execute(sql: "DELETE FROM sharedTimerAck")
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outboxItem WHERE \(SeshRepository.timerMutationSQL)") ?? 0
            guard pending == 0 else { return }
            var adopted = timer?.localTimer() ?? .idle
            let row = try TimerRecord.fetchOne(db, key: 1)
            let local = try row.map { try JSONDecoder().decode(TimerState.self, from: Data($0.state.utf8)) } ?? .idle
            // Intention, category and selected tasks on the ready screen are
            // local preparation, not a shared session. An idle poll refreshes
            // the server baseline without erasing what the person is typing.
            if local.phase == .idle, adopted.phase == .idle {
                let baseline = adopted.sharedBaseline
                adopted = local
                adopted.sharedBaseline = baseline
            }
            // Reflection belongs to history work, independent of who owns the
            // next live sitting. Never discard notes when the shared timer moves.
            adopted.reflection = local.reflection
            if local.startedAt == adopted.startedAt, adopted.phase == .paused, local.phase == .reflect {
                adopted.phase = .reflect
            }
            if local.startedAt == adopted.startedAt {
                adopted.retainedReflection = local.retainedReflection
            } else if adopted.reflection == nil {
                adopted.reflection = local.retainedReflection
            }
            guard adopted != local else { return }
            try TimerRecord(id: 1, state: String(decoding: try JSONEncoder().encode(adopted), as: UTF8.self),
                            updatedAt: timer?.updatedAt ?? clock()).save(db)
        }
    }

    /// Build 3 queued unguarded mirrors. Upgrade them conservatively, rather
    /// than letting an old offline sitting silently replace a running Mac one.
    private static func upgradeLegacyTimerOp(_ db: Database, row: OutboxRecordRow) throws -> OutboxRecord? {
        guard let decoded = decode(row) else { return nil }
        guard case .data(let op) = decoded.op,
              op.kind == .timerMirror || op.kind == .sessionComplete,
              op.payload["journalOnly"] != .bool(true),
              op.payload["expectedUpdatedAt"] == nil, op.payload["afterTimerOpId"] == nil else { return decoded }
        var payload = op.payload
        if let predecessor = try String.fetchOne(db, sql: """
            SELECT opId FROM outboxItem WHERE \(SeshRepository.timerMutationSQL)
            AND rowid < (SELECT rowid FROM outboxItem WHERE opId = ?)
            ORDER BY rowid DESC LIMIT 1
            """, arguments: [row.opId]) {
            payload["afterTimerOpId"] = .string(predecessor)
        } else {
            payload["expectedUpdatedAt"] = .number(0)
            payload["expectedStartedAt"] = .null
        }
        if op.kind == .timerMirror { payload["recordedAt"] = .number(Double(row.createdAt)) }
        try db.execute(sql: "INSERT OR IGNORE INTO timerOpBaseline (opId, updatedAt, startedAt) VALUES (?, 0, NULL)", arguments: [op.opId])
        let guarded = SyncOp(opId: op.opId, kind: op.kind, payload: payload)
        let text = String(decoding: try JSONEncoder().encode(guarded), as: UTF8.self)
        try db.execute(sql: "UPDATE outboxItem SET payload = ?, coalesceKey = NULL WHERE opId = ?", arguments: [text, row.opId])
        return OutboxRecord(opId: row.opId, op: .data(guarded), attempts: row.attempts, createdAt: row.createdAt)
    }

    // ── Encoding ────────────────────────────────────────────────────────

    /// The stored JSON, back into something the engine can send.
    static func decode(_ row: OutboxRecordRow) -> OutboxRecord? {
        guard let data = row.payload.data(using: .utf8) else { return nil }

        if row.kind == OutboxKind.task.rawValue {
            guard let command = try? JSONDecoder().decode(TaskCommand.self, from: data) else { return nil }
            return OutboxRecord(opId: row.opId, op: .task(command), attempts: row.attempts, createdAt: row.createdAt)
        }
        guard let op = try? JSONDecoder().decode(SyncOp.self, from: data) else { return nil }
        return OutboxRecord(opId: row.opId, op: .data(op), attempts: row.attempts, createdAt: row.createdAt)
    }
}

/**
 What an outbox row's `kind` column holds.

 A task command stores `task`. A data op stores its own `SyncOpKind` — the
 literal `"session.complete"`, `"category.upsert"` and so on — rather than
 `data`, so the queue can be read without decoding every payload. `data` is
 therefore the name of the category, never a stored value.
 */
public enum OutboxKind: String, Sendable {
    /// Replicated state, sent in a batch through `/api/sync`. Never stored as-is.
    case data
    /// A command to Todoist or Things, sent one at a time to its own endpoint.
    case task
}
