import SwiftUI
import SeshCore

/**
 The sixty-minute clock face.

 A Bauhaus dial rather than a progress bar, and the only circle in the app: sixty
 ticks with the fives picked out, numerals outside the index, a wedge for what
 has elapsed, and two hands. Dragging anywhere on the face sets the length — the
 same `atan2` mapping the web app uses, so a gesture learned on one behaves the
 same on the other.

 Drawn in a `Canvas` because there are roughly a hundred marks on it, and a
 hundred SwiftUI shapes updating every second would cost far more than a single
 immediate-mode redraw.
 */
struct DialView: View {
    let totalMs: Int
    let remainingMs: Int
    let isRunning: Bool
    let isPaused: Bool
    let showSecondHand: Bool
    /// Absent when the dial is not adjustable — a session already under way.
    var onScrub: ((Int) -> Void)?

    @Environment(\.theme) private var theme
    @State private var scrubbing: Int?
    /// Flipped once on appearance to give the overtime badge something to
    /// animate between; a constant opacity has nothing to repeat.
    @State private var pulsing = false

    private var elapsedFraction: Double {
        guard totalMs > 0 else { return 0 }
        let elapsed = Double(totalMs - remainingMs) / Double(totalMs)
        return min(1, max(0, elapsed))
    }

    private var isOvertime: Bool { remainingMs < 0 }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .frame(width: side, height: side)

                readout
                    .frame(width: side * 0.62)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Circle())
            .gesture(scrubGesture(side: side))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // ── The face ────────────────────────────────────────────────────────

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width / 2
        let indexRadius = radius * 0.80
        let ink = theme.palette.text
        let faint = theme.palette.textTertiary

        // The elapsed wedge, drawn first so everything else sits on top.
        if elapsedFraction > 0 {
            var wedge = Path()
            wedge.move(to: centre)
            wedge.addArc(
                center: centre,
                radius: indexRadius,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * elapsedFraction),
                clockwise: false
            )
            wedge.closeSubpath()
            context.fill(wedge, with: .color(theme.accent.opacity(isOvertime ? 0.32 : 0.18)))
        }

        // Sixty ticks; every fifth one longer and darker.
        for minute in 0..<60 {
            let major = minute % 5 == 0
            let angle = Angle.degrees(Double(minute) * 6 - 90)
            let outer = indexRadius
            let inner = indexRadius - (major ? radius * 0.085 : radius * 0.04)
            var tick = Path()
            tick.move(to: point(centre, inner, angle))
            tick.addLine(to: point(centre, outer, angle))
            context.stroke(
                tick,
                with: .color(major ? ink.opacity(0.55) : faint.opacity(0.35)),
                lineWidth: major ? 1.6 : 1
            )
        }

        // Numerals, 5 through 60, outside the index.
        for step in 1...12 {
            let minute = step * 5
            let angle = Angle.degrees(Double(minute) * 6 - 90)
            let position = point(centre, radius * 0.92, angle)
            let text = Text("\(minute)")
                .font(Typeface.font(radius * 0.085, .medium))
                .foregroundStyle(faint)
            context.draw(text, at: position, anchor: .center)
        }

        // The rim arc: a thin line showing the same progress, at full radius.
        if elapsedFraction > 0 {
            var arc = Path()
            arc.addArc(
                center: centre,
                radius: indexRadius,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * elapsedFraction),
                clockwise: false
            )
            context.stroke(arc, with: .color(theme.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }

        // The hands. The minute hand shows where the session is; the second hand
        // sweeps only while it is actually running.
        let plannedMinutes = Double(scrubbing ?? Format.minutes(totalMs))
        let elapsedMinutes = Double(totalMs - remainingMs) / 60_000
        let minuteAngle = Angle.degrees((isRunning || isPaused ? elapsedMinutes : plannedMinutes) * 6 - 90)

        var minuteHand = Path()
        minuteHand.move(to: point(centre, -radius * 0.06, minuteAngle))
        minuteHand.addLine(to: point(centre, indexRadius * 0.92, minuteAngle))
        context.stroke(minuteHand, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

        if showSecondHand && isRunning {
            let seconds = (Double(totalMs - remainingMs) / 1000).truncatingRemainder(dividingBy: 60)
            let secondAngle = Angle.degrees(seconds * 6 - 90)
            var secondHand = Path()
            secondHand.move(to: point(centre, -radius * 0.10, secondAngle))
            secondHand.addLine(to: point(centre, indexRadius * 0.98, secondAngle))
            context.stroke(secondHand, with: .color(theme.accent), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }

        // The hub.
        let hub = radius * 0.035
        context.fill(
            Path(ellipseIn: CGRect(x: centre.x - hub, y: centre.y - hub, width: hub * 2, height: hub * 2)),
            with: .color(ink)
        )
    }

    private func point(_ centre: CGPoint, _ radius: CGFloat, _ angle: Angle) -> CGPoint {
        CGPoint(
            x: centre.x + radius * cos(angle.radians),
            y: centre.y + radius * sin(angle.radians)
        )
    }

    // ── The readout ─────────────────────────────────────────────────────

    private var readout: some View {
        VStack(spacing: 2) {
            Text(Format.clock(max(0, remainingMs)))
                .numeralStyle(44, weight: .semibold)
                .foregroundStyle(theme.palette.text)

            Text(sublabel)
                .metaStyle()
                .foregroundStyle(theme.palette.textTertiary)

            if isOvertime {
                Text(Format.overtime(remainingMs))
                    .numeralStyle(15, weight: .semibold)
                    .foregroundStyle(theme.accent)
                    // Pulses, so overtime reads as something still happening
                    // rather than a number that has stopped.
                    .opacity(pulsing ? 0.45 : 0.95)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var sublabel: String {
        if let scrubbing { return "\(scrubbing) min" }
        if isPaused { return "Paused" }
        if isOvertime { return "Overtime" }
        if isRunning { return "Remaining" }
        return "\(Format.minutes(totalMs)) min planned"
    }

    // ── Dragging to set the length ──────────────────────────────────────

    private func scrubGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard onScrub != nil else { return }
                let minutes = Self.minutes(at: value.location, in: side)
                // One tick per minute crossed, so the dial feels notched.
                if minutes != scrubbing {
                    Haptics.light()
                    scrubbing = minutes
                }
            }
            .onEnded { value in
                guard let onScrub else { return }
                let minutes = Self.minutes(at: value.location, in: side)
                scrubbing = nil
                onScrub(minutes)
            }
    }

    /**
     Where a touch falls on the face, in minutes.

     `atan2(dx, -dy)` puts zero at the top and runs clockwise, which is how a
     clock is read — and is exactly what the web app computes. Clamped to 1…60,
     so a drag through the twelve does not wrap round to nothing.
     */
    static func minutes(at location: CGPoint, in side: CGFloat) -> Int {
        let centre = CGPoint(x: side / 2, y: side / 2)
        let dx = location.x - centre.x
        let dy = location.y - centre.y
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let minutes = Int((degrees / 6).rounded())
        return min(60, max(1, minutes == 0 ? 60 : minutes))
    }
}
