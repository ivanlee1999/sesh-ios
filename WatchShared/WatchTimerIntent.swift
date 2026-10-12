import AppIntents
import WidgetKit
import SeshCore
import Foundation

/// Explicit desired phase and sitting ID make a stale widget tap harmless.
struct WatchTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Control Sesh timer"
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Session start") var sessionStart: Int
    @Parameter(title: "Resume") var resume: Bool
    init() { sessionStart = 0; resume = false }
    init(start: Millis?, resume: Bool) { sessionStart = Int(start ?? 0); self.resume = resume }

    func perform() async throws -> some IntentResult {
        try WatchFileStore.access { document in
            let phase: TimerState.Phase = resume ? .paused : .running
            guard document.conflict == nil, document.timer.startedAt == Int64(sessionStart),
                  document.timer.phase == phase else { return }
            try document.perform(WatchCommand(action: resume ? .resume : .pause,
                at: Int64(Date().timeIntervalSince1970 * 1000), sessionStart: Int64(sessionStart)))
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
