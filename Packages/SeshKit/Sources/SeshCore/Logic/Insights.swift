import Foundation

/**
 What the Insights tab shows, computed here rather than fetched.

 The web app asks the server, which answers in a timezone hard-coded to
 `America/Los_Angeles` — correct for exactly one person in one place, and
 wrong for them the moment they travel. More to the point, a phone with every
 session already on it has no reason to ask anyone: this works in a tunnel,
 and it answers in the timezone the person is actually standing in.
 */
public struct DayTotal: Equatable, Sendable {
    public let key: String
    public let label: String
    public let ms: Int
}

public struct CategoryTotal: Equatable, Sendable {
    public let category: String
    public let ms: Int
    public let share: Double
}

public struct Insights: Equatable, Sendable {
    public let todayMs: Int
    public let todayCount: Int
    public let streak: Int
    public let days: [DayTotal]
    public let categories: [CategoryTotal]
    /// Actual over planned, across every focus session with a target.
    public let planAccuracy: Double?

    public static func compute(
        sessions: [Session],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        dayCount: Int = 7,
        topCategories: Int = 4
    ) -> Insights {
        // Breaks are not focus; they are the gaps between it.
        let focus = sessions.filter { $0.type == .focus }

        let todayKey = DayKey.key(for: now, timeZone: timeZone)
        let bucketed = Dictionary(grouping: focus) { session in
            DayKey.key(for: Date(timeIntervalSince1970: Double(session.startedAt) / 1000), timeZone: timeZone)
        }

        let todaySessions = bucketed[todayKey] ?? []

        var days: [DayTotal] = []
        var key = todayKey
        for _ in 0..<max(1, dayCount) {
            days.append(DayTotal(
                key: key,
                label: Self.weekdayLabel(key, timeZone: timeZone),
                ms: (bucketed[key] ?? []).reduce(0) { $0 + $1.actualMs }
            ))
            key = DayKey.previous(key)
        }
        days.reverse()

        /*
         Walk back a day at a time until a day has nothing in it. Today being
         empty does not end the streak — it is not over yet — so the walk starts
         from yesterday when today is blank, or a streak would collapse every
         morning before the first session.
         */
        var streak = 0
        var cursor = todaySessions.isEmpty ? DayKey.previous(todayKey) : todayKey
        while !(bucketed[cursor] ?? []).isEmpty {
            streak += 1
            cursor = DayKey.previous(cursor)
        }

        // Spelled out in steps with explicit types: as one chained expression
        // the type-checker gives up on it.
        let totalMs: Int = focus.reduce(0) { $0 + $1.actualMs }
        let grouped: [String: [Session]] = Dictionary(grouping: focus, by: { $0.category })
        var byCategory: [CategoryTotal] = []
        for (name, rows) in grouped {
            let ms: Int = rows.reduce(0) { $0 + $1.actualMs }
            let share: Double = totalMs > 0 ? Double(ms) / Double(totalMs) : 0
            byCategory.append(CategoryTotal(category: name, ms: ms, share: share))
        }
        byCategory.sort { $0.ms == $1.ms ? $0.category < $1.category : $0.ms > $1.ms }

        let planned = focus.filter { $0.targetMs > 0 }
        let plannedMs = planned.reduce(0) { $0 + $1.targetMs }
        let actualMs = planned.reduce(0) { $0 + $1.actualMs }

        return Insights(
            todayMs: todaySessions.reduce(0) { $0 + $1.actualMs },
            todayCount: todaySessions.count,
            streak: streak,
            days: days,
            categories: Array(byCategory.prefix(topCategories)),
            planAccuracy: plannedMs > 0 ? Double(actualMs) / Double(plannedMs) : nil
        )
    }

    static func weekdayLabel(_ key: String, timeZone: TimeZone) -> String {
        let millis = DayKey.startOfDayMillis(key, timeZone: timeZone)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}
