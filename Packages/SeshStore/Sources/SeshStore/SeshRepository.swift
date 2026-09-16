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

    private func now() -> Millis { clock() }

    // ── Queueing ────────────────────────────────────────────────────────

    /**
     Add an op to the outbox, inside whatever transaction is already open.

     `coalesceKey` is for state where only the latest value is worth sending —
     the mirrored timer, which changes on every pause and resume. Keeping a
     queue of stale timer positions would waste the phone's battery telling the
     server about a countdown it can work out for itself.
     */
    func enqueue(_ db: Database, op: SyncOp, coalesceKey: String? = nil) throws {
        if let coalesceKey {
            try db.execute(sql: "DELETE FROM outboxItem WHERE coalesceKey = ?", arguments: [coalesceKey])
        }
        let payload = String(data: try JSONEncoder().encode(op), encoding: .utf8) ?? "{}"
        try OutboxRecordRow(
            opId: op.opId, kind: op.kind.rawValue, payload: payload, coalesceKey: coalesceKey,
            createdAt: now(), attempts: 0, nextAttemptAt: 0, lastError: nil
        ).insert(db)
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
     mirror is coalesced: only the newest position is ever worth sending.
     */
    public func saveTimer(_ state: TimerState, deviceId: String, mirror: Bool = true) throws {
        let stamp = now()
        let encoded = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? "{}"
        try writer.write { db in
            try TimerRecord(id: 1, state: encoded, updatedAt: stamp).save(db)
            guard mirror else { return }

            let payload = state.mirrorPayload(now: stamp, deviceId: deviceId)
            var json: [String: JSONValue] = [:]
            for (key, value) in payload {
                switch value {
                case let v as String: json[key] = .string(v)
                case let v as Int: json[key] = .number(Double(v))
                case let v as Millis: json[key] = .number(Double(v))
                case let v as Double: json[key] = .number(v)
                case let v as Bool: json[key] = .bool(v)
                default: json[key] = .null
                }
            }
            try enqueue(db, op: SyncOp(kind: .timerMirror, payload: json), coalesceKey: "timer")
        }
    }

    public func remoteTimer() throws -> RemoteTimer? {
        try reader.read { db in
            guard let row = try RemoteTimerRecord.fetchOne(db, key: 1),
                  let payload = row.payload,
                  let data = payload.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(RemoteTimer.self, from: data)
        }
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
        let slug = Self.slugify(label)

        return try writer.write { db in
            let existing = try CategoryRecord.fetchOne(db, key: categoryId)
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

    public func deleteCategory(id: String) throws {
        let stamp = now()
        try writer.write { db in
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
