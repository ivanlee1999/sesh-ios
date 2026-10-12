import Foundation
import WatchConnectivity
import SeshCore

@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    weak var model: AppModel?
    private let session = WCSession.default
    private var lastPublished: WatchSnapshot?

    func activate(model: AppModel) {
        #if DEBUG
        NSLog("Sesh WCSession supported: \(WCSession.isSupported())")
        #endif
        guard WCSession.isSupported() else { return }
        self.model = model
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func publish() -> WatchSnapshot? {
        guard let model, let snapshot = try? model.repository.watchSnapshot() else { return nil }
        #if DEBUG
        NSLog("Sesh phone bridge: activation=\(session.activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable)")
        #endif
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return snapshot }
        if snapshot != lastPublished, let data = try? JSONEncoder().encode(snapshot) {
            do {
                try session.updateApplicationContext(["snapshot": data])
                lastPublished = snapshot
            } catch { /* Retried on activation/reachability/foreground. */ }
        }
        return snapshot
    }

    private func receive(_ message: [String: Any], reply: (([String: Any]) -> Void)? = nil) {
        guard let model else { reply?(["retry": true]); return }
        do {
            let snapshot: WatchSnapshot
            if let data = message["batch"] as? Data {
                let batch = try JSONDecoder().decode(WatchBatch.self, from: data)
                snapshot = try model.repository.receiveWatch(batch, deviceId: model.deviceIdentity)
                model.watchStateDidChange(snapshot)
            } else { snapshot = try model.repository.watchSnapshot() }
            let data = try JSONEncoder().encode(snapshot)
            reply?(["snapshot": data])
            // Receipts must be queued, unlike applicationContext which can be replaced.
            if message["batch"] != nil { session.transferUserInfo(["snapshot": data]) }
            publish()
        } catch { reply?(["retry": true]) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.receive(message, reply: replyHandler) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.receive(userInfo) }
    }
}
