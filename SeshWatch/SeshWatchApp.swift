import SwiftUI
import SeshCore

@main
struct SeshWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WatchHomeView(model: model)
                .task { model.activate() }
                .onOpenURL { _ in model.refresh(); model.flush() }
                .onReceive(NotificationCenter.default.publisher(for: .seshWatchTimerChanged)) { _ in
                    model.refresh(); model.flush()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh(); model.flush() }
        }
    }
}

private struct WatchHomeView: View {
    @Bindable var model: WatchModel
    @State private var newSession = false
    @State private var confirmFinish = false
    @Environment(\.isLuminanceReduced) private var reduced
    private let accent = Color(red: 0.94, green: 0.65, blue: 0.49)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let conflict = model.document.conflict {
                        conflictView(conflict)
                    } else if let draft = model.document.timer.reflection {
                        ReflectionView(model: model, draft: draft)
                    } else if model.document.timer.isActive {
                        activeView
                    } else { readyView }
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red).accessibilityLabel("Error: \(error)")
                    }
                    if !model.document.pending.isEmpty && model.document.conflict == nil {
                        Label("Saved on Watch", systemImage: "checkmark.shield")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Syncs when iPhone is available.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.document.pending.isEmpty, let message = model.document.snapshot.syncMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !model.document.recovered.isEmpty {
                        NavigationLink { RecoveryView(model: model) } label: {
                            Label("Recovered sessions", systemImage: "tray.full")
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("sesh")
            .tint(accent)
            .sheet(isPresented: $newSession) { NewSessionView(model: model) }
            .confirmationDialog("Finish this session?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish session") { model.perform(.finish) }
                Button("Keep going", role: .cancel) {}
            } message: { Text("Your focus time stays safe. You can add a reflection before saving.") }
        }
    }

    private var readyView: some View {
        VStack(spacing: 8) {
            Text("Make room\nfor focus.").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("\(model.document.lastMinutes) min · \(categoryLabel)")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task {
                    await model.requestAlerts()
                    model.perform(.start, minutes: model.document.lastMinutes, category: model.document.lastCategory)
                }
            } label: { Label("Start focus", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts your last used focus preset")
            Button("New session") { newSession = true }.frame(minHeight: 44)
        }
    }

    private var categoryLabel: String {
        model.document.preferences.categories.first { $0.name == model.document.lastCategory }?.label ?? "Focus"
    }

    private var activeView: some View {
        let timer = model.document.timer
        return VStack(spacing: 8) {
            Text(timer.intention.isEmpty ? (timer.kind.isFocus ? "FOCUS" : "BREAK") : timer.intention)
                .font(.headline).lineLimit(1).foregroundStyle(accent).privacySensitive()
                .accessibilityLabel("\(timer.kind.isFocus ? "Focus" : "Break"), \(timer.intention)")
            TimelineView(.periodic(from: .now, by: reduced ? 60 : 1)) { context in
                let now = Int64(context.date.timeIntervalSince1970 * 1000)
                let remaining = timer.remainingMs(now: now)
                ZStack {
                    Circle().stroke(accent.opacity(0.2), lineWidth: 7)
                    Circle().trim(from: 0, to: max(0, min(1, Double(remaining) / Double(max(1, timer.targetMs)))))
                        .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .accessibilityHidden(true)
                    VStack(spacing: 2) {
                        Text(WatchClock.string(remaining))
                            .font(.system(size: 43, weight: .medium, design: .rounded).monospacedDigit())
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text(timer.phase == .paused ? "Paused" : (remaining <= 0 ? "Overtime" : "Remaining"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(12)
                }
                .frame(maxWidth: 100).aspectRatio(1, contentMode: .fit)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timer.phase == .paused ? "Timer paused" : (remaining <= 0 ? "Timer in overtime" : "Running timer"))
                .accessibilityValue(WatchClock.string(remaining))
            }
            Button { model.perform(timer.phase == .paused ? .resume : .pause) } label: {
                Label(timer.phase == .paused ? "Resume" : "Pause", systemImage: timer.phase == .paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).frame(minHeight: 44)
            Button("Finish session") { confirmFinish = true }.frame(minHeight: 44)
                .accessibilityHint("Stops focus and opens your reflection")
        }
    }

    private func conflictView(_ phone: WatchSnapshot) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(accent).accessibilityHidden(true)
            Text("Two timers changed").font(.headline).multilineTextAlignment(.center)
            Text("iPhone has \(phone.timer.isActive ? "an active session" : "a newer timer"). Your Watch session is kept here.")
                .font(.caption).multilineTextAlignment(.center)
            Button("Use iPhone timer") { model.keepPhone() }.buttonStyle(.borderedProminent)
            Text("Your Watch work moves to Recovered sessions, where you can save it to iPhone.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct NewSessionView: View {
    @Bindable var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 25
    @State private var intention = ""
    @State private var category = "deep"
    @State private var rest = false
    var body: some View {
        NavigationStack {
            Form {
                Toggle("Break", isOn: $rest)
                Picker("Minutes", selection: $minutes) {
                    ForEach(1...180, id: \.self) { Text("\($0) min").tag($0) }
                }
                TextField("Intention (optional)", text: $intention)
                Picker("Category", selection: $category) {
                    ForEach(model.document.preferences.categories) { Text($0.label).tag($0.name) }
                }
                Button("Start \(rest ? "break" : "focus")") {
                    Task {
                        await model.requestAlerts()
                        model.perform(.start, minutes: minutes, intention: intention, category: category, kind: rest ? .rest : .focus)
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent)
            }
            .navigationTitle("New session")
            .onAppear {
                minutes = model.document.lastMinutes
                category = model.document.preferences.categories.contains { $0.name == model.document.lastCategory }
                    ? model.document.lastCategory : (model.document.preferences.categories.first?.name ?? "deep")
            }
            .onChange(of: rest) { _, value in
                minutes = value ? model.document.preferences.breakMinutes : model.document.preferences.focusMinutes
            }
        }
    }
}

private struct ReflectionView: View {
    @Bindable var model: WatchModel
    let draft: Session
    private var rating: Int { model.document.timer.reflection?.rating ?? draft.rating }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.largeTitle).accessibilityHidden(true)
            Text("Time well spent").font(.headline)
            Text("\(draft.minutes) min · \(draft.intention.isEmpty ? "Focus" : draft.intention)")
                .font(.caption).multilineTextAlignment(.center).privacySensitive()
            TextField("Reflection (optional)", text: Binding(
                get: { model.document.timer.reflection?.notes ?? draft.notes },
                set: { model.perform(.editReflection, notes: $0) }))
            Text("How was your focus?").font(.headline)
            focusRating("Focused", value: 5)
            focusRating("So-so", value: 3)
            focusRating("Scattered", value: 1)
            Button("Save session") { model.perform(.save) }.buttonStyle(.borderedProminent).frame(minHeight: 44)
            if model.document.timer.isActive {
                Text("Your break is \(model.document.timer.phase == .paused ? "paused" : "running").")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(model.document.timer.phase == .paused ? "Resume break" : "Pause break") {
                    model.perform(model.document.timer.phase == .paused ? .resume : .pause)
                }
            }
        }
    }

    private func focusRating(_ label: String, value: Int) -> some View {
        Button {
            model.perform(.editReflection, rating: rating == value ? 0 : value)
        } label: {
            HStack {
                Text(label)
                Spacer(minLength: 4)
                if rating == value { Image(systemName: "checkmark") }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(label), focus rating \(value) of 5")
        .accessibilityAddTraits(rating == value ? .isSelected : [])
        .accessibilityHint("Tap again to clear your rating")
    }
}

private struct RecoveryView: View {
    @Bindable var model: WatchModel
    var body: some View {
        List {
            Text("These Watch sessions were kept after a sync conflict. Saving adds history and keeps the iPhone timer.")
                .font(.caption)
            ForEach(model.document.recovered) { session in
                VStack(alignment: .leading) {
                    Text(session.intention.isEmpty ? "Focus session" : session.intention)
                    Text("\(session.minutes) min").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Save to iPhone") { model.importRecovery() }
        }.navigationTitle("Recovered")
    }
}
