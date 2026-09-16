import Foundation

/**
 A task pulled in from Todoist or Things.

 Both normalise into this one shape on the server, so the list can show them
 together without the screens knowing which is which. Almost everything is
 optional because the two providers genuinely differ — Things has areas and no
 durations, Todoist has durations and no areas — and because these values
 arrive from somebody else's API, where a field can quietly stop being sent.
 */
public struct ExternalTask: Identifiable, Equatable, Sendable, Codable {
    public enum Bucket: String, Sendable, Codable {
        case today, inbox, anytime, upcoming, someday
    }

    public var id: String
    public var provider: TaskProvider?
    public var content: String
    public var duration: Duration?
    public var labels: [String]
    /// 1 is most urgent, 4 is none — normalised across both providers.
    public var priority: Int
    public var projectId: String?
    public var projectName: String?
    public var due: String?
    public var dueLabel: String?
    /// The calendar day itself, `YYYY-MM-DD`, which is what Upcoming sorts on.
    public var dueDate: String?
    public var bucket: Bucket?
    /// A Things area, kept apart from the project so the sidebar can list both.
    public var areaName: String?
    public var category: String?
    public var completed: Bool?

    public struct Duration: Equatable, Sendable, Codable {
        public let amount: Int
        public let unit: String

        public init(amount: Int, unit: String = "minute") {
            self.amount = amount
            self.unit = unit
        }
    }

    public init(
        id: String, provider: TaskProvider? = nil, content: String,
        duration: Duration? = nil, labels: [String] = [], priority: Int = 4,
        projectId: String? = nil, projectName: String? = nil,
        due: String? = nil, dueLabel: String? = nil, dueDate: String? = nil,
        bucket: Bucket? = nil, areaName: String? = nil,
        category: String? = nil, completed: Bool? = nil
    ) {
        self.id = id
        self.provider = provider
        self.content = content
        self.duration = duration
        self.labels = labels
        self.priority = priority
        self.projectId = projectId
        self.projectName = projectName
        self.due = due
        self.dueLabel = dueLabel
        self.dueDate = dueDate
        self.bucket = bucket
        self.areaName = areaName
        self.category = category
        self.completed = completed
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, content, duration, labels, priority, projectId, projectName
        case due, dueLabel, dueDate, bucket, areaName, category, completed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try? c.decodeIfPresent(TaskProvider.self, forKey: .provider)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        duration = try? c.decodeIfPresent(Duration.self, forKey: .duration)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 4
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        dueLabel = try c.decodeIfPresent(String.self, forKey: .dueLabel)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        // An unfamiliar bucket is dropped rather than fatal; the list still shows the task.
        bucket = try? c.decodeIfPresent(Bucket.self, forKey: .bucket)
        areaName = try c.decodeIfPresent(String.self, forKey: .areaName)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed)
    }

    /// Older payloads predate the field, and a missing one must not send a
    /// completion to the wrong app.
    public var resolvedProvider: TaskProvider { provider ?? .todoist }

    public var ref: TaskRef { TaskRef(provider: resolvedProvider, id: id) }

    /// The estimate a session starts from, clamped to something a dial can show.
    public var suggestedMinutes: Int? {
        guard let duration, duration.unit == "minute", duration.amount > 0 else { return nil }
        return max(5, min(60, duration.amount))
    }

    public func dueKind(clock: DayClock) -> DueKind? {
        DayKey.dueKind(dueDate ?? due, clock: clock)
    }
}
