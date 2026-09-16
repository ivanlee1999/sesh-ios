import Foundation

/**
 The wire, exactly as the server speaks it.

 These types are a contract, not a convenience: every field name and every
 optional here mirrors `sesh-web`'s `/api/sync`. The fixtures in the tests are
 real captured responses rather than hand-written samples, because a protocol
 that is only ever tested against its own idea of itself will agree with itself
 right up until it meets the server.
 */

/// Any JSON value — settings hold numbers, strings and booleans alike.
public enum JSONValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}

// ── Operations the client pushes ────────────────────────────────────────

public enum SyncOpKind: String, Codable, Sendable {
    case sessionComplete = "session.complete"
    case sessionUpsert = "session.upsert"
    case sessionDelete = "session.delete"
    case categoryUpsert = "category.upsert"
    case categoryDelete = "category.delete"
    case settingsSet = "settings.set"
    case timerMirror = "timer.mirror"
}

public struct SyncOp: Equatable, Sendable, Codable {
    public let opId: String
    public let kind: SyncOpKind
    public let payload: [String: JSONValue]

    public init(opId: String = UUID().uuidString, kind: SyncOpKind, payload: [String: JSONValue]) {
        self.opId = opId
        self.kind = kind
        self.payload = payload
    }
}

public struct SyncRequest: Equatable, Sendable, Codable {
    public let deviceId: String
    public let cursor: Int
    public let limit: Int?
    public let ops: [SyncOp]

    public init(deviceId: String, cursor: Int, limit: Int? = nil, ops: [SyncOp] = []) {
        self.deviceId = deviceId
        self.cursor = cursor
        self.limit = limit
        self.ops = ops
    }
}

// ── What comes back ─────────────────────────────────────────────────────

public enum OpStatus: String, Sendable, Codable {
    /// Done.
    case applied
    /// Already done — this op arrived twice, and the first answer stands.
    case duplicate
    /// The server's copy is newer; the client's edit loses and the pull carries the winner.
    case stale
    /// Refused, with a reason. Sometimes with the row that won instead.
    case rejected
}

public struct OpResult: Equatable, Sendable, Codable {
    public let opId: String
    public let status: OpStatus
    public let error: String?
    /// The category the server used instead — a slug renamed or deleted while away.
    public let category: RemoteCategory?
    /// Why a category could not be deleted.
    public let sessionCount: Int?
}

public struct RemoteSession: Equatable, Sendable, Codable {
    public let id: String
    public let intention: String
    public let category: String
    public let type: SessionKind
    public let targetMs: Int
    public let actualMs: Int
    public let overflowMs: Int
    public let startedAt: Millis
    public let endedAt: Millis
    public let notes: String
    public let rating: Int
    public let todoistTaskId: String?
    public let updatedAt: Millis
    /// Non-nil means deleted elsewhere: the client drops its own copy.
    public let deletedAt: Millis?

    public var session: Session {
        Session(
            id: id, intention: intention, category: category, type: type,
            targetMs: targetMs, actualMs: actualMs, overflowMs: overflowMs,
            startedAt: startedAt, endedAt: endedAt, notes: notes, rating: rating,
            todoistTaskId: todoistTaskId
        )
    }
}

public struct RemoteCategory: Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let label: String
    public let color: String
    public let sortOrder: Int
    public let isDefault: Bool
    public let updatedAt: Millis?
    public let deletedAt: Millis?
}

public struct RemoteSetting: Equatable, Sendable, Codable {
    public let key: String
    public let value: JSONValue
    public let updatedAt: Millis
}

public struct SyncChanges: Equatable, Sendable, Codable {
    public let sessions: [RemoteSession]
    public let categories: [RemoteCategory]
    public let settings: [RemoteSetting]
}

public struct RemoteTimer: Equatable, Sendable, Codable {
    public let phase: String
    public let sessionType: String
    public let intention: String
    public let category: String
    public let targetMs: Int
    public let remainingMs: Int
    public let overflowMs: Int
    public let startedAt: Millis?
    public let pausedAt: Millis?
    public let updatedAt: Millis
    public let todoistTaskId: String?
    public let deviceId: String?

    public var isRunning: Bool { phase == "running" || phase == "paused" }

    /**
     Whether this timer belongs to some other device.

     Never adopted automatically. A timer running on the laptop is information,
     not an instruction — silently taking it over would be the app deciding, on
     its own, what the person is currently doing.
     */
    public func belongsToAnotherDevice(_ myDeviceId: String) -> Bool {
        isRunning && (deviceId ?? "") != myDeviceId
    }

    /// What the dial would read now, rebuilt from the server's own clock.
    public func remainingMs(now: Millis) -> Int {
        remainingMs - Int(now - updatedAt)
    }
}

public struct SyncResponse: Equatable, Sendable, Codable {
    public let results: [OpResult]
    public let changes: SyncChanges
    public let cursor: Int
    public let hasMore: Bool
    public let timer: RemoteTimer?
    public let serverTime: Millis
}

// ── Auth ────────────────────────────────────────────────────────────────

public struct TokenResponse: Equatable, Sendable, Codable {
    public let token: String
    public let expiresAt: Millis
    public let username: String?
    public let authDisabled: Bool?

    /// Refreshed well before expiry, so a phone that syncs rarely is never
    /// caught holding a dead token with work still queued behind it.
    public func needsRefresh(now: Millis, window: Millis = 7 * 24 * 60 * 60 * 1000) -> Bool {
        expiresAt - now < window
    }
}
