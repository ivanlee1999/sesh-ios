import Foundation
import Observation
import WatchConnectivity
import WidgetKit
import UserNotifications
import WatchKit
import SeshCore

@MainActor @Observable
final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var document = WatchDocument()
    private(set) var reachable = false
    private(set) var error: String?
    private let session = WCSession.default
    private var alertTask: Task<Void, Never>?
    private var lastAlertTimer: TimerState?
    private var lastAlertOwner: Bool?
    private var lastAlertSound: Bool?

    override init() { super.init(); refresh() }
    func activate() {
        refresh()
        #if DEBUG
        NSLog("Sesh WCSession supported: \(WCSession.isSupported())")
        #endif
        guard WCSession.isSupported() else { return }
        session.delegate = self; session.activate()
        Task { await updateAlertAuthorization() }
    }

    func refresh() {
        do {
            let next = try WatchFileStore.read()
            if next != document { WidgetCenter.shared.reloadAllTimelines() }
            document = next; error = nil
        }
        catch { self.error = "Could not open the saved timer. Try reopening Sesh." }
        scheduleAlert()
    }

    func perform(_ action: WatchCommand.Action, minutes: Int = 25, intention: String = "",
                 category: String = "deep", kind: SessionKind = .focus,
                 notes: String = "", rating: Int = 0) {
        do {
            try WatchFileStore.access { document in
                let start = [.save, .editReflection].contains(action)
                    ? document.timer.reflection?.startedAt : document.timer.startedAt
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try document.perform(.init(action: action, at: now, sessionStart: start,
                    kind: kind, minutes: minutes, intention: intention, category: category,
                    notes: notes, rating: rating))
            }
            refresh()
            WKInterfaceDevice.current().play(action == .finish || action == .save ? .success : .click)
            flush()
        } catch { self.error = "That timer changed. Reopen Sesh and try again." }
    }

    func keepPhone() {
        do { try WatchFileStore.access { $0.keepPhone(now: Int64(Date().timeIntervalSince1970 * 1000)) }; refresh(); flush() }
        catch { self.error = "Could not keep the timer on disk. Please try again." }
    }

    /// Recovery remains visible until imported, with no active timer overwritten.
    func importRecovery() {
        do { try WatchFileStore.access { $0.importingRecovery = true }; refresh(); flush() }
        catch { self.error = "Could not start recovery. Your sessions are still here." }
    }

    func flush() {
        guard session.activationState == .activated else { return }
        reachable = session.isReachable
        #if DEBUG
        NSLog("Sesh watch bridge: activation=\(session.activationState.rawValue) phoneInstalled=\(session.isCompanionAppInstalled) reachable=\(session.isReachable) pending=\(document.pending.count)")
        #endif
        var message: [String: Any] = ["request": true]
        if !document.pending.isEmpty || (document.importingRecovery && !document.recovered.isEmpty) || (document.snapshot.alertsOnWatch && !document.alertsAuthorized) {
            var batch = WatchBatch(revision: document.snapshot.revision, commands: document.pending,
                                   recovered: document.importingRecovery ? document.recovered : [], watchCanAlert: document.alertsAuthorized)
            // WCSession messages have a bounded payload. Deliver a causal prefix
            // rather than dropping queued notes when offline work accumulates.
            while (try? JSONEncoder().encode(batch).count) ?? Int.max > 50_000 {
                if batch.recovered.count > 0 { batch.recovered.removeLast() }
                else if batch.commands.count > 1 { batch.commands.removeLast() }
                else { error = "This session is too large to sync. Keep it on Watch and shorten the reflection."; return }
            }
            guard let data = try? JSONEncoder().encode(batch) else { return }
            let key = "\(batch.watchCanAlert):\(batch.revision):\(batch.commands.map(\.id).joined(separator: ",")):\(batch.recovered.map(\.id).joined(separator: ","))"
            message = ["batch": data, "batchKey": key]
            if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["batchKey"] as? String == key }) {
                session.transferUserInfo(message)
            }
        }
        if session.isReachable {
            session.sendMessage(message, replyHandler: { reply in
                Task { @MainActor in self.receive(reply) }
            }, errorHandler: { _ in /* The durable queue will retry. */ })
        }
    }

    private func receive(_ message: [String: Any]) {
        guard let data = message["snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        do {
            try WatchFileStore.access { $0.receive(snapshot) }
            refresh()
            // A command made while an earlier batch was in flight is sent next.
            if document.conflict == nil && (!document.pending.isEmpty || document.importingRecovery || (document.snapshot.alertsOnWatch && !document.alertsAuthorized)) { flush() }
        } catch { self.error = "Could not save the iPhone update. Your Watch timer is still here." }
    }

    func requestAlerts() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await updateAlertAuthorization()
    }

    private func updateAlertAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let granted = status == .authorized || status == .provisional
        do {
            try WatchFileStore.access { document in
                document.alertsAuthorized = granted
                // Accepted timers keep the negotiated owner. Pending actions
                // advertise ability before the phone withdraws its alarm.
                document.watchOwnsAlerts = granted && (document.snapshot.alertsOnWatch || !document.pending.isEmpty)
            }
            lastAlertTimer = nil
            refresh()
            flush()
        } catch { self.error = "Could not save notification settings." }
    }

    private func scheduleAlert() {
        let timer = document.timer
        let owner = document.watchOwnsAlerts && document.alertsAuthorized
        guard timer != lastAlertTimer || owner != lastAlertOwner || document.preferences.soundEnabled != lastAlertSound else { return }
        lastAlertTimer = timer; lastAlertOwner = owner; lastAlertSound = document.preferences.soundEnabled
        alertTask?.cancel()
        let sound = document.preferences.soundEnabled
        alertTask = Task {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["sesh.watch.target"])
            guard owner, timer.phase == .running,
                  let target = timer.targetDate(now: Int64(Date().timeIntervalSince1970 * 1000)),
                  target.timeIntervalSinceNow > 0 else { return }
            let content = UNMutableNotificationContent()
            content.title = timer.kind.isFocus ? "Time to reflect" : "Break over"
            content.body = timer.intention.isEmpty ? "Open Sesh to finish your session." : timer.intention
            content.sound = sound ? .default : nil
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, target.timeIntervalSinceNow), repeats: false)
            guard !Task.isCancelled else { return }
            try? await center.add(UNNotificationRequest(identifier: "sesh.watch.target", content: content, trigger: trigger))
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.flush() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.flush() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receive(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.receive(userInfo) }
    }
}
