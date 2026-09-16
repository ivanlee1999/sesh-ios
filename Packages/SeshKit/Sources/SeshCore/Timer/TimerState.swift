import Foundation

/**
 The running timer, as a value.

 The web app decrements a number once a second and corrects the drift whenever
 it resyncs. That works while a tab is open and is the wrong shape entirely for
 a phone, which is mostly asleep: a timer that only advances when someone is
 looking at it would lose ten minutes the moment the screen locked.

 So nothing counts down here. The state records when the session began and how
 long it has been paused, and the remaining time is *derived* from the clock
 whenever anybody asks. Being asleep, killed, or restored from disk therefore
 costs nothing — the arithmetic is the same either way, which is what makes
 the timer work offline in the first place.
 */
public struct TimerState: Equatable, Sendable, Codable {
    public enum Phase: String, Codable, Sendable {
        case idle
        case running
        case paused
        /// Finished, with the poster up and the rating not yet given.
        case reflect
    }

    public var phase: Phase
    public var kind: SessionKind
    public var intention: String
    public var category: String
    public var targetMs: Int
    public var startedAt: Millis?
    public var pausedAt: Millis?
    /// Time already spent paused, excluding any pause currently open.
    public var pausedTotalMs: Int
    public var taskRefs: String?

    public init(
        phase: Phase = .idle,
        kind: SessionKind = .focus,
        intention: String = "",
        category: String = "",
        targetMs: Int = 0,
        startedAt: Millis? = nil,
        pausedAt: Millis? = nil,
        pausedTotalMs: Int = 0,
        taskRefs: String? = nil
    ) {
        self.phase = phase
        self.kind = kind
        self.intention = intention
        self.category = category
        self.targetMs = targetMs
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.pausedTotalMs = pausedTotalMs
        self.taskRefs = taskRefs
    }

    public static let idle = TimerState()

    // ── Derived time ────────────────────────────────────────────────────

    /// Time the session has actually been running, pauses removed.
    public func elapsedMs(now: Millis) -> Int {
        guard let startedAt else { return 0 }
        let openPause = pausedAt.map { Int(now - $0) } ?? 0
        return max(0, Int(now - startedAt) - pausedTotalMs - openPause)
    }

    /// What the dial reads. Goes negative in overtime, deliberately.
    public func remainingMs(now: Millis) -> Int {
        targetMs - elapsedMs(now: now)
    }

    public func isOvertime(now: Millis) -> Bool {
        phase != .idle && remainingMs(now: now) < 0
    }

    /// When the session will reach its target — what a notification is scheduled for.
    public func targetDate(now: Millis) -> Date? {
        guard phase == .running else { return nil }
        return Date(timeIntervalSince1970: Double(now + Millis(remainingMs(now: now))) / 1000)
    }

    public var isActive: Bool { phase == .running || phase == .paused }

    // ── Transitions ─────────────────────────────────────────────────────

    public mutating func start(
        kind: SessionKind,
        intention: String,
        category: String,
        targetMs: Int,
        taskRefs: String? = nil,
        now: Millis
    ) {
        self = TimerState(
            phase: .running,
            kind: kind,
            intention: intention,
            category: category,
            targetMs: targetMs,
            startedAt: now,
            pausedAt: nil,
            pausedTotalMs: 0,
            taskRefs: taskRefs
        )
    }

    public mutating func pause(now: Millis) {
        guard phase == .running else { return }
        phase = .paused
        pausedAt = now
    }

    public mutating func resume(now: Millis) {
        guard phase == .paused, let pausedAt else { return }
        pausedTotalMs += Int(now - pausedAt)
        self.pausedAt = nil
        phase = .running
    }

    /**
     Changing the topic mid-session drops the linked tasks.

     Deliberate, and carried over from the web app: if you have moved onto
     something else, the minutes should not still be written back to the task
     you started against. Losing the link is the honest outcome.
     */
    public mutating func changeTopic(_ topic: String) {
        intention = topic
        taskRefs = nil
    }

    public mutating func abandon() {
        self = .idle
    }

    // ── Finishing ───────────────────────────────────────────────────────

    /**
     The session this timer just became.

     Two rules, both taken verbatim from the web app so that the same sitting
     recorded on either client produces the same row:

     - finishing naturally credits at least the full target, since the time was
       served even if the app came back a moment late;
     - finishing by hand credits at least a minute, so a mis-tap still reads as
       something rather than as a zero-length session.

     `actualMs` is measured from start to end including any pause, which is what
     the server computes for a session finished in the browser. It is a slightly
     generous definition, and it is the existing one: a phone that measured it
     differently would disagree with the web app about the same hour.
     */
    public func draftSession(now: Millis, manual: Bool) -> Session? {
        guard let startedAt, isActive else { return nil }
        let span = Int(now - startedAt)
        let actualMs = manual ? max(60_000, span) : max(targetMs, span)
        return Session(
            id: Session.id(startedAt: startedAt),
            intention: intention,
            category: category,
            type: kind,
            targetMs: targetMs,
            actualMs: actualMs,
            overflowMs: max(0, actualMs - targetMs),
            startedAt: startedAt,
            endedAt: now,
            notes: "",
            rating: 0,
            todoistTaskId: taskRefs
        )
    }

    // ── Mirroring to the server ─────────────────────────────────────────

    /**
     The shape `PUT /api/timer` and the sync endpoint expect.

     The server stores a remaining figure and the moment it was written, and
     every web client reconstructs the countdown as `remaining - (now - updatedAt)`.
     Converting only at the boundary keeps this app's wall-clock model to itself
     while still showing up correctly on a laptop across the room.
     */
    public func mirrorPayload(now: Millis, deviceId: String) -> [String: Any] {
        [
            "phase": phase == .reflect ? "idle" : phase.rawValue,
            "sessionType": kind.rawValue,
            "intention": intention,
            "category": category,
            "targetMs": targetMs,
            "remainingMs": remainingMs(now: now),
            "overflowMs": max(0, -remainingMs(now: now)),
            "startedAt": startedAt as Any,
            "pausedAt": pausedAt as Any,
            "todoistTaskId": taskRefs as Any,
            "deviceId": deviceId,
        ]
    }
}
