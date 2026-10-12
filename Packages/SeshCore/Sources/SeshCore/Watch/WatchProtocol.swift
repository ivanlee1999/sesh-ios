import Foundation

/// Commands carry intent, not a replacement timer. The phone validates the
/// causal revision and replays them with the same rules as the offline Watch.
public struct WatchCommand: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case start, pause, resume, finish, save, editReflection, abandon
    }
    public var id: String
    public var action: Action
    public var at: Millis
    public var sessionStart: Millis?
    public var kind: SessionKind
    public var minutes: Int
    public var intention: String
    public var category: String
    public var notes: String
    public var rating: Int
    public var manual: Bool

    /// Field-specific edits merge with the current durable reflection while the
    /// Watch file lock is held. Rating taps cannot replay stale phone notes.
    public static func reflectionEdit(in timer: TimerState, at: Millis,
                                      notes: String? = nil, rating: Int? = nil) -> WatchCommand {
        .init(action: .editReflection, at: at, sessionStart: timer.reflection?.startedAt,
              notes: notes ?? timer.reflection?.notes ?? "", rating: rating ?? timer.reflection?.rating ?? 0)
    }

    public init(action: Action, at: Millis, sessionStart: Millis? = nil,
                kind: SessionKind = .focus, minutes: Int = 25,
                intention: String = "", category: String = "deep",
                notes: String = "", rating: Int = 0, manual: Bool = true,
                id: String = UUID().uuidString) {
        self.id = id; self.action = action; self.at = at
        self.sessionStart = sessionStart; self.kind = kind; self.minutes = minutes
        self.intention = intention; self.category = category
        self.notes = notes; self.rating = rating; self.manual = manual
    }
}

public struct WatchPreferences: Codable, Equatable, Sendable {
    public struct Category: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var label: String
        public init(name: String, label: String) { self.name = name; self.label = label }
    }
    public var focusMinutes = 25
    public var breakMinutes = 5
    public var longBreakMinutes = 15
    public var sessionsBeforeLongBreak = 4
    public var autoStartBreak = true
    public var autoStartFocus = false
    public var soundEnabled = true
    public var focusCount = 0
    public var categories: [Category] = [.init(name: "deep", label: "Deep Work")]
    public init() {}
}

public struct WatchSnapshot: Codable, Equatable, Sendable {
    public var revision: Int64
    public var timer: TimerState
    public var preferences: WatchPreferences
    public var accepted: [String]
    public var conflict: Bool
    public var recoveredIDs: [String] = []
    public var alertsOnWatch = false
    public var syncMessage: String?
    public init(revision: Int64 = 0, timer: TimerState = .idle,
                preferences: WatchPreferences = .init(), accepted: [String] = [], conflict: Bool = false) {
        self.revision = revision; self.timer = timer; self.preferences = preferences
        self.accepted = accepted; self.conflict = conflict
    }
}

public struct WatchBatch: Codable, Equatable, Sendable {
    public var revision: Int64
    public var commands: [WatchCommand]
    public var recovered: [Session]
    public var watchCanAlert: Bool
    public init(revision: Int64, commands: [WatchCommand], recovered: [Session] = [], watchCanAlert: Bool = false) {
        self.revision = revision; self.commands = commands
        self.recovered = recovered; self.watchCanAlert = watchCanAlert
    }
}

public enum WatchTransitionError: Error { case invalidTransition }

public enum WatchReducer {
    /// Returns history only on an explicit Save, never just at the target.
    public static func apply(_ command: WatchCommand, timer: inout TimerState,
                             preferences: inout WatchPreferences) throws -> Session? {
        switch command.action {
        case .start:
            guard !timer.isActive, timer.reflection == nil,
                  (1...180).contains(command.minutes), command.at > 0 else {
                throw WatchTransitionError.invalidTransition
            }
            timer.start(kind: command.kind, intention: String(command.intention.prefix(500)),
                        category: command.category, targetMs: command.minutes * 60_000, now: command.at)
        case .pause, .resume, .finish, .abandon:
            guard timer.isActive, timer.startedAt == command.sessionStart,
                  command.at >= (timer.pausedAt ?? timer.startedAt ?? 0) else {
                throw WatchTransitionError.invalidTransition
            }
            switch command.action {
            case .pause:
                guard timer.phase == .running else { throw WatchTransitionError.invalidTransition }
                timer.pause(now: command.at)
            case .resume:
                guard timer.phase == .paused else { throw WatchTransitionError.invalidTransition }
                timer.resume(now: command.at)
            case .abandon:
                guard timer.reflection == nil else { throw WatchTransitionError.invalidTransition }
                timer.abandon()
            default:
                guard timer.reflection == nil else { throw WatchTransitionError.invalidTransition }
                if timer.kind.isFocus {
                    let count = preferences.focusCount + 1
                    let long = count % max(1, preferences.sessionsBeforeLongBreak) == 0
                    timer.beginReflection(now: command.at, manual: command.manual,
                        breakTargetMs: preferences.autoStartBreak
                            ? (long ? preferences.longBreakMinutes : preferences.breakMinutes) * 60_000 : nil)
                } else {
                    timer.abandon()
                    if preferences.autoStartFocus {
                        timer.start(kind: .focus, intention: "", category: command.category,
                                    targetMs: preferences.focusMinutes * 60_000, now: command.at)
                    }
                }
            }
        case .editReflection, .save:
            guard var draft = timer.reflection, draft.startedAt == command.sessionStart else {
                throw WatchTransitionError.invalidTransition
            }
            if command.action == .editReflection {
                draft.notes = String(command.notes.prefix(10_000))
                draft.rating = max(0, min(5, command.rating))
                timer.reflection = draft
            } else {
                timer.controlSessionStart = timer.startedAt
                timer.reflection = nil
                if timer.phase == .reflect || timer.startedAt == draft.startedAt { timer.abandon() }
                preferences.focusCount += 1
                return draft
            }
        }
        return nil
    }
}

/// Persisted as one atomic document on Watch; widgets read the same document.
public struct WatchDocument: Codable, Equatable, Sendable {
    public var snapshot = WatchSnapshot()
    public var timer = TimerState.idle
    public var preferences = WatchPreferences()
    public var pending: [WatchCommand] = []
    public var conflict: WatchSnapshot?
    public var recovered: [Session] = []
    public var savedLocally: [Session] = []
    public var importingRecovery = false
    public var lastMinutes = 25
    public var lastCategory = "deep"
    public var watchOwnsAlerts = false
    public var alertsAuthorized = false
    public init() {}

    public mutating func perform(_ raw: WatchCommand) throws {
        var command = raw
        command.intention = String(command.intention.prefix(500))
        command.notes = String(command.notes.prefix(10_000))
        command.category = String(command.category.prefix(200))
        guard conflict == nil, pending.count < 1000 else { throw WatchTransitionError.invalidTransition }
        var next = timer
        var prefs = preferences
        let completed = try WatchReducer.apply(command, timer: &next, preferences: &prefs)
        if let completed { savedLocally.append(completed) }
        timer = next; preferences = prefs; pending.append(command)
        if [.start, .resume, .pause, .finish].contains(command.action) { watchOwnsAlerts = alertsAuthorized }
        if command.action == .start {
            lastMinutes = command.minutes; lastCategory = command.category
        }
    }

    public mutating func receive(_ incoming: WatchSnapshot) {
        // A delayed background snapshot must never resurrect a finished timer.
        guard incoming.revision >= snapshot.revision else { return }
        var acceptedTimer = snapshot.timer
        var acceptedPrefs = snapshot.preferences
        for command in pending.prefix(while: { incoming.accepted.contains($0.id) }) {
            _ = try? WatchReducer.apply(command, timer: &acceptedTimer, preferences: &acceptedPrefs)
        }
        for command in pending where incoming.accepted.contains(command.id) && command.action == .save {
            savedLocally.removeAll { $0.startedAt == command.sessionStart }
        }
        let acknowledgedPrefix = pending.first.map { incoming.accepted.contains($0.id) } ?? false
        pending.removeAll { incoming.accepted.contains($0.id) }
        recovered.removeAll { incoming.recoveredIDs.contains($0.id) }
        if recovered.isEmpty { importingRecovery = false }
        if pending.isEmpty {
            snapshot = incoming; timer = incoming.timer; preferences = incoming.preferences
            watchOwnsAlerts = incoming.alertsOnWatch
            conflict = nil
            return
        }
        if acknowledgedPrefix && incoming.timer.sameSessionState(as: acceptedTimer) && !incoming.conflict {
            snapshot = incoming
            return
        }
        // Context updates can outrun the receipt. Wait for the batch response
        // before treating a different epoch as a conflict.
        if incoming.accepted.isEmpty && !incoming.conflict { return }
        // Unchanged snapshots are harmless while commands wait for delivery.
        guard incoming.revision != snapshot.revision || incoming.conflict else {
            preferences.categories = incoming.preferences.categories
            return
        }
        // Preserve the complete local sitting until the user resolves it.
        conflict = incoming
    }

    /// Explicit resolution never overwrites the phone's active sitting.
    /// Retain finished/offline work locally for export from the Watch UI.
    public mutating func keepPhone(now: Millis) {
        guard let conflict else { return }
        if let draft = timer.reflection { recovered.append(draft) }
        else if timer.kind.isFocus, let draft = timer.draftSession(now: now, manual: true) {
            recovered.append(draft)
        }
        for session in savedLocally where !recovered.contains(where: { $0.id == session.id }) {
            recovered.append(session)
        }
        savedLocally = []
        snapshot = conflict; timer = conflict.timer; preferences = conflict.preferences
        pending = []; self.conflict = nil; watchOwnsAlerts = false
    }
}
