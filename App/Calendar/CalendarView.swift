import SwiftUI
import SeshCore

/**
 Where the hours actually went.

 Month, week and day, all drawn from the sessions already on the phone — so it
 works on a plane, and so paging back through a year costs nothing. Breaks are
 drawn as outlines and focus as fills, which is the whole legend: the filled
 area is the work.
 */
struct CalendarSceneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var span: Span = .month
    @State private var anchor = Date()
    @State private var selectedDay = DayKey.key(for: Date())

    enum Span: String, Hashable, CaseIterable {
        case month, week, day
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $anchor) {
                ForEach(pages, id: \.self) { page in
                    pageBody(for: page)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: span == .month ? 320 : 300)

            Hairline()
            dayLog
        }
        .background(theme.palette.background)
        .onAppear { span = Span(rawValue: DeviceDefaults.calendarView) ?? .month }
        .onChange(of: span) { _, value in DeviceDefaults.calendarView = value.rawValue }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(periodTitle).titleStyle()
                Spacer()
                HStack(spacing: 4) {
                    arrow("chevron.left", by: -1)
                    arrow("chevron.right", by: 1)
                }
            }
            SeshSegmented(
                options: Span.allCases.map { ($0, $0.label, nil) },
                selection: $span
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func arrow(_ symbol: String, by delta: Int) -> some View {
        Button {
            Haptics.light()
            withAnimation(Motion.standard) { anchor = shift(anchor, by: delta) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.palette.textSecondary)
    }

    /// Three pages either side, so a swipe always has somewhere to go.
    private var pages: [Date] {
        (-2...2).map { shift(anchor, by: $0) }
    }

    private func shift(_ date: Date, by delta: Int) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2   // Monday, as in the web app
        let component: Calendar.Component = span == .month ? .month : (span == .week ? .weekOfYear : .day)
        return calendar.date(byAdding: component, value: delta, to: date) ?? date
    }

    @ViewBuilder
    private func pageBody(for page: Date) -> some View {
        switch span {
        case .month: MonthGrid(anchor: page, selected: $selectedDay, sessions: model.sessions)
        case .week: WeekGrid(anchor: page, sessions: model.sessions, selected: $selectedDay)
        case .day: DayStrip(dayKey: DayKey.key(for: page), sessions: model.sessions)
        }
    }

    private var periodTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = span == .day ? "EEEE d MMMM" : (span == .week ? "'Week of' d MMM" : "MMMM yyyy")
        return formatter.string(from: anchor)
    }

    // ── The day log ─────────────────────────────────────────────────────

    private var dayLog: some View {
        let rows = model.sessions
            .filter { DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == selectedDay }
            .sorted { $0.startedAt < $1.startedAt }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(DayKey.label(selectedDay)).eyebrowStyle().foregroundStyle(theme.palette.textSecondary)
                    Spacer()
                    Text(Format.duration(rows.filter { $0.type.isFocus }.reduce(0) { $0 + $1.actualMs }))
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                if rows.isEmpty {
                    Text("Nothing logged.")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                } else {
                    ForEach(rows) { session in
                        DayLogRow(session: session, color: color(for: session))
                        Hairline(inset: 20)
                    }
                }
            }
        }
    }

    private func color(for session: Session) -> String {
        model.category(named: session.category)?.color ?? Accent.defaultAccent
    }
}

private struct DayLogRow: View {
    let session: Session
    let color: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text(Format.timeOfDay(Date(timeIntervalSince1970: Double(session.startedAt) / 1000)))
                .numeralStyle(12)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 44, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: color))
                .frame(width: 3, height: 26)
                .opacity(session.type.isFocus ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.intention.isEmpty ? (session.type.isFocus ? "Focus" : "Break") : session.intention)
                    .rowTitleStyle()
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1)
                Text(session.category).metaStyle().foregroundStyle(theme.palette.textTertiary)
            }

            Spacer(minLength: 6)
            Text(Format.duration(session.actualMs))
                .numeralStyle(12.5)
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// ── Month ───────────────────────────────────────────────────────────────

private struct MonthGrid: View {
    let anchor: Date
    @Binding var selected: String
    let sessions: [Session]
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        let days = monthDays()
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { label in
                    Text(label)
                        .eyebrowStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(days, id: \.self) { day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func dayCell(_ key: String) -> some View {
        let bars = sessions
            .filter { DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == key && $0.type.isFocus }
            .sorted { $0.actualMs < $1.actualMs }
            .prefix(4)
        let isToday = key == DayKey.key(for: Date())

        return Button {
            Haptics.light()
            selected = key
        } label: {
            VStack(spacing: 3) {
                Text(String(key.suffix(2)))
                    .numeralStyle(13)
                    .foregroundStyle(selected == key ? theme.accentInk : (isToday ? theme.accent : theme.palette.text))
                    .frame(width: 24, height: 20)
                    .background(selected == key ? theme.accent : .clear, in: Capsule())

                VStack(spacing: 2) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, session in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(hex: model.category(named: session.category)?.color ?? Accent.defaultAccent))
                            .frame(height: 2.5)
                    }
                }
                .frame(height: 14, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Leading blanks so the first of the month lands under the right weekday.
    private func monthDays() -> [String?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchor) else { return [] }
        let first = interval.start
        let count = calendar.range(of: .day, in: .month, for: anchor)?.count ?? 30
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var cells: [String?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            if let date = calendar.date(byAdding: .day, value: offset, to: first) {
                cells.append(DayKey.key(for: date))
            }
        }
        return cells
    }
}

// ── Week ────────────────────────────────────────────────────────────────

private struct WeekGrid: View {
    let anchor: Date
    let sessions: [Session]
    @Binding var selected: String
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        let days = weekDays()
        let weekSessions = sessions.filter { days.contains(DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000))) }
        let bounds = hourBounds(for: weekSessions)

        GeometryReader { geometry in
            let hourHeight = geometry.size.height / CGFloat(max(1, bounds.upperBound - bounds.lowerBound))
            HStack(alignment: .top, spacing: 2) {
                // The hour gutter.
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(stride(from: bounds.lowerBound, to: bounds.upperBound, by: 2)), id: \.self) { hour in
                        Text("\(hour)")
                            .numeralStyle(10)
                            .foregroundStyle(theme.palette.textTertiary)
                            .frame(height: hourHeight * 2, alignment: .top)
                    }
                }
                .frame(width: 20)

                ForEach(days, id: \.self) { day in
                    dayColumn(day, bounds: bounds, hourHeight: hourHeight)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func dayColumn(_ key: String, bounds: Range<Int>, hourHeight: CGFloat) -> some View {
        let dayStart = DayKey.startOfDayMillis(key)
        let blocks = sessions.filter {
            DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == key
        }

        return VStack(spacing: 3) {
            Text(String(key.suffix(2)))
                .numeralStyle(11)
                .foregroundStyle(key == selected ? theme.accent : theme.palette.textTertiary)

            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 3).fill(theme.palette.fill1)

                    ForEach(blocks) { session in
                        let startHour = Double(session.startedAt - dayStart) / 3_600_000
                        let offset = (startHour - Double(bounds.lowerBound)) * hourHeight
                        let height = max(3, CGFloat(Double(session.actualMs) / 3_600_000 * Double(hourHeight)))
                        let color = Color(hex: model.category(named: session.category)?.color ?? Accent.defaultAccent)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(session.type.isFocus ? color : .clear)
                            .overlay {
                                if !session.type.isFocus {
                                    RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.6), lineWidth: 1)
                                }
                            }
                            .frame(height: height)
                            .offset(y: max(0, offset))
                    }
                }
                .frame(width: geometry.size.width)
            }
        }
        .onTapGesture { selected = key }
    }

    private func weekDays() -> [String] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return [] }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: interval.start).map { DayKey.key(for: $0) }
        }
    }

    /// The hours this week actually used, padded — not a fixed 00–24 that would
    /// spend most of its height on an empty night.
    private func hourBounds(for sessions: [Session]) -> Range<Int> {
        guard !sessions.isEmpty else { return 8..<18 }
        let hours = sessions.map { session -> Int in
            let dayStart = DayKey.startOfDayMillis(DayKey.key(for: Date(timeIntervalSince1970: Double(session.startedAt) / 1000)))
            return Int(Double(session.startedAt - dayStart) / 3_600_000)
        }
        let lower = max(0, (hours.min() ?? 8) - 1)
        let upper = min(24, (hours.max() ?? 18) + 2)
        return lower..<max(lower + 6, upper)
    }
}

// ── Day ─────────────────────────────────────────────────────────────────

private struct DayStrip: View {
    let dayKey: String
    let sessions: [Session]
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let dayStart = DayKey.startOfDayMillis(dayKey)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(6..<22, id: \.self) { hour in
                let inHour = sessions.filter { session in
                    let offset = Int(Double(session.startedAt - dayStart) / 3_600_000)
                    return offset == hour
                }
                HStack(spacing: 10) {
                    Text("\(hour)")
                        .numeralStyle(11)
                        .foregroundStyle(theme.palette.textTertiary)
                        .frame(width: 20, alignment: .trailing)

                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(inHour) { session in
                                let share = min(1, Double(session.actualMs) / 3_600_000)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: model.category(named: session.category)?.color ?? Accent.defaultAccent))
                                    .opacity(session.type.isFocus ? 1 : 0.35)
                                    .frame(width: max(4, geometry.size.width * share))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 8)
                    .background(theme.palette.fill1, in: RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .padding(.horizontal, 20)
    }
}
