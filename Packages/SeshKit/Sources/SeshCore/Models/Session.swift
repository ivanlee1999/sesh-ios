import Foundation

/// Epoch milliseconds — the unit every timestamp crossing the wire is in.
public typealias Millis = Int64

/**
 What kind of sitting a session was.

 Not an enum, despite looking like one. The live database holds a third value —
 `short`, left over from an older version of the app — and roughly a quarter of
 the existing history is filed under it. A closed enum refuses to decode that,
 and because a sync response arrives as one document, a single unrecognised row
 costs the client the entire page: no sessions, no categories, no cursor. The
 first sync against real data would simply have failed, and gone on failing.

 So the raw value is kept exactly as it arrives, whatever it is, and questions
 are asked of it rather than of a case list. An unknown kind round-trips back
 to the server unchanged instead of being quietly rewritten to something we
 recognise.
 */
public struct SessionKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let focus = SessionKind(rawValue: "focus")
    /// `break` is a keyword in Swift; it is not on the wire.
    public static let rest = SessionKind(rawValue: "break")

    /// Focus is the one kind that counts toward a day's total and its streak,
    /// which is exactly how the web app's analytics treat it.
    public var isFocus: Bool { rawValue == "focus" }

    /// Anything that is not focus is a pause of some sort — including `short`.
    public var isRest: Bool { !isFocus }
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
