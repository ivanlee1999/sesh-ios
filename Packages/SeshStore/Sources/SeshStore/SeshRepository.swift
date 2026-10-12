import Foundation
import GRDB
import SeshCore

/**
 Every write the app makes.

 The rule this type exists to enforce: a change is written to the local database
 and queued for the server **in the same transaction**. Never one without the
 other. If they could come apart, a session could be saved and never sent, or
 sent and never saved — and the second is worse, because the phone would show
 an hour that no longer exists anywhere.

 Nothing here awaits the network. The screens call these and are done; the sync
 engine catches up later, or tomorrow, or on the train home.
 */
public final class SeshRepository: Sendable {
    private let database: AppDatabase
    private let clock: @Sendable () -> Millis

    public init(database: AppDatabase, clock: @escaping @Sendable () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }) {
        self.database = database
        self.clock = clock
    }

    public var writer: any DatabaseWriter { database.writer }
    public var reader: any DatabaseReader { database.writer }

    func now() -> Millis { clock() }

    // ── Queueing ────────────────────────────────────────────────────────

    /// Timer writes keep their causal chain: removing an intermediate pause can
    /// make a later resume overwrite a different sitting after reconnecting.
    func enqueue(_ db: Database, op: SyncOp, coalesceKey: String? = nil) throws {
        if op.payload["journalOnly"] == .bool(true), try OutboxRecordRow.fetchOne(db, key: op.opId) != nil { return }
        var queued = op
        let timerMutation = op.kind == .timerMirror || (op.kind == .sessionComplete && op.payload["journalOnly"] != .bool(true))
        if timerMutation {
            var payload = op.payload
            try Self.guardTimerPayload(db, payload: &payload, opId: op.opId)
            if op.kind == .timerMirror, payload["recordedAt"] == nil { payload["recordedAt"] = .number(Double(now())) }
            queued = SyncOp(opId: op.opId, kind: op.kind, payload: payload)
        } else if let coalesceKey {
            try db.execute(sql: "DELETE FROM outboxItem WHERE coalesceKey = ?", arguments: [coalesceKey])
        }
        let payload = String(decoding: try JSONEncoder().encode(queued), as: UTF8.self)
        try OutboxRecordRow(
            opId: op.opId, kind: op.kind.rawValue, payload: payload,
            coalesceKey: timerMutation ? nil : coalesceKey,
            createdAt: now(), attempts: 0, nextAttemptAt: 0, lastError: nil
        ).insert(db)
    }

    static let timerMutationSQL = "kind IN ('timer.mirror', 'session.complete') AND CASE WHEN json_valid(payload) THEN COALESCE(json_extract(payload, '$.payload.journalOnly'), 0) ELSE 0 END = 0"

    static func guardTimerPayload(_ db: Database, payload: inout [String: JSONValue], opId: String) throws {
        let row = try TimerRecord.fetchOne(db, key: 1)
        let local = try row.map { try JSONDecoder().decode(TimerState.self, from: Data($0.state.utf8)) }
        let baseline = TimerBaseline(
            updatedAt: payload["expectedUpdatedAt"]?.doubleValue.map { Millis($0) } ?? local?.sharedBaseline?.updatedAt ?? 0,
            startedAt: payload["expectedUpdatedAt"] != nil ? payload["expectedStartedAt"]?.doubleValue.map { Millis($0) } : local?.sharedBaseline?.startedAt)
        // Keep the displayed causal context outside the wire payload, even
        // after a predecessor receipt supersedes its version guard.
        try db.execute(sql: "INSERT INTO timerOpBaseline (opId, updatedAt, startedAt) VALUES (?, ?, ?)",
                       arguments: [opId, baseline.updatedAt, baseline.startedAt])
        let predecessor = try Row.fetchOne(db, sql: """
            SELECT outboxItem.opId, timerOpBaseline.updatedAt, timerOpBaseline.startedAt
            FROM outboxItem LEFT JOIN timerOpBaseline USING (opId)
            WHERE \(Self.timerMutationSQL)
            ORDER BY outboxItem.rowid DESC LIMIT 1
            """) ?? Row.fetchOne(db, sql: "SELECT opId, updatedAt, startedAt FROM sharedTimerAck WHERE id = 1")
        if let predecessor, let stamp: Millis = predecessor["updatedAt"],
           stamp == baseline.updatedAt, (predecessor["startedAt"] as Millis?) == baseline.startedAt {
            // Only actions from the same displayed context may extend this
            // chain. A stale A action must never become authorized by B's pause.
            payload["afterTimerOpId"] = .string(predecessor["opId"] as String)
            payload.removeValue(forKey: "expectedUpdatedAt")
            payload.removeValue(forKey: "expectedStartedAt")
        } else {
            payload.removeValue(forKey: "afterTimerOpId")
            payload["expectedUpdatedAt"] = .number(Double(baseline.updatedAt))
            payload["expectedStartedAt"] = baseline.startedAt.map { .number(Double($0)) } ?? .null
        }
    }

    static func remoteTimer(_ db: Database) throws -> RemoteTimer? {
        guard let row = try RemoteTimerRecord.fetchOne(db, key: 1), let payload = row.payload else { return nil }
        return try JSONDecoder().decode(RemoteTimer.self, from: Data(payload.utf8))
    }

    func enqueue(_ db: Database, command: TaskCommand, opId: String = UUID().uuidString) throws {
        let payload = String(data: try JSONEncoder().encode(command), encoding: .utf8) ?? "{}"
        try OutboxRecordRow(
            opId: opId, kind: OutboxKind.task.rawValue, payload: payload, coalesceKey: nil,
            createdAt: now(), attempts: 0, nextAttemptAt: 0, lastError: nil
        ).insert(db)
    }

    /// How much is waiting to be sent, and what went wrong last — for Settings.
    public func pendingCount() throws -> Int {
        try reader.read { db in try OutboxRecordRow.fetchCount(db) }
    }

    public func syncState() throws -> SyncStateRecord? {
        try reader.read { db in try SyncStateRecord.fetchOne(db, key: 1) }
    }

    // ── Sessions ────────────────────────────────────────────────────────

    /**
     Record a finished session.

     The one place the app turns a timer into history. Note what is *not* here:
     any writing back of minutes to Things or Todoist. The server does that when
     the session reaches it, from the refs the session carries — so the phone
     keeps one durable operation with one retry policy instead of a session and
     a scatter of task writes that can each fail on their own.
     */
    @discardableResult
    public func save(_ session: Session) throws -> Session {
        let stamp = now()
        try writer.write { db in
            let existing = try SessionRecord.fetchOne(db, key: session.id)
            try SessionRecord(session: session, updatedAt: stamp, dirty: true).save(db)

            // A session saved again — a rating added after the poster, a title
            // corrected — is an edit, not a second sitting.
            let kind: SyncOpKind = existing == nil ? .sessionComplete : .sessionUpsert
            try enqueue(db, op: SyncOp(kind: kind, payload: Self.payload(for: session, updatedAt: stamp, full: kind == .sessionComplete)))
        }
        return session
    }

    /// History, its single completion operation, and timer transition commit together.
    /// Retrying a final Save after success cannot enqueue a second completion.
    @discardableResult
    public func save(_ session: Session, replacingTimer state: TimerState,
                     deviceId: String, requiringReflection: Bool = false) throws -> Bool {
        let stamp = now()
        return try writer.write { db in
            let row = try TimerRecord.fetchOne(db, key: 1)
            let current = try row.map { try JSONDecoder().decode(TimerState.self, from: Data($0.state.utf8)) }
            if requiringReflection, current?.reflection?.id != session.id { return false }
            let completesCurrent = current?.startedAt == session.startedAt
            var next = current ?? state
            if completesCurrent {
                next.abandon()
                // The preceding completion has retired the shared identity;
                // the following mirror acts against its resulting idle state.
                next.controlSessionStart = nil
            }
            if next.reflection?.id == session.id { next.reflection = nil }
            if next.retainedReflection?.id == session.id { next.retainedReflection = nil }
            var payload = Self.payload(for: session, updatedAt: stamp, full: true)
            if !completesCurrent { payload["journalOnly"] = .bool(true) }
            // An explicit Save can contain new notes even for history that
            // already exists. Immutable recovery imports alone reuse an op ID.
            let opId = UUID().uuidString
            try SessionRecord(session: session, updatedAt: stamp, dirty: true).save(db)
            try enqueue(db, op: SyncOp(opId: opId, kind: .sessionComplete, payload: payload))
            try TimerRecord(id: 1, state: String(decoding: try JSONEncoder().encode(next), as: UTF8.self), updatedAt: stamp).save(db)
            if completesCurrent {
                try enqueue(db, op: SyncOp(kind: .timerMirror, payload: next.mirrorPayload(now: stamp, deviceId: deviceId)))
            }
            return true
        }
    }

    public enum ReflectionEditError: Error { case missingDraft }

    /// Reflection edits may race a shared snapshot. Replace just this draft,
    /// never restore the cached timer's old session identity or wire baseline.
    public func editReflection(_ draft: Session) throws -> TimerState {
        try writer.write { db in
            guard let row = try TimerRecord.fetchOne(db, key: 1) else { throw ReflectionEditError.missingDraft }
            var current = try JSONDecoder().decode(TimerState.self, from: Data(row.state.utf8))
            guard current.reflection?.id == draft.id else { throw ReflectionEditError.missingDraft }
            current.reflection = draft
            try TimerRecord(id: 1, state: String(decoding: try JSONEncoder().encode(current), as: UTF8.self), updatedAt: now()).save(db)
            return current
        }
    }

    /// Save an older failed reflection as history without restoring its timer
    /// over the canonical shared sitting that arrived in the meantime.
    public func saveDetachedReflection(_ session: Session, deviceId: String) throws -> TimerState {
        let stamp = now()
        return try writer.write { db in
            let row = try TimerRecord.fetchOne(db, key: 1)
            var current = try row.map { try JSONDecoder().decode(TimerState.self, from: Data($0.state.utf8)) } ?? .idle
            let completesCurrent = current.startedAt == session.startedAt
            let recoveryOpID = "journal-recovery-\(session.id)"
            if try completesCurrent || OutboxRecordRow.fetchOne(db, key: recoveryOpID) == nil {
                try SessionRecord(session: session, updatedAt: stamp, dirty: true).save(db)
            }
            // A previous refused Save may already exist locally but not on the
            // server. Full completion can create it and remains idempotent by
            // sitting identity. Journal-only recovery never controls B's timer.
            var payload = Self.payload(for: session, updatedAt: stamp, full: true)
            if !completesCurrent { payload["journalOnly"] = .bool(true) }
            let opId = completesCurrent ? UUID().uuidString : "journal-recovery-\(session.id)"
            try enqueue(db, op: SyncOp(opId: opId, kind: .sessionComplete, payload: payload))
            if completesCurrent {
                current.abandon()
                current.controlSessionStart = nil
            }
            if current.reflection?.id == session.id { current.reflection = nil }
            if current.retainedReflection?.id == session.id { current.retainedReflection = nil }
            try TimerRecord(id: 1, state: String(decoding: try JSONEncoder().encode(current), as: UTF8.self), updatedAt: stamp).save(db)
            if completesCurrent {
                try enqueue(db, op: SyncOp(kind: .timerMirror, payload: current.mirrorPayload(now: stamp, deviceId: deviceId)))
            }
            return current
        }
    }

    /// Explicitly recover recorded work into history without controlling the
    /// current shared timer. Full completion can create a refused local Save.
    public func saveRecoveredSession(_ session: Session) throws {
        let stamp = now()
        try writer.write { db in
            let existing = try SessionRecord.fetchOne(db, key: session.id)
            let recovered = existing?.session ?? session
            if existing == nil { try SessionRecord(session: session, updatedAt: stamp, dirty: true).save(db) }
            var payload = Self.payload(for: recovered, updatedAt: stamp, full: true)
            payload["journalOnly"] = .bool(true)
            try enqueue(db, op: SyncOp(opId: "journal-recovery-\(session.id)", kind: .sessionComplete, payload: payload))
        }
    }

    public func updateSession(
        id: String,
        intention: String? = nil,
        category: String? = nil,
        notes: String? = nil,
        rating: Int? = nil,
        taskRefs: String?? = nil
    ) throws {
        let stamp = now()
        try writer.write { db in
            guard var record = try SessionRecord.fetchOne(db, key: id) else { return }
            if let intention { record.intention = intention }
            if let category { record.category = category }
            if let notes { record.notes = notes }
            if let rating { record.rating = max(0, min(5, rating)) }
            if let taskRefs { record.taskRefs = taskRefs }
            record.updatedAt = stamp
            record.dirty = true
            try record.save(db)

            var payload: [String: JSONValue] = [
                "id": .string(id),
                "intention": .string(record.intention),
                "category": .string(record.category),
                "notes": .string(record.notes),
                "rating": .number(Double(record.rating)),
                "updatedAt": .number(Double(stamp)),
            ]
            payload["todoistTaskId"] = record.taskRefs.map { JSONValue.string($0) } ?? .null
            try enqueue(db, op: SyncOp(kind: .sessionUpsert, payload: payload))
        }
    }

    public func deleteSession(id: String) throws {
        let stamp = now()
        try writer.write { db in
            _ = try SessionRecord.deleteOne(db, key: id)
            try enqueue(db, op: SyncOp(kind: .sessionDelete, payload: [
                "id": .string(id),
                "deletedAt": .number(Double(stamp)),
            ]))
        }
    }

    static func payload(for session: Session, updatedAt: Millis, full: Bool) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "id": .string(session.id),
            "intention": .string(session.intention),
            "category": .string(session.category),
            "notes": .string(session.notes),
            "rating": .number(Double(session.rating)),
            "updatedAt": .number(Double(updatedAt)),
        ]
        payload["todoistTaskId"] = session.todoistTaskId.map { JSONValue.string($0) } ?? .null

        if full {
            // Timings travel only with the completion. They are set by whoever
            // ran the session and are not revised afterwards.
            payload["type"] = .string(session.type.rawValue)
            payload["targetMs"] = .number(Double(session.targetMs))
            payload["actualMs"] = .number(Double(session.actualMs))
            payload["overflowMs"] = .number(Double(session.overflowMs))
            payload["startedAt"] = .number(Double(session.startedAt))
            payload["endedAt"] = .number(Double(session.endedAt))
        }
        return payload
    }

    // ── The timer ───────────────────────────────────────────────────────

    public func loadTimer() throws -> TimerState {
        try reader.read { db in
            guard let row = try TimerRecord.fetchOne(db, key: 1),
                  let data = row.state.data(using: .utf8),
                  let state = try? JSONDecoder().decode(TimerState.self, from: data)
            else { return .idle }
            return state
        }
    }

    /**
     Persist the timer and tell the server about it.

     Written synchronously before the caller returns, so a phone killed by the
     system a second later comes back to exactly the session it was running. The
     mirror retains the causal sequence of every local control action.
     */
    public func saveTimer(_ state: TimerState, deviceId: String, mirror: Bool = true) throws {
        let stamp = now()
        let encoded = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? "{}"
        try writer.write { db in
            try TimerRecord(id: 1, state: encoded, updatedAt: stamp).save(db)
            guard mirror else { return }

            let payload = state.mirrorPayload(now: stamp, deviceId: deviceId)
            try enqueue(db, op: SyncOp(kind: .timerMirror, payload: payload), coalesceKey: "timer")
        }
    }

    public func remoteTimer() throws -> RemoteTimer? {
        try reader.read { db in try Self.remoteTimer(db) }
    }

    /// A rejected control never destroys the unsent local sitting or its notes.
    /// Clearing the notice leaves the recovery draft available across relaunch.
    public func timerConflict() throws -> TimerState? {
        try reader.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT state FROM timerRecovery WHERE notice = 1 ORDER BY id DESC LIMIT 1") else { return nil }
            let state: String = row["state"]
            return try JSONDecoder().decode(TimerState.self, from: Data(state.utf8))
        }
    }

    public func recoveredTimer() throws -> TimerState? {
        try reader.read { db in
            guard let state = try String.fetchOne(db, sql: "SELECT state FROM timerRecovery ORDER BY id DESC LIMIT 1") else { return nil }
            return try JSONDecoder().decode(TimerState.self, from: Data(state.utf8))
        }
    }

    public func recoveredTimers() throws -> [TimerState] {
        try reader.read { db in
            try String.fetchAll(db, sql: "SELECT state FROM timerRecovery ORDER BY id DESC").map {
                try JSONDecoder().decode(TimerState.self, from: Data($0.utf8))
            }
        }
    }

    public func resolveTimerConflict() throws {
        try writer.write { db in try db.execute(sql: "UPDATE timerRecovery SET notice = 0") }
    }

    // ── Categories ──────────────────────────────────────────────────────

    /// Every session still standing, newest first.
    public func sessions() throws -> [Session] {
        try reader.read { db in try SessionRecord.live.fetchAll(db) }.map(\.session)
    }

    /// What each task source last told us, for the header and Settings.
    public func taskSources() throws -> [TaskSourceRecord] {
        try reader.read { db in try TaskSourceRecord.fetchAll(db) }
    }

    public func deviceId() throws -> String {
        try reader.read { db in try SyncStateRecord.fetchOne(db, key: 1)?.deviceId ?? "" }
    }

    public func categories() throws -> [CategoryRecord] {
        try reader.read { db in try CategoryRecord.live.fetchAll(db) }
    }

    @discardableResult
    public func saveCategory(id: String? = nil, label: String, color: String) throws -> CategoryRecord {
        let stamp = now()
        let categoryId = id ?? UUID().uuidString

        return try writer.write { db in
            let existing = try CategoryRecord.fetchOne(db, key: categoryId)

            /*
             The slug follows the label only when the label actually changed.

             Deriving it unconditionally re-slugs a category that nobody
             renamed: the server's `deep` is labelled "Deep Work", so picking a
             new colour for it would quietly refile it — and every session
             under it — as `deep-work`, disagreeing with the server about the
             one value they join on. A slug is a name a row was given, not a
             function of its current label.
             */
            let slug: String = {
                guard let existing else { return Self.slugify(label) }
                return existing.label == label ? existing.name : Self.slugify(label)
            }()

            // Checked in the same transaction as the write, for the same
            // reason the in-use count is: the constraint is the database's,
            // so the answer has to come from there too.
            if let clash = try CategoryRecord.filter(Column("name") == slug).fetchOne(db),
               clash.id != categoryId {
                throw CategoryNameTaken(label: clash.label)
            }

            let order = try existing?.sortOrder
                ?? ((try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM category") ?? -1) + 1)

            // A rename has to carry the sessions filed under the old slug, here
            // just as on the server.
            if let existing, existing.name != slug {
                try db.execute(sql: "UPDATE session SET category = ? WHERE category = ?", arguments: [slug, existing.name])
            }

            let record = CategoryRecord(
                id: categoryId, name: slug, label: label, color: color,
                sortOrder: order, isDefault: existing?.isDefault ?? false,
                updatedAt: stamp, deletedAt: nil, dirty: true
            )
            try record.save(db)

            try enqueue(db, op: SyncOp(kind: .categoryUpsert, payload: [
                "id": .string(categoryId),
                "name": .string(slug),
                "label": .string(label),
                "color": .string(color),
                "sortOrder": .number(Double(order)),
                "isDefault": .bool(record.isDefault),
                "updatedAt": .number(Double(stamp)),
            ]))
            return record
        }
    }

    /// How many sessions stand behind a category — what makes deleting it refusable.
    public func sessionCount(forCategory name: String) throws -> Int {
        try reader.read { db in
            try SessionRecord.live.filter(Column("category") == name).fetchCount(db)
        }
    }

    /// Refused when sessions still stand behind it — they are filed by its slug
    /// and would lose their name and colour.
    public struct CategoryInUse: Error {
        public let sessionCount: Int
    }

    /**
     Refused because another category already answers to that slug.

     `name` is unique, so without this the insert fails as a raw SQLite
     constraint error — which the call site swallowed, leaving someone typing
     a name that silently does nothing. The server refuses the same case in
     the same words.
     */
    public struct CategoryNameTaken: Error {
        public let label: String
    }

    /**
     Delete a category, or refuse to.

     The count is checked inside the same transaction as the delete rather than
     by the caller beforehand: a guard that lives at one call site is a guard
     the next call site will forget, and the cost of forgetting here is a year
     of sessions pointing at a slug that no longer exists.
     */
    public func deleteCategory(id: String) throws {
        let stamp = now()
        try writer.write { db in
            guard let existing = try CategoryRecord.fetchOne(db, key: id) else { return }

            let count = try SessionRecord.live.filter(Column("category") == existing.name).fetchCount(db)
            guard count == 0 else { throw CategoryInUse(sessionCount: count) }

            _ = try CategoryRecord.deleteOne(db, key: id)
            try enqueue(db, op: SyncOp(kind: .categoryDelete, payload: [
                "id": .string(id),
                "deletedAt": .number(Double(stamp)),
            ]))
        }
    }

    static func slugify(_ label: String) -> String {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        // Collapse runs and trim, so "Deep  Work!" and "deep-work" agree.
        let collapsed = String(replaced).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed
    }

    // ── Settings ────────────────────────────────────────────────────────

    public func settings() throws -> AppSettings {
        let rows = try reader.read { db in try SettingRecord.fetchAll(db) }
        var settings = AppSettings.defaults
        for row in rows {
            guard let data = row.value.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }
            settings.apply(key: row.key, value: value)
        }
        return settings
    }

    public func setSetting(key: String, value: JSONValue) throws {
        let stamp = now()
        let encoded = String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "null"
        try writer.write { db in
            try SettingRecord(key: key, value: encoded, updatedAt: stamp, dirty: true).save(db)
            try enqueue(db, op: SyncOp(kind: .settingsSet, payload: [
                "key": .string(key),
                "value": value,
                "updatedAt": .number(Double(stamp)),
            ]))
        }
    }

    // ── Tasks ───────────────────────────────────────────────────────────

    /// Replace one provider's cached list wholesale, keeping anything still pending.
    public func replaceTaskCache(provider: TaskProvider, tasks: [ExternalTask], status: String?, error: String?) throws {
        try writer.write { db in
            let pending = try CachedTaskRecord
                .filter(Column("provider") == provider.rawValue)
                .filter(Column("pendingComplete") == true || Column("pendingCreate") == true)
                .fetchAll(db)
            let pendingRefs = Set(pending.map(\.ref))

            try db.execute(
                sql: "DELETE FROM cachedTask WHERE provider = ? AND pendingComplete = 0 AND pendingCreate = 0",
                arguments: [provider.rawValue]
            )

            for task in tasks {
                let ref = TaskRef(provider: provider, id: task.id).encoded
                // A row still waiting on its own command keeps the state the
                // person put it in; the server does not yet know better.
                if pendingRefs.contains(ref) { continue }
                let json = String(data: (try? JSONEncoder().encode(task)) ?? Data(), encoding: .utf8) ?? "{}"
                try CachedTaskRecord(
                    ref: ref, provider: provider.rawValue, json: json,
                    pendingComplete: false, pendingCreate: false
                ).save(db)
            }

            try TaskSourceRecord(
                provider: provider.rawValue, fetchedAt: now(), statusJSON: status, error: error
            ).save(db)
        }
    }

    public func completeTask(ref: String) throws {
        guard let decoded = TaskRef.decode(ref) else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE cachedTask SET pendingComplete = 1 WHERE ref = ?", arguments: [ref])
            try enqueue(db, command: TaskCommand(kind: .complete, provider: decoded.provider, taskId: decoded.id))
        }
    }

    /**
     A to-do typed with no signal.

     It appears in the list straight away against a placeholder id, because the
     person has made it and should be able to see it. The real id is Things'
     to give, and it arrives with the next refresh.
     */
    public func createTask(title: String, when: String, provider: TaskProvider = .things) throws {
        let placeholder = "pending-\(UUID().uuidString)"
        let task = ExternalTask(
            id: placeholder, provider: provider, content: title,
            projectName: provider == .things ? "Things" : "Todoist",
            dueLabel: when == "today" ? "Today" : nil
        )
        try writer.write { db in
            let json = String(data: (try? JSONEncoder().encode(task)) ?? Data(), encoding: .utf8) ?? "{}"
            try CachedTaskRecord(
                ref: TaskRef(provider: provider, id: placeholder).encoded,
                provider: provider.rawValue, json: json,
                pendingComplete: false, pendingCreate: true
            ).save(db)
            try enqueue(db, command: TaskCommand(kind: .create, provider: provider, title: title, when: when))
        }
    }

    public func cachedTasks() throws -> [ExternalTask] {
        try reader.read { db in
            try CachedTaskRecord
                .filter(Column("pendingComplete") == false)
                .fetchAll(db)
                .compactMap { row in
                    guard let data = row.json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(ExternalTask.self, from: data)
                }
        }
    }
}
