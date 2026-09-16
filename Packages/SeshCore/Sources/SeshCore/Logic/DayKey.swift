import Foundation

public enum DueKind: String, Sendable {
    case today
    case tomorrow
    case upcoming
}

/**
 Calendar days, kept apart from instants.

 Which day a task belongs to is a fact about the person reading the list, not
 about the machine that served it — the server runs in UTC and its user does
 not. A day key is a plain `YYYY-MM-DD` string for the same reason the web app
 uses one: comparing two of them is exact, whereas comparing two dates drags in
 hours, offsets and the chance of being one day out twice a year.
 */
public struct DayClock: Equatable, Sendable {
    public let today: String
    public let tomorrow: String

    public init(today: String, tomorrow: String) {
        self.today = today
        self.tomorrow = tomorrow
    }

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        let today = DayKey.key(for: now, timeZone: timeZone)
        self.init(today: today, tomorrow: DayKey.next(today))
    }
}

public enum DayKey {
    /// A calendar is built per call rather than shared: the timezone varies, and
    /// a stale one silently files work on the wrong day after travel.
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func key(for date: Date, timeZone: TimeZone = .current) -> String {
        let parts = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func components(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let parts = key.split(separator: "-")
        guard parts.count >= 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return (year, month, day)
    }

    /// Arithmetic on the key itself, in UTC, so a daylight-saving change cannot shift it.
    public static func next(_ key: String) -> String {
        guard let parts = components(key) else { return key }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
        return DayKey.key(for: utc.date(byAdding: .day, value: 1, to: date)!, timeZone: utc.timeZone)
    }

    public static func previous(_ key: String) -> String {
        guard let parts = components(key) else { return key }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
        return DayKey.key(for: utc.date(byAdding: .day, value: -1, to: date)!, timeZone: utc.timeZone)
    }

    /**
     The instant a calendar day begins, in Unix seconds UTC. Things encodes its
     scheduled dates exactly this way, so this is what a stored date compares
     against.
     */
    public static func startOfDayUtcSeconds(_ key: String) -> Int {
        guard let parts = components(key) else { return 0 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
        return Int(date.timeIntervalSince1970)
    }

    /// Midnight local to `timeZone`, in epoch milliseconds — where a day's sessions start.
    public static func startOfDayMillis(_ key: String, timeZone: TimeZone = .current) -> Millis {
        guard let parts = components(key) else { return 0 }
        let cal = calendar(timeZone)
        // `startOfDay` rather than a constructed midnight: on a spring-forward
        // day the hour 00:00 may not exist, and Foundation knows that.
        guard let noon = cal.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) else { return 0 }
        return Millis(cal.startOfDay(for: noon).timeIntervalSince1970 * 1000)
    }

    /// Overdue counts as today — it is what you should be working on now.
    public static func dueKind(_ date: String?, clock: DayClock) -> DueKind? {
        guard let date, date.count >= 10 else { return nil }
        let day = String(date.prefix(10))
        if day <= clock.today { return .today }
        if day == clock.tomorrow { return .tomorrow }
        return .upcoming
    }

    public static func dueLabel(_ date: String?, fallback: String? = nil, clock: DayClock) -> String? {
        switch dueKind(date, clock: clock) {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .upcoming, .none: return fallback ?? date
        }
    }

    /**
     A day key as something worth reading — "Wed, Sep 2" rather than "2026-09-02".
     Formatted in UTC because the key is already a calendar day, not an instant;
     re-interpreting it in a zone would shift it.
     */
    public static func label(_ key: String) -> String {
        guard let parts = components(key) else { return key }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = utc.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}
