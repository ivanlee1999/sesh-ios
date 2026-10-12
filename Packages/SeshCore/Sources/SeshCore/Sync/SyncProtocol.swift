import Foundation

/**
 The wire, exactly as the server speaks it.

 These types are a contract, not a convenience: every field name and every
 optional here mirrors `sesh-web`'s `/api/sync`. The fixtures in the tests are
 real captured responses rather than hand-written samples, because a protocol
 that is only ever tested against its own idea of itself will agree with itself
 right up until it meets the server.
 */

/**
 Numbers, read the way they are meant rather than the way they arrive.

 Every quantity in this protocol is a whole number: milliseconds since the
 epoch, a duration, a rating out of five. Swift's decoder is strict about that
 and will refuse `1789517179528.8936` for an `Int64` — and because a sync page
 arrives as one document, refusing one field throws away every row beside it.
 A single malformed timestamp written by some other client would cost this one
 its entire history.

 The server now rounds on the way in, so this should never be needed. It is
 here because "should never" is not a property a client can verify, and losing
 a page of someone's sessions is a poor way to find out.
 */
private extension KeyedDecodingContainer {
    func decodeRounded(_ key: Key) throws -> Millis {
        if let exact = try? decode(Millis.self, forKey: key) { return exact }
        return Millis(try decode(Double.self, forKey: key).rounded())
    }

    /// Absent and null are the same answer here: the server omits a field it has
    /// nothing to say about (a category quoted back inside an op result carries
    /// no timestamps at all), and asking whether it is null would throw.
    func decodeRoundedIfPresent(_ key: Key) throws -> Millis? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let exact = try? decodeIfPresent(Millis.self, forKey: key) { return exact }
        guard let value = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Millis(value.rounded())
    }

    func decodeRoundedInt(_ key: Key) throws -> Int {
        if let exact = try? decode(Int.self, forKey: key) { return exact }
        return Int(try decode(Double.self, forKey: key).rounded())
    }
}

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
    public init(opId: String, status: OpStatus, error: String?, category: RemoteCategory?, sessionCount: Int?, timerConflict: Bool? = nil, timerUpdatedAt: Millis? = nil, timerStartedAt: Millis? = nil) {
        self.timerConflict = timerConflict; self.timerUpdatedAt = timerUpdatedAt; self.timerStartedAt = timerStartedAt
        self.opId = opId; self.status = status; self.error = error
        self.category = category; self.sessionCount = sessionCount
    }

    public let opId: String
    public let status: OpStatus
    public let error: String?
    /// The category the server used instead — a slug renamed or deleted while away.
    public let category: RemoteCategory?
    /// Why a category could not be deleted.
    public let sessionCount: Int?
    public let timerConflict: Bool?
    public let timerUpdatedAt: Millis?
    public let timerStartedAt: Millis?
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

    enum CodingKeys: String, CodingKey {
        case id, intention, category, type, targetMs, actualMs, overflowMs
        case startedAt, endedAt, notes, rating, todoistTaskId, updatedAt, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        intention = try c.decodeIfPresent(String.self, forKey: .intention) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        type = try c.decodeIfPresent(SessionKind.self, forKey: .type) ?? .focus
        targetMs = try c.decodeRoundedInt(.targetMs)
        actualMs = try c.decodeRoundedInt(.actualMs)
        overflowMs = try c.decodeRoundedInt(.overflowMs)
        startedAt = try c.decodeRounded(.startedAt)
        endedAt = try c.decodeRounded(.endedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        rating = try c.decodeRoundedInt(.rating)
        todoistTaskId = try c.decodeIfPresent(String.self, forKey: .todoistTaskId)
        updatedAt = try c.decodeRounded(.updatedAt)
        deletedAt = try c.decodeRoundedIfPresent(.deletedAt)
    }

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

    enum CodingKeys: String, CodingKey {
        case id, name, label, color, sortOrder, isDefault, updatedAt, deletedAt
    }

    public init(id: String, name: String, label: String, color: String,
                sortOrder: Int, isDefault: Bool, updatedAt: Millis?, deletedAt: Millis?) {
        self.id = id; self.name = name; self.label = label; self.color = color
        self.sortOrder = sortOrder; self.isDefault = isDefault
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? Accent.defaultAccent
        sortOrder = try c.decodeRoundedInt(.sortOrder)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        updatedAt = try c.decodeRoundedIfPresent(.updatedAt)
        deletedAt = try c.decodeRoundedIfPresent(.deletedAt)
    }
}

public struct RemoteSetting: Equatable, Sendable, Codable {
    public let key: String
    public let value: JSONValue
    public let updatedAt: Millis

    enum CodingKeys: String, CodingKey { case key, value, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        updatedAt = try c.decodeRounded(.updatedAt)
    }
}

public struct SyncChanges: Equatable, Sendable, Codable {
    public let sessions: [RemoteSession]
    public let categories: [RemoteCategory]
    public let settings: [RemoteSetting]

    public init(sessions: [RemoteSession], categories: [RemoteCategory], settings: [RemoteSetting]) {
        self.sessions = sessions; self.categories = categories; self.settings = settings
    }
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

    enum CodingKeys: String, CodingKey {
        case phase, sessionType, intention, category, targetMs, remainingMs, overflowMs
        case startedAt, pausedAt, updatedAt, todoistTaskId, deviceId
    }

    public init(phase: String, sessionType: String, intention: String, category: String,
                targetMs: Int, remainingMs: Int, overflowMs: Int, startedAt: Millis?,
                pausedAt: Millis?, updatedAt: Millis, todoistTaskId: String?, deviceId: String?) {
        self.phase = phase; self.sessionType = sessionType; self.intention = intention
        self.category = category; self.targetMs = targetMs; self.remainingMs = remainingMs
        self.overflowMs = overflowMs; self.startedAt = startedAt; self.pausedAt = pausedAt
        self.updatedAt = updatedAt; self.todoistTaskId = todoistTaskId; self.deviceId = deviceId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        sessionType = try c.decodeIfPresent(String.self, forKey: .sessionType) ?? "focus"
        intention = try c.decodeIfPresent(String.self, forKey: .intention) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        targetMs = try c.decodeRoundedInt(.targetMs)
        remainingMs = try c.decodeRoundedInt(.remainingMs)
        overflowMs = try c.decodeRoundedInt(.overflowMs)
        startedAt = try c.decodeRoundedIfPresent(.startedAt)
        pausedAt = try c.decodeRoundedIfPresent(.pausedAt)
        updatedAt = try c.decodeRounded(.updatedAt)
        todoistTaskId = try c.decodeIfPresent(String.self, forKey: .todoistTaskId)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
    }

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
        phase == "running" ? remainingMs - Int(now - updatedAt) : remainingMs
    }

    /// Preserve the shared sitting identity and its absolute countdown deadline.
    /// Receiving a snapshot never creates a new session or writes it back.
    public func localTimer() -> TimerState {
        let baseline = TimerBaseline(updatedAt: updatedAt, startedAt: startedAt)
        guard isRunning, let startedAt else { return TimerState(sharedBaseline: baseline) }
        let reference = phase == "paused" ? (pausedAt ?? updatedAt) : updatedAt
        let elapsed = targetMs - remainingMs
        let pausedTotal = max(0, Int(reference - startedAt) - elapsed)
        return TimerState(phase: phase == "paused" ? .paused : .running,
            kind: SessionKind(rawValue: sessionType), intention: intention, category: category,
            targetMs: targetMs, startedAt: startedAt,
            pausedAt: phase == "paused" ? reference : nil, pausedTotalMs: pausedTotal, taskRefs: todoistTaskId, sharedBaseline: baseline)
    }
}

public struct SyncResponse: Equatable, Sendable, Codable {
    public init(results: [OpResult], changes: SyncChanges, cursor: Int, hasMore: Bool,
                timer: RemoteTimer?, serverTime: Millis, timerProtocolVersion: Int? = nil) {
        self.results = results; self.changes = changes; self.cursor = cursor
        self.hasMore = hasMore; self.timer = timer; self.serverTime = serverTime
        self.timerProtocolVersion = timerProtocolVersion
    }

    public let results: [OpResult]
    public let changes: SyncChanges
    public let cursor: Int
    public let hasMore: Bool
    public let timer: RemoteTimer?
    public let serverTime: Millis
    public let timerProtocolVersion: Int?
}

// ── Auth ────────────────────────────────────────────────────────────────

public struct TokenResponse: Equatable, Sendable, Codable {
    public init(token: String, expiresAt: Millis, username: String?, authDisabled: Bool?) {
        self.token = token; self.expiresAt = expiresAt
        self.username = username; self.authDisabled = authDisabled
    }

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
