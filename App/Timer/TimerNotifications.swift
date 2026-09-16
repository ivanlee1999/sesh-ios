import Foundation
import UserNotifications
import SeshCore

/**
 The alarm that fires whether or not the app is running.

 This is the part that makes an offline timer real. The web app depends on the
 server noticing the session has run over and sending a push — which needs a
 network, a live service worker, and a server that has been told the timer
 exists. A locked phone in a tunnel has none of those.

 So the notifications are scheduled locally, up front, the moment the session
 starts: one at the target, then reminders every five minutes into overtime.
 They are already sitting in iOS's queue, and nothing — no signal, no server,
 the app killed outright — stops them arriving.
 */
enum TimerNotifications {
    private static let prefix = "sesh.timer."
    /// Five-minute reminders for an hour. iOS keeps at most 64 pending
    /// notifications per app, and an hour of overtime is already well past the
    /// point where the reminder is the problem.
    private static let overtimeReminders = 12
    private static let reminderInterval: TimeInterval = 5 * 60

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /**
     Replace the pending alarms with the ones this timer implies.

     Called on every transition rather than only on start: pausing has to
     withdraw them, and resuming has to lay them down again from the new finish
     time. Anything else and a paused session would still announce itself.
     */
    static func reschedule(for state: TimerState, settings: AppSettings, now: Millis) async {
        let center = UNUserNotificationCenter.current()
        await cancelAll()

        guard state.phase == .running, let target = state.targetDate(now: now) else { return }

        let isFocus = state.kind.isFocus
        let label = state.intention.isEmpty
            ? (isFocus ? "Focus session" : "Break")
            : state.intention

        // The target itself.
        let remaining = target.timeIntervalSinceNow
        if remaining > 0 {
            let content = UNMutableNotificationContent()
            content.title = isFocus ? "Session complete" : "Break over"
            content.body = "\(label) · \(Format.minutes(state.targetMs)) min"
            content.sound = settings.soundEnabled ? .default : nil
            content.interruptionLevel = .timeSensitive
            await add(center, id: "\(prefix)target", content: content, after: remaining)
        }

        // Then the reminders, because the timer runs on rather than stopping.
        for index in 1...overtimeReminders {
            let delay = remaining + Double(index) * reminderInterval
            guard delay > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Still going"
            content.body = "\(label) · +\(index * 5) min over"
            content.sound = nil
            content.interruptionLevel = .passive
            await add(center, id: "\(prefix)over\(index)", content: content, after: delay)
        }
    }

    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    private static func add(
        _ center: UNUserNotificationCenter,
        id: String,
        content: UNMutableNotificationContent,
        after seconds: TimeInterval
    ) async {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
