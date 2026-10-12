import SwiftUI
import WidgetKit
import ActivityKit

/**
 The session on the Lock Screen and in the Dynamic Island.

 Every countdown here is `Text(timerInterval:)`, which redraws itself from a
 date the widget already has. Nothing is pushed, nothing wakes up once a second,
 and the numbers stay right even with the phone face-down and offline — which is
 the same reason the app's own timer stores an instant rather than a tally.
 */
@main
struct SeshWidgetBundle: WidgetBundle {
    var body: some Widget { configuredActivity() }

    // WidgetBundleBuilder has no buildEither. Its public availability wrapper
    // gives both OS branches the same result type, registering exactly one
    // ActivityConfiguration while retaining the iOS 17 presentation.
    private func configuredActivity() -> some Widget {
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(SeshWatchLiveActivity()))
        } else {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(SeshLiveActivity()))
        }
    }
}

struct SeshLiveActivity: Widget {
    var body: some WidgetConfiguration { configuration }

    fileprivate var configuration: some WidgetConfiguration {
        ActivityConfiguration(for: SeshActivityAttributes.self) { context in
            Group {
                if #available(iOS 18.0, *) {
                    AdaptiveActivityView(state: context.state, isStale: context.isStale)
                } else {
                    LockScreenView(state: context.state, isStale: context.isStale)
                }
            }
                .activityBackgroundTint(Color(hex: context.state.accentHex).opacity(0.18))
                .activitySystemActionForegroundColor(Color(hex: context.state.accentHex))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(Self.isOvertime(context.state, stale: context.isStale) ? "Overtime" : (context.state.isFocus ? "Focus" : "Break"), systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(Color(hex: context.state.accentHex))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context.state)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color(hex: context.state.accentHex))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.title)
                        .font(.footnote)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : (Self.isOvertime(context.state, stale: context.isStale) ? "plus" : "timer"))
                    .foregroundStyle(Color(hex: context.state.accentHex))
            } compactTrailing: {
                countdown(context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 52)
                    .foregroundStyle(Color(hex: context.state.accentHex))
            } minimal: {
                Image(systemName: Self.isOvertime(context.state, stale: context.isStale) ? "plus" : "timer").foregroundStyle(Color(hex: context.state.accentHex))
            }
        }
    }

    static func isOvertime(_ state: SeshActivityAttributes.ContentState, stale: Bool) -> Bool {
        if let paused = state.pausedRemaining { return paused < 0 }
        return stale && state.endDate <= Date()
    }

    /// The system date formatter crosses the target and counts overtime without
    /// an app wakeup. Paused overtime remains a signed, fixed value.
    private func countdown(_ state: SeshActivityAttributes.ContentState) -> some View {
        ActivityTimerView(state: state)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        SeshActivityAttributes.clock(seconds)
    }

}

@available(iOS 18.0, *)
private struct SeshWatchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        SeshLiveActivity().configuration.supplementalActivityFamilies([.small])
    }
}

private struct LockScreenView: View {
    let state: SeshActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.isFocus ? "FOCUS" : "BREAK")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color(hex: state.accentHex))

                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)

                if state.isPaused {
                    Text(SeshLiveActivity.isOvertime(state, stale: isStale) ? "Paused · overtime" : "Paused").font(.caption).foregroundStyle(.secondary)
                } else if SeshLiveActivity.isOvertime(state, stale: isStale) {
                    Text("Overtime").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            ActivityTimerView(state: state)
            .font(.system(.title, design: .rounded).monospacedDigit())
            .foregroundStyle(Color(hex: state.accentHex))
        }
        .padding(16)
    }
}

private struct ActivityTimerView: View {
    let state: SeshActivityAttributes.ContentState
    var body: some View {
        if let paused = state.pausedRemaining {
            Text(SeshLiveActivity.clock(paused))
        } else {
            Text(state.endDate, style: .timer)
        }
    }
}

@available(iOS 18.0, *)
private struct AdaptiveActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: SeshActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        if family == .small {
            WatchActivityView(state: state, isStale: isStale)
        } else {
            LockScreenView(state: state, isStale: isStale)
        }
    }
}

@available(iOS 18.0, *)
private struct WatchActivityView: View {
    @Environment(\.isLuminanceReduced) private var dimmed
    let state: SeshActivityAttributes.ContentState
    let isStale: Bool
    private var status: String {
        if state.isPaused { return (state.pausedRemaining ?? 0) < 0 ? "Paused · overtime" : "Paused" }
        return isStale && state.endDate <= Date() ? "Overtime" : (state.isFocus ? "Focus timer" : "Break timer")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: state.isPaused ? "pause.fill" : "timer")
                Text(status).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(dimmed ? Color.secondary : Color(hex: state.accentHex))
            ActivityTimerView(state: state)
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(state.title).font(.caption2).lineLimit(1).privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .accessibilityElement(children: .combine)
    }
}

/// The widget target cannot see the app's own helper, so it keeps its own.
private extension Color {
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
