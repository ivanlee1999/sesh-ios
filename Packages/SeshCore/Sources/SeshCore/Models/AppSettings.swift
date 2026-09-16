import Foundation

/**
 The settings, which are shared with every other device.

 Stored key by key rather than as one blob, because that is how the server keeps
 them and how conflicts are settled: changing the focus length on a phone and
 dark mode on a laptop within the same minute should leave both changed, not one
 overwriting the other with a stale copy of everything else.

 Anything genuinely about *this* device — how wide a pane is, which calendar
 view was last open — is not here. It belongs in `UserDefaults`, unsynced, for
 the same reason the web app keeps it out: a phone should not impose its layout
 on a monitor.
 */
public struct AppSettings: Equatable, Sendable {
    public var displayName: String
    public var focusDuration: Int
    public var breakDuration: Int
    public var longBreakDuration: Int
    public var sessionsBeforeLongBreak: Int
    public var soundEnabled: Bool
    public var calendarSync: Bool
    public var darkMode: Bool
    public var keepScreenAwake: Bool
    public var autoStartBreak: Bool
    public var autoStartFocus: Bool
    public var todoistEnabled: Bool
    public var accentColor: String

    public static let defaults = AppSettings(
        displayName: "there",
        focusDuration: 25,
        breakDuration: 5,
        longBreakDuration: 15,
        sessionsBeforeLongBreak: 4,
        soundEnabled: true,
        calendarSync: false,
        darkMode: false,
        keepScreenAwake: true,
        autoStartBreak: true,
        autoStartFocus: false,
        todoistEnabled: true,
        accentColor: Accent.defaultAccent
    )

    public enum Key: String, CaseIterable, Sendable {
        case displayName, focusDuration, breakDuration, longBreakDuration
        case sessionsBeforeLongBreak, soundEnabled, calendarSync, darkMode
        case keepScreenAwake, autoStartBreak, autoStartFocus, todoistEnabled, accentColor
    }

    /// Take one key's worth of a pulled settings table, leaving the rest alone.
    public mutating func apply(key: String, value: JSONValue) {
        guard let key = Key(rawValue: key) else { return }
        switch key {
        case .displayName: displayName = value.stringValue ?? displayName
        case .focusDuration: focusDuration = value.intValue ?? focusDuration
        case .breakDuration: breakDuration = value.intValue ?? breakDuration
        case .longBreakDuration: longBreakDuration = value.intValue ?? longBreakDuration
        case .sessionsBeforeLongBreak: sessionsBeforeLongBreak = value.intValue ?? sessionsBeforeLongBreak
        case .soundEnabled: soundEnabled = value.boolValue ?? soundEnabled
        case .calendarSync: calendarSync = value.boolValue ?? calendarSync
        case .darkMode: darkMode = value.boolValue ?? darkMode
        case .keepScreenAwake: keepScreenAwake = value.boolValue ?? keepScreenAwake
        case .autoStartBreak: autoStartBreak = value.boolValue ?? autoStartBreak
        case .autoStartFocus: autoStartFocus = value.boolValue ?? autoStartFocus
        case .todoistEnabled: todoistEnabled = value.boolValue ?? todoistEnabled
        case .accentColor: accentColor = value.stringValue ?? accentColor
        }
    }

    public func value(for key: Key) -> JSONValue {
        switch key {
        case .displayName: return .string(displayName)
        case .focusDuration: return .number(Double(focusDuration))
        case .breakDuration: return .number(Double(breakDuration))
        case .longBreakDuration: return .number(Double(longBreakDuration))
        case .sessionsBeforeLongBreak: return .number(Double(sessionsBeforeLongBreak))
        case .soundEnabled: return .bool(soundEnabled)
        case .calendarSync: return .bool(calendarSync)
        case .darkMode: return .bool(darkMode)
        case .keepScreenAwake: return .bool(keepScreenAwake)
        case .autoStartBreak: return .bool(autoStartBreak)
        case .autoStartFocus: return .bool(autoStartFocus)
        case .todoistEnabled: return .bool(todoistEnabled)
        case .accentColor: return .string(accentColor)
        }
    }

    /// The length a session of this kind should start at.
    public func duration(for kind: SessionKind, longBreak: Bool = false) -> Int {
        if kind.isFocus { return focusDuration }
        return longBreak ? longBreakDuration : breakDuration
    }

    public func targetMs(for kind: SessionKind, longBreak: Bool = false) -> Int {
        duration(for: kind, longBreak: longBreak) * 60_000
    }
}

/**
 How many focus sessions have been finished today, which decides when a break
 is a long one.

 Device-local and reset each day, exactly as in the web app: it is a property of
 this morning's run of work, not a fact about the account worth syncing.
 */
public struct PomodoroCycle: Equatable, Sendable, Codable {
    public var count: Int
    public var dayKey: String

    public init(count: Int = 0, dayKey: String = "") {
        self.count = count
        self.dayKey = dayKey
    }

    public func today(_ key: String) -> Int {
        dayKey == key ? count : 0
    }

    public mutating func increment(on key: String) -> Int {
        count = today(key) + 1
        dayKey = key
        return count
    }

    /// A long break lands on every nth finished focus session.
    public func isLongBreakDue(after count: Int, every interval: Int) -> Bool {
        interval > 0 && count % interval == 0
    }
}
