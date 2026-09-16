import SwiftUI
import SeshCore

/**
 The week, counted.

 Every figure here is worked out on the phone from sessions it already has —
 which means it is right offline, and right in whatever timezone you are
 actually standing in. The web app asks its server, and its server answers in
 Pacific time whoever is asking; a streak that resets at the wrong midnight is
 worse than no streak at all.
 */
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var insights: Insights { model.insights }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Insights").titleStyle()

                statGrid
                weekChart
                categoryBreakdown
                hourStrip
            }
            .padding(20)
        }
        .background(theme.palette.background)
    }

    // ── The four cells ──────────────────────────────────────────────────

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatCell(label: "Focused today", value: Format.duration(insights.todayMs))
            StatCell(label: "Sessions today", value: "\(insights.todayCount)")
            StatCell(label: "Day streak", value: "\(insights.streak)")
            StatCell(
                label: "Planned vs actual",
                value: insights.planAccuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            )
        }
    }

    // ── Seven days ──────────────────────────────────────────────────────

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Last seven days")

            let peak = max(1, insights.days.map(\.ms).max() ?? 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(insights.days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(index == insights.days.count - 1 ? theme.accent : theme.palette.fill3)
                            .frame(height: max(3, 110 * CGFloat(day.ms) / CGFloat(peak)))
                        Text(day.label)
                            .font(Typeface.font(10.5, .medium))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140, alignment: .bottom)
        }
    }

    // ── Where it went ───────────────────────────────────────────────────

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Where it went")

            if insights.categories.isEmpty {
                Text("Nothing logged yet.").metaStyle().foregroundStyle(theme.palette.textTertiary)
            } else {
                ForEach(insights.categories, id: \.category) { total in
                    let record = model.category(named: total.category)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(record?.label ?? total.category).metaStyle().foregroundStyle(theme.palette.text)
                            Spacer()
                            Text("\(Int((total.share * 100).rounded()))% · \(Format.duration(total.ms))")
                                .metaStyle()
                                .foregroundStyle(theme.palette.textTertiary)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.palette.fill1)
                                Capsule()
                                    .fill(Color(hex: record?.color ?? Accent.defaultAccent))
                                    .frame(width: geometry.size.width * CGFloat(total.share))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    // ── Today, hour by hour ─────────────────────────────────────────────

    private var hourStrip: some View {
        let todayKey = DayKey.key(for: Date())
        let dayStart = DayKey.startOfDayMillis(todayKey)
        let today = model.sessions.filter {
            $0.type.isFocus && DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == todayKey
        }

        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Today, hour by hour")
            HStack(spacing: 3) {
                ForEach(8..<21, id: \.self) { hour in
                    let ms = today
                        .filter { Int(Double($0.startedAt - dayStart) / 3_600_000) == hour }
                        .reduce(0) { $0 + $1.actualMs }
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ms > 0 ? theme.accent.opacity(min(1, 0.35 + Double(ms) / 3_600_000)) : theme.palette.fill1)
                            .frame(height: 26)
                        if hour % 3 == 0 {
                            Text("\(hour)").font(Typeface.font(9)).foregroundStyle(theme.palette.textTertiary)
                        } else {
                            Color.clear.frame(height: 11)
                        }
                    }
                }
            }
        }
    }
}

private struct StatCell: View {
    let label: String
    let value: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).eyebrowStyle().foregroundStyle(theme.palette.textTertiary)
            Text(value).numeralStyle(26, weight: .bold).foregroundStyle(theme.palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }
}
