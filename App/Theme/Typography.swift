import SwiftUI

/**
 Archivo, in the handful of roles the interface actually uses.

 The web app gives every size a name and a job; the same names are kept here so
 a change made in one place can be found in the other. Numbers are always
 tabular and slightly tightened — a countdown whose digits change width jitters
 once a second, which is the last thing a focus timer should do.
 */
enum Typeface {
    static let family = "Archivo"

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: size).weight(weight)
    }
}

extension View {
    /// 11px, uppercase, wide-tracked — the only place capitals survive.
    func eyebrowStyle() -> some View {
        self.font(Typeface.font(11, .semibold))
            .tracking(0.9)
            .textCase(.uppercase)
    }

    func titleStyle(_ size: CGFloat = 24) -> some View {
        self.font(Typeface.font(size, .bold)).tracking(-0.5)
    }

    func metaStyle() -> some View {
        self.font(Typeface.font(12.5, .medium))
    }

    func bodyStyle() -> some View {
        self.font(Typeface.font(14))
    }

    func rowTitleStyle() -> some View {
        self.font(Typeface.font(15, .medium))
    }

    /// For anything counting: the dial, the stat cells, a duration.
    func numeralStyle(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        self.font(Typeface.font(size, weight))
            .monospacedDigit()
            .tracking(-0.03 * size)
    }
}

enum Format {
    /// `MM:SS`, and `-MM:SS` once a session is into overtime.
    static func clock(_ milliseconds: Int) -> String {
        let negative = milliseconds < 0
        let total = abs(milliseconds) / 1000
        return String(format: "%@%d:%02d", negative ? "-" : "", total / 60, total % 60)
    }

    /// The overtime badge, which reads as time gained rather than time lost.
    static func overtime(_ milliseconds: Int) -> String {
        let total = Int(ceil(Double(abs(milliseconds)) / 1000))
        return String(format: "+%d:%02d", total / 60, total % 60)
    }

    /// "1h 25m", "25m" — durations as someone would say them.
    static func duration(_ milliseconds: Int) -> String {
        let minutes = Int((Double(milliseconds) / 60_000).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func minutes(_ milliseconds: Int) -> Int {
        Int((Double(milliseconds) / 60_000).rounded())
    }

    static func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func weekdayAndDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter.string(from: date)
    }

    /// "Session 03" — padded, so the eyebrow does not change width mid-morning.
    static func ordinal(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}
