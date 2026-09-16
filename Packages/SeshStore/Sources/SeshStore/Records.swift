import Foundation
import GRDB
import SeshCore

/**
 The stored shapes.

 Each one carries the sync metadata the server keeps too — `updatedAt` to settle
 conflicts, `deletedAt` so a deletion is a fact rather than an absence — plus
 `dirty`, which is this side only: it marks a row changed here and not yet
 acknowledged there.
 */
public struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "session"

    public var id: String
    public var intention: String
    public var category: String
    public var type: String
    public var targetMs: Int
    public var actualMs: Int
    public var overflowMs: Int
    public var startedAt: Millis
    public var endedAt: Millis
    public var notes: String
    public var rating: Int
    public var taskRefs: String?
    public var updatedAt: Millis
    public var deletedAt: Millis?
    public var dirty: Bool

    public init(session: Session, updatedAt: Millis, dirty: Bool, deletedAt: Millis? = nil) {
        self.id = session.id
        self.intention = session.intention
        self.category = session.category
        self.type = session.type.rawValue
        self.targetMs = session.targetMs
        self.actualMs = session.actualMs
        self.overflowMs = session.overflowMs
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.notes = session.notes
        self.rating = session.rating
        self.taskRefs = session.todoistTaskId
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public init(remote: RemoteSession) {
        self.init(session: remote.session, updatedAt: remote.updatedAt, dirty: false, deletedAt: remote.deletedAt)
    }

    public var session: Session {
        Session(
            id: id, intention: intention, category: category, type: SessionKind(rawValue: type),
            targetMs: targetMs, actualMs: actualMs, overflowMs: overflowMs,
            startedAt: startedAt, endedAt: endedAt, notes: notes, rating: rating,
            todoistTaskId: taskRefs
        )
    }

    /// What the day, week and month views are built from: everything still standing.
    public static var live: QueryInterfaceRequest<SessionRecord> {
        SessionRecord.filter(Column("deletedAt") == nil).order(Column("startedAt").desc)
    }
}

public struct CategoryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "category"

    public var id: String
    /// The slug. Sessions are filed by this, never by the label or the id.
    public var name: String
    public var label: String
    public var color: String
    public var sortOrder: Int
    public var isDefault: Bool
    public var updatedAt: Millis
    public var deletedAt: Millis?
    public var dirty: Bool

    public init(
        id: String, name: String, label: String, color: String,
        sortOrder: Int, isDefault: Bool, updatedAt: Millis,
        deletedAt: Millis? = nil, dirty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.color = color
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public init(remote: RemoteCategory) {
        self.init(
            id: remote.id, name: remote.name, label: remote.label, color: remote.color,
            sortOrder: remote.sortOrder, isDefault: remote.isDefault,
            updatedAt: remote.updatedAt ?? 0, deletedAt: remote.deletedAt, dirty: false
        )
    }

    public static var live: QueryInterfaceRequest<CategoryRecord> {
        CategoryRecord.filter(Column("deletedAt") == nil)
            .order(Column("sortOrder"), Column("label"))
    }
}

public struct SettingRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "setting"

    public var key: String
    /// JSON, exactly as the server keeps it, so a value we do not understand survives.
    public var value: String
    public var updatedAt: Millis
    public var dirty: Bool
}

public struct TimerRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "timerRow"

    public var id: Int64
    /// The `TimerState`, as JSON. One column, because it is one value.
    public var state: String
    public var updatedAt: Millis
}

public struct RemoteTimerRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "remoteTimerRow"

    public var id: Int64
    public var payload: String?
    public var seenAt: Millis
}

public struct CachedTaskRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "cachedTask"

    /// The provider-qualified ref, which is what a session stores.
    public var ref: String
    public var provider: String
    public var json: String
    public var pendingComplete: Bool
    public var pendingCreate: Bool

    public var id: String { ref }
}

public struct TaskSourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "taskSource"

    public var provider: String
    public var fetchedAt: Millis?
    public var statusJSON: String?
    public var error: String?

    public var id: String { provider }
}

public struct OutboxRecordRow: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "outboxItem"

    public var opId: String
    public var kind: String
    public var payload: String
    public var coalesceKey: String?
    public var createdAt: Millis
    public var attempts: Int
    public var nextAttemptAt: Millis
    public var lastError: String?

    public var id: String { opId }
}

public struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "syncStateRow"

    public var id: Int64
    public var deviceId: String
    public var cursor: Int
    public var lastPullAt: Millis?
    public var lastError: String?
}
