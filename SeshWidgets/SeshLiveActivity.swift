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
    var body: some Widget {
        SeshLiveActivity()
    }
}

struct SeshLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SeshActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(hex: context.state.accentHex).opacity(0.18))
                .activitySystemActionForegroundColor(Color(hex: context.state.accentHex))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.isFocus ? "Focus" : "Break", systemImage: "timer")
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
                Image(systemName: context.state.isPaused ? "pause.fill" : "timer")
                    .foregroundStyle(Color(hex: context.state.accentHex))
            } compactTrailing: {
                countdown(context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 52)
                    .foregroundStyle(Color(hex: context.state.accentHex))
            } minimal: {
                Image(systemName: "timer").foregroundStyle(Color(hex: context.state.accentHex))
            }
        }
    }

    /// Paused shows a fixed figure; running counts itself down.
    @ViewBuilder
    private func countdown(_ state: SeshActivityAttributes.ContentState) -> some View {
        if let paused = state.pausedRemaining {
            Text(Self.clock(paused))
        } else {
            Text(timerInterval: Date()...state.endDate, countsDown: true)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LockScreenView: View {
    let state: SeshActivityAttributes.ContentState

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
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Group {
                if let paused = state.pausedRemaining {
                    Text(SeshLiveActivity.clock(paused))
                } else {
                    Text(timerInterval: Date()...state.endDate, countsDown: true)
                }
            }
            .font(.system(.title, design: .rounded).monospacedDigit())
            .foregroundStyle(Color(hex: state.accentHex))
        }
        .padding(16)
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
