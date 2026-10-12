import SwiftUI
import SeshCore

/**
 The screen the app is for.

 Three states in one place, because they are one thing at different moments:
 the dial you set, the session you are in, and the poster that tells you what
 just happened. Running inverts the whole screen into the category's own room —
 the tab bar goes, the chrome goes, and what is left is a clock.
 */
struct FocusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var actionHeight: CGFloat = 48

    @State private var intention: String = ""
    @State private var showingTaskPicker = false
    @State private var showingAbandonConfirm = false
    // Focus, like the server's `timer_state.session_type` — opening a focus
    // timer on a five-minute break offers the wrong thing first.
    @State private var breakKind: BreakKind = .focus

    enum BreakKind: Hashable { case focus, short, long }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            if model.timer.isActive {
                runningBody
            } else {
                idleBody
            }

            if let session = model.reflecting {
                PosterView(session: session)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(2)
            }
        }
        .animation(Motion.standard, value: model.timer.phase)
        .animation(Motion.standard, value: model.reflecting?.id)
        .onAppear { intention = model.timer.intention }
        /*
         The field is local state, so it has to be told when the timer's topic
         changes underneath it. Picking tasks on the Tasks tab sets the topic
         and switches here — but this view was already alive, so `onAppear` had
         long since run, and pressing Start would have written the stale text
         back over the titles just chosen.
         */
        .onChange(of: model.timer.intention) { _, updated in
            if updated != intention { intention = updated }
        }
        .sheet(isPresented: $showingTaskPicker) {
            TaskPickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // ── Idle ────────────────────────────────────────────────────────────

    private var idleBody: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                adaptiveTimerContent(maximumDial: 280) {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "Session \(Format.ordinal(model.sessionNumberToday)) · \(Format.weekdayAndDate(context.date))")

                        UnderlinedField(
                            placeholder: "What are you working on?",
                            text: $intention,
                            size: 22,
                            onCommit: { model.setIntention(intention) }
                        )
                        .accessibilityIdentifier("focus.intention")

                        categoryChips

                        SeshSegmented(
                            options: [
                                SegmentOption(BreakKind.focus, "Focus", "\(model.settings.focusDuration) min"),
                                SegmentOption(BreakKind.short, "Short break", "\(model.settings.breakDuration) min"),
                                SegmentOption(BreakKind.long, "Long break", "\(model.settings.longBreakDuration) min"),
                            ],
                            selection: $breakKind
                        )
                    }

                    DialView(
                        totalMs: plannedMs,
                        remainingMs: plannedMs,
                        isRunning: false,
                        isPaused: false,
                        showSecondHand: false,
                        onScrub: { minutes in
                            model.setPlannedMinutes(minutes, for: plannedKind, longBreak: breakKind == .long)
                        }
                    )
                    .layoutValue(key: TimerDialLayoutKey.self, value: true)

                    LinkedTaskCard(refs: model.timer.taskRefs) { showingTaskPicker = true }
                }

                adaptiveActions {
                    VStack(spacing: 8) {
                        Button {
                            model.setIntention(intention)
                            model.start(kind: plannedKind, longBreak: breakKind == .long)
                        } label: {
                            Text("Start \(plannedKind.isFocus ? "focus" : "break") · \(Format.minutes(plannedMs)) min")
                        }
                        .buttonStyle(FocusActionStyle(role: .primary, minimumHeight: actionHeight))
                        .accessibilityIdentifier("focus.start")

                        Text("Ends \(Format.timeOfDay(context.date.addingTimeInterval(Double(plannedMs) / 1000))) · drag the dial to change the length")
                            .metaStyle()
                            .foregroundStyle(theme.palette.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Geometry is the actual space left by the safe areas, tab bar and action
    /// area, including a visible keyboard. The layout measures the content
    /// before choosing a dial size; there is no device-height breakpoint.
    private func adaptiveTimerContent<Content: View>(
        maximumDial: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                TimerContentLayout(
                    viewportHeight: max(0, geometry.size.height - 24),
                    minimumDial: dynamicTypeSize.isAccessibilitySize ? 260 : 164,
                    maximumDial: dynamicTypeSize.isAccessibilitySize ? max(maximumDial, 340) : maximumDial
                ) {
                    content()
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(minHeight: 44)
    }

    /// Usually an intrinsic-height footer. If very large text and the keyboard
    /// leave too little room, its controls gain their own scrolling escape.
    /// The intention field keeps the same identity and keyboard focus.
    private func adaptiveActions<Actions: View>(@ViewBuilder actions: @escaping () -> Actions) -> some View {
        ViewThatFits(in: .vertical) {
            actions().fixedSize(horizontal: false, vertical: true)
            ScrollView { actions() }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.orderedCategories) { category in
                    CategoryChip(
                        label: category.label,
                        color: category.color,
                        isSelected: model.timer.category == category.name
                    ) {
                        Haptics.light()
                        model.setCategory(category.name)
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var plannedKind: SessionKind {
        breakKind == .focus ? .focus : .rest
    }

    private var plannedMs: Int {
        switch breakKind {
        case .focus: return model.settings.focusDuration * 60_000
        case .short: return model.settings.breakDuration * 60_000
        case .long: return model.settings.longBreakDuration * 60_000
        }
    }

    // ── Running ─────────────────────────────────────────────────────────

    private var runningBody: some View {
        // Redrawn once a second, and only while this screen is on show — the
        // countdown itself is derived from the clock, so nothing is lost when
        // the ticking stops.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = Millis(context.date.timeIntervalSince1970 * 1000)
            let remaining = model.timer.remainingMs(now: now)

            VStack(spacing: 0) {
                adaptiveTimerContent(maximumDial: 340) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Text(model.category(named: model.timer.category)?.label ?? model.timer.category)
                                .eyebrowStyle().foregroundStyle(theme.accent)
                            Spacer(minLength: 8)
                            Eyebrow(text: eyebrow(remaining: remaining))
                        }

                        UnderlinedField(
                            placeholder: "Untitled session",
                            text: $intention,
                            size: 20,
                            onCommit: { model.setIntention(intention) }
                        )
                        .accessibilityIdentifier("focus.intention")

                        if let refs = model.timer.taskRefs, !refs.isEmpty {
                            let linked = TaskRef.decodeList(refs).count
                            Text("Logging to \(linked) task\(linked == 1 ? "" : "s")")
                                .metaStyle()
                                .foregroundStyle(theme.palette.textTertiary)
                        }

                        if let status = model.sharedTimerStatus {
                            Text(status)
                                .metaStyle()
                                .foregroundStyle(theme.palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("focus.sharedStatus")
                        }
                    }

                    DialView(
                        totalMs: model.timer.targetMs,
                        remainingMs: remaining,
                        isRunning: model.timer.phase == .running,
                        isPaused: model.timer.phase == .paused,
                        showSecondHand: true,
                        onScrub: nil
                    )
                    .layoutValue(key: TimerDialLayoutKey.self, value: true)
                }

                adaptiveActions {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Button(model.timer.phase == .paused ? "Resume" : "Pause") {
                                model.timer.phase == .paused ? model.resume() : model.pause()
                            }
                            .buttonStyle(FocusActionStyle(role: .tonal, minimumHeight: actionHeight))
                            .accessibilityIdentifier("focus.pauseResume")

                            Button("Finish") { model.finish(manual: true) }
                                .buttonStyle(FocusActionStyle(role: .ink, minimumHeight: actionHeight))
                                .accessibilityIdentifier("focus.finish")
                        }

                        Button("Abandon session") { showingAbandonConfirm = true }
                            .buttonStyle(FocusActionStyle(role: .quiet, minimumHeight: max(44, actionHeight * 0.92)))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: remaining <= 0) { wasOver, isOver in
                // The chime belongs to the moment of crossing, not to every
                // second after it — and a session restored already overdue
                // should arrive quietly.
                if !wasOver && isOver { announceTarget() }
            }
        }
        .confirmationDialog(
            "Abandon this session?",
            isPresented: $showingAbandonConfirm,
            titleVisibility: .visible
        ) {
            Button("Abandon", role: .destructive) { model.abandon() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Nothing will be logged, and no time will be written back to your tasks.")
        }
    }

    private func eyebrow(remaining: Int) -> String {
        if model.timer.phase == .paused { return "Paused" }
        if remaining < 0 { return "Overtime" }
        let kind = model.timer.kind.isFocus ? "Focus" : "Break"
        return "\(kind) · \(Format.ordinal(model.sessionNumberToday))"
    }

    private func announceTarget() {
        Haptics.success()
        Task { await Chime.shared.play(focus: model.timer.kind.isFocus, enabled: model.settings.soundEnabled) }
    }

}

/// Same visual language as SeshButtonStyle, but multiline accessibility labels
/// may grow beyond the normal button height rather than being clipped.
private struct FocusActionStyle: ButtonStyle {
    let role: ButtonRole2
    let minimumHeight: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.font(15, .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: minimumHeight)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay {
                if role == .quiet {
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .stroke(theme.palette.line, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: return theme.accentInk
        case .ink: return theme.palette.background
        case .tonal, .quiet: return theme.palette.text
        case .warn: return theme.palette.warn
        }
    }

    private var background: Color {
        switch role {
        case .primary: return theme.accent
        case .ink: return theme.palette.text
        case .tonal: return theme.palette.fill2
        case .quiet, .warn: return .clear
        }
    }
}

/// The dial is flexible; the surrounding controls keep their natural height.
/// Any spare room is split around the dial, and overflow remains scrollable.
private struct TimerDialLayoutKey: LayoutValueKey {
    static let defaultValue = false
}

private struct TimerContentLayout: Layout {
    let viewportHeight: CGFloat
    let minimumDial: CGFloat
    let maximumDial: CGFloat
    private let spacing: CGFloat = 14

    private struct Measurements {
        let sizes: [CGSize]
        let dialSide: CGFloat
        let height: CGFloat
        let spare: CGFloat
    }

    private func measure(width: CGFloat, subviews: Subviews) -> Measurements {
        let sizes = subviews.map { view in
            view[TimerDialLayoutKey.self] ? CGSize.zero : view.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        let fixedHeight = sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, subviews.count - 1))
        let dialSide = min(width, max(min(minimumDial, width), min(maximumDial, viewportHeight - fixedHeight)))
        let intrinsicHeight = fixedHeight + dialSide
        let height = max(viewportHeight, intrinsicHeight)
        return Measurements(sizes: sizes, dialSide: dialSide, height: height, spare: height - intrinsicHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? maximumDial
        return CGSize(width: width, height: measure(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let view = subviews[index]
            if view[TimerDialLayoutKey.self] {
                y += measured.spare / 2
                view.place(
                    at: CGPoint(x: bounds.midX, y: y), anchor: .top,
                    proposal: ProposedViewSize(width: measured.dialSide, height: measured.dialSide)
                )
                y += measured.dialSide + measured.spare / 2
            } else {
                let size = measured.sizes[index]
                view.place(
                    at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: size.height)
                )
                y += size.height
            }
            y += spacing
        }
    }
}

private struct LinkedTaskCard: View {
    let refs: String?
    let onChoose: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var linked: [ExternalTask] {
        let wanted = Set(TaskRef.split(refs))
        return model.tasks.filter { wanted.contains($0.ref.encoded) }
    }

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if linked.isEmpty {
                        Text("No task linked").rowTitleStyle().foregroundStyle(theme.palette.textSecondary)
                        Text("Nothing will be written back").metaStyle().foregroundStyle(theme.palette.textTertiary)
                    } else {
                        Text(linked.map(\.content).joined(separator: " · "))
                            .rowTitleStyle()
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(linked.first?.projectName ?? "")
                            .metaStyle()
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(linked.isEmpty ? "Choose" : "Change")
                    .font(Typeface.font(13, .semibold))
                    .foregroundStyle(theme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.fill1, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
