import AppIntents
import WidgetKit
import SeshCore
import Foundation

/// Explicit desired phase and sitting ID make a stale widget tap harmless.
struct WatchTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Control Sesh timer"
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Session start") var sessionStart: String
    @Parameter(title: "Resume") var resume: Bool
    init() { sessionStart = "0"; resume = false }
    init(start: Millis?, resume: Bool) { sessionStart = String(start ?? 0); self.resume = resume }

    func perform() async throws -> some IntentResult {
        guard let start = Int64(sessionStart) else { return .result() }
        try WatchFileStore.access { document in
            let phase: TimerState.Phase = resume ? .paused : .running
            guard document.conflict == nil, document.timer.startedAt == start,
                  document.timer.phase == phase else { return }
            try document.perform(WatchCommand(action: resume ? .resume : .pause,
                at: Int64(Date().timeIntervalSince1970 * 1000), sessionStart: start))
        }
        // If the intent executes after the app is already foreground, update its
        // observable model too; the foreground hook covers other-process execution.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .seshWatchTimerChanged, object: nil)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

enum WatchClock {
    static func string(_ milliseconds: Int) -> String {
        let total = Int(ceil(Double(abs(milliseconds)) / 1000))
        return String(format: "%@%d:%02d", milliseconds < 0 ? "+" : "", total / 60, total % 60)
    }
}

extension Notification.Name {
    static let seshWatchTimerChanged = Notification.Name("us.liyifan.sesh.watch.timerChanged")
}
