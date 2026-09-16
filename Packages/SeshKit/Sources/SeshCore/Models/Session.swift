import Foundation

/// Epoch milliseconds — the unit every timestamp crossing the wire is in.
public typealias Millis = Int64

public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case focus
    /// `break` is a keyword; the wire value is not.
    case rest = "break"
}

/**
 A finished session.

 The id is derived from the start — `manual-<startedAtMs>` — rather than being a
 fresh uuid, and that is load-bearing rather than cosmetic: it is the same id
 the server's own timer would have given it, so a session completed offline and
 pushed later lands on exactly the row the server may already have written, and
 the two reconcile into one instead of becoming two sessions for one hour.
 */
public struct Session: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var intention: String
    /// The category *slug*, not its label or id — sessions are filed by slug.
    public var category: String
    public var type: SessionKind
    public var targetMs: Int
    public var actualMs: Int
    public var overflowMs: Int
    public var startedAt: Millis
    public var endedAt: Millis
    public var notes: String
    public var rating: Int
    /// Comma-joined provider refs; see `TaskRef`.
    public var todoistTaskId: String?

    public init(
        id: String,
        intention: String = "",
        category: String,
        type: SessionKind = .focus,
        targetMs: Int = 0,
        actualMs: Int = 0,
        overflowMs: Int = 0,
        startedAt: Millis,
        endedAt: Millis,
        notes: String = "",
        rating: Int = 0,
        todoistTaskId: String? = nil
    ) {
        self.id = id
        self.intention = intention
        self.category = category
        self.type = type
        self.targetMs = targetMs
        self.actualMs = actualMs
        self.overflowMs = overflowMs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
        self.rating = rating
        self.todoistTaskId = todoistTaskId
    }

    /// The id a session started at this instant must have, on any client.
    public static func id(startedAt: Millis) -> String { "manual-\(startedAt)" }

    public var minutes: Int { Int((Double(actualMs) / 60_000).rounded()) }

    public var isOverflowing: Bool { overflowMs > 0 }

    /// The refs this session logged time against, decoded.
    public var taskRefs: [TaskRef] { TaskRef.decodeList(todoistTaskId) }
}
