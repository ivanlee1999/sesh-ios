import Foundation
import SeshCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/**
 The session on the Lock Screen.

 Started when a session starts, updated only when something actually changes —
 a pause, a new title — and ended when the session is. The countdown between
 those moments looks after itself, because the widget is told when the session
 ends rather than how much is left.
 */
@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit)
    private var activity: Activity<SeshActivityAttributes>?

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(state: TimerState, accentHex: String, now: Millis) {
        guard isSupported, activity == nil, let end = state.targetDate(now: now) else { return }

        let attributes = SeshActivityAttributes(
            sessionStart: Date(timeIntervalSince1970: Double(state.startedAt ?? now) / 1000)
        )
        let content = SeshActivityAttributes.ContentState(
            endDate: end,
            pausedRemaining: nil,
            title: title(for: state),
            accentHex: accentHex,
            isFocus: state.kind.isFocus
        )

        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: content, staleDate: nil),
            pushType: nil
        )
    }

    func update(state: TimerState, accentHex: String, now: Millis) {
        guard let activity else {
            start(state: state, accentHex: accentHex, now: now)
            return
        }
        guard state.isActive else {
            Task { await end() }
            return
        }

        let remaining = TimeInterval(state.remainingMs(now: now)) / 1000
        let content = SeshActivityAttributes.ContentState(
            // While paused the end date is meaningless, so the widget is handed
            // a static figure to show instead of a countdown that would lie.
            endDate: Date().addingTimeInterval(max(0, remaining)),
            pausedRemaining: state.phase == .paused ? remaining : nil,
            title: title(for: state),
            accentHex: accentHex,
            isFocus: state.kind.isFocus
        )
        Task {
            await activity.update(ActivityContent(state: content, staleDate: nil))
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    private func title(for state: TimerState) -> String {
        if !state.intention.isEmpty { return state.intention }
        return state.kind.isFocus ? "Focus" : "Break"
    }
    #else
    var isSupported: Bool { false }
    func start(state: TimerState, accentHex: String, now: Millis) {}
    func update(state: TimerState, accentHex: String, now: Millis) {}
    func end() async {}
    #endif
}
