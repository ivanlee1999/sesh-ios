import SwiftUI
import WidgetKit
import SeshCore

struct SeshWatchEntry: TimelineEntry {
    var date: Date
    var document: WatchDocument
}

struct SeshWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> SeshWatchEntry { .init(date: .now, document: WatchDocument()) }
    func getSnapshot(in context: Context, completion: @escaping (SeshWatchEntry) -> Void) {
        completion(entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SeshWatchEntry>) -> Void) {
        let current = entry()
        var entries = [current]
        if current.document.timer.phase == .running {
            // Future entries animate the gauge without spending a refresh per minute.
            for minute in 1...180 {
                entries.append(.init(date: current.date.addingTimeInterval(Double(minute * 60)), document: current.document))
            }
        }
        // Explicit post-target entry labels overtime; no upward-counting countdown.
        if let target = current.document.timer.targetDate(now: Int64(current.date.timeIntervalSince1970 * 1000)), target > .now {
            entries.append(.init(date: target, document: current.document))
        }
        completion(Timeline(entries: entries.sorted { $0.date < $1.date }, policy: .after(Date().addingTimeInterval(15 * 60))))
    }
    private func entry() -> SeshWatchEntry {
        .init(date: .now, document: (try? WatchFileStore.read()) ?? WatchDocument())
    }
}

@main
struct SeshWatchWidgets: Widget {
    let kind = "SeshWatchTimer"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SeshWatchProvider()) { entry in
            SeshWatchWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sesh timer")
        .description("Your focus session, at a glance. Open Sesh to start, pause or finish.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

private struct SeshWatchWidgetView: View {
    let entry: SeshWatchEntry
    @Environment(\.widgetFamily) private var family
    private var timer: TimerState { entry.document.timer }
    private var remaining: Int { timer.remainingMs(now: Int64(entry.date.timeIntervalSince1970 * 1000)) }
    private var label: String {
        if entry.document.conflict != nil { return "Review timers" }
        if timer.reflection != nil { return "Save session" }
        return timer.isActive ? (timer.kind.isFocus ? "Focus" : "Break") : "Start focus"
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label).font(.headline).lineLimit(1)
                        if timer.isActive { countdown.font(.title3.monospacedDigit()) }
                        else { Text("\(entry.document.lastMinutes) min").font(.caption) }
                        if timer.phase == .paused { Text("Paused").font(.caption2) }
                    }
                    Spacer(minLength: 0)
                    if timer.isActive && timer.reflection == nil && entry.document.conflict == nil {
                        Button(intent: WatchTimerIntent(start: timer.startedAt, resume: timer.phase == .paused)) {
                            Image(systemName: timer.phase == .paused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(timer.phase == .paused ? "Resume session" : "Pause session")
                        .accessibilityHint("Opens Sesh on Apple Watch")
                    } else { Image(systemName: timer.reflection != nil ? "checkmark.circle" : "timer") }
                }
            case .accessoryInline:
                HStack { Image(systemName: "timer"); Text(label); if timer.isActive { countdown } }
            case .accessoryCorner:
                Image(systemName: "timer").font(.title3)
                    .widgetLabel { if timer.isActive { countdown } else { Text("Sesh") } }
            default:
                Gauge(value: timer.isActive ? max(0, min(1, Double(remaining) / Double(max(1, timer.targetMs)))) : 0) {
                    Image(systemName: "timer")
                } currentValueLabel: {
                    if timer.isActive { countdown.font(.caption2.monospacedDigit()).minimumScaleFactor(0.6) }
                    else { Image(systemName: timer.reflection == nil ? "play.fill" : "checkmark") }
                }.gaugeStyle(.accessoryCircular)
            }
        }
        .widgetURL(URL(string: "sesh-watch://timer"))
        .privacySensitive(timer.isActive)
        .accessibilityLabel("Sesh, \(label)\(timer.phase == .paused ? ", paused" : "")")
    }
    @ViewBuilder private var countdown: some View {
        if timer.phase == .running, remaining > 0, let end = timer.targetDate(now: Int64(entry.date.timeIntervalSince1970 * 1000)) {
            Text(timerInterval: entry.date...end, countsDown: true, showsHours: false)
        } else if remaining <= 0 { Text("Overtime") }
        else { Text(WatchClock.string(remaining)) }
    }
}
