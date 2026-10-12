import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/**
 What the Lock Screen and Dynamic Island show while a session runs.

 Shared between the app and the widget extension, so both agree on the shape.

 The important field is `endDate`. SwiftUI can count down to a date without
 anybody updating anything — `Text(timerInterval:)` redraws itself — which
 means a running session costs no background work at all. A Live Activity that
 had to be pushed a new number every second would drain the battery to tell
 someone something their phone already knew.
 */
#if canImport(ActivityKit)
struct SeshActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// When the session reaches its target. Counts on past it, into overtime.
        var endDate: Date
        /// Set only while paused, because a paused timer must not keep counting.
        var pausedRemaining: TimeInterval?
        var title: String
        /// The category's colour, so the island matches the room.
        var accentHex: String
        var isFocus: Bool

        var isPaused: Bool { pausedRemaining != nil }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(abs(seconds)))
        return (seconds < 0 ? "+" : "") + String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Fixed for the life of the session.
    var sessionStart: Date
}
#endif
