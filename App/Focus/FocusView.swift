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
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let remote = model.remoteTimer, remote.belongsToAnotherDevice(deviceIdentity) {
                        RemoteTimerBanner(remote: remote)
                    }

                    Eyebrow(text: "Session \(Format.ordinal(model.sessionNumberToday)) · \(Format.weekdayAndDate(Date()))")

                    UnderlinedField(
                        placeholder: "What are you working on?",
                        text: $intention,
                        size: 22,
                        onCommit: { model.setIntention(intention) }
                    )

                    categoryChips

                    SeshSegmented(
                        options: [
                            SegmentOption(BreakKind.focus, "Focus", "\(model.settings.focusDuration) min"),
                            SegmentOption(BreakKind.short, "Short break", "\(model.settings.breakDuration) min"),
                            SegmentOption(BreakKind.long, "Long break", "\(model.settings.longBreakDuration) min"),
                        ],
                        selection: $breakKind
                    )

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
                    .frame(maxHeight: 280)
                    .frame(maxWidth: .infinity)

                    LinkedTaskCard(refs: model.timer.taskRefs) { showingTaskPicker = true }

                    VStack(spacing: 8) {
                        Button {
                            model.setIntention(intention)
                            model.start(kind: plannedKind, longBreak: breakKind == .long)
                        } label: {
                            Text("Start \(plannedKind.isFocus ? "focus" : "break") · \(Format.minutes(plannedMs)) min")
                        }
                        .seshButton(.primary)

                        Text("Ends \(Format.timeOfDay(Date().addingTimeInterval(Double(plannedMs) / 1000))) · drag the dial to change the length")
                            .metaStyle()
                            .foregroundStyle(theme.palette.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
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

            VStack(spacing: 18) {
                Spacer(minLength: 0)

                Eyebrow(text: eyebrow(remaining: remaining))

                UnderlinedField(
                    placeholder: "Untitled session",
                    text: $intention,
                    size: 20,
                    onCommit: { model.setIntention(intention) }
                )
                .padding(.horizontal, 4)

                if let refs = model.timer.taskRefs, !refs.isEmpty {
                    let linked = TaskRef.decodeList(refs).count
                    Text("Logging to \(linked) task\(linked == 1 ? "" : "s")")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                }

                DialView(
                    totalMs: model.timer.targetMs,
                    remainingMs: remaining,
                    isRunning: model.timer.phase == .running,
                    isPaused: model.timer.phase == .paused,
                    showSecondHand: true,
                    onScrub: nil
                )
                .frame(maxHeight: 320)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button(model.timer.phase == .paused ? "Resume" : "Pause") {
                        model.timer.phase == .paused ? model.resume() : model.pause()
                    }
                    .seshButton(.tonal)

                    Button("Finish") { model.finish(manual: true) }
                        .seshButton(.ink)
                }

                Button("Abandon session") { showingAbandonConfirm = true }
                    .seshButton(.quiet, size: 40)
                    .padding(.bottom, 4)
            }
            .padding(20)
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

    private var deviceIdentity: String { model.deviceIdentity }
}

/// A session running elsewhere. Offered, never adopted on its own.
private struct RemoteTimerBanner: View {
    let remote: RemoteTimer
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Running on another device").rowTitleStyle()
                Text("\(remote.intention.isEmpty ? "Focus" : remote.intention) · \(Format.clock(max(0, remote.remainingMs(now: Millis(Date().timeIntervalSince1970 * 1000)))))")
                    .metaStyle()
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Take over") { model.takeOverRemoteTimer() }
                .seshButton(.tonal, size: 36)
                .fixedSize()
        }
        .padding(14)
        .background(theme.palette.fill1, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
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
