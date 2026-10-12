import SwiftUI
import SeshCore

/// A durable reflection: edits stay on this phone until completion succeeds.
struct PosterView: View {
    let session: Session
    @Environment(AppModel.self) private var model
    @State private var showingTasks = false

    private var draft: Session { model.reflecting ?? session }
    private var accent: AccentTheme {
        Accent.accent(for: model.category(named: draft.category)?.color ?? Accent.defaultAccent, dark: false)
    }
    private var ink: Color { Color(hex: accent.on) }
    private var refs: [TaskRef] { TaskRef.decodeList(draft.todoistTaskId) }

    var body: some View {
        ZStack {
            Color(hex: accent.base).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 6) {
                        Text("Session reflection").eyebrowStyle()
                        Text("\(draft.minutes)").numeralStyle(80, weight: .bold)
                        Text("minutes · \(model.category(named: draft.category)?.label ?? draft.category)").metaStyle()
                    }
                    .frame(maxWidth: .infinity)
                    TextField("What did you work on?", text: Binding(
                        get: { draft.intention }, set: { model.editReflection(intention: $0) }
                    ), axis: .vertical)
                    .font(Typeface.font(22, .medium))
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.25)).frame(height: 1) }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes").eyebrowStyle()
                        TextField("What moved forward? What’s next?", text: Binding(
                            get: { draft.notes }, set: { model.editReflection(notes: $0) }
                        ), axis: .vertical)
                        .lineLimit(4...10)
                        .font(Typeface.font(16, .regular))
                        .padding(14)
                        .background(ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("reflection.notes")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How did it go?").eyebrowStyle()
                        HStack(spacing: 8) {
                            rating("Focused", 5)
                            rating("So-so", 3)
                            rating("Scattered", 1)
                        }
                    }
                    Button { showingTasks = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(refs.isEmpty ? "No task linked" : "\(refs.count) task\(refs.count == 1 ? "" : "s") linked")
                                    .rowTitleStyle()
                                Text(refs.isEmpty ? "Choose tasks to log this time to" : "Change where this time is logged")
                                    .metaStyle().opacity(0.75)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(14)
                        .background(ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    if let error = model.reflectionError {
                        Text(error).metaStyle().accessibilityIdentifier("reflection.error")
                    }
                    VStack(spacing: 8) {
                        Button(model.savingReflection ? "Saving…" : "Save session") { model.saveReflection() }
                            .seshButton(.ink)
                            .disabled(model.savingReflection)
                            .accessibilityIdentifier("reflection.save")
                        if model.timer.phase == .reflect {
                            Button("Save & start break · \(model.settings.breakDuration) min") {
                                if model.saveReflection() { model.start(kind: .rest) }
                            }
                            .seshButton(.quiet, size: 44)
                            Button("Back to paused session") { model.returnToPausedSession() }
                                .seshButton(.quiet, size: 44)
                                .accessibilityIdentifier("reflection.back")
                        } else {
                            Text("Your break is running. Save when you’re ready.").metaStyle()
                        }
                    }
                }
                .foregroundStyle(ink)
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showingTasks) {
            TaskPickerSheet(forReflection: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func rating(_ label: String, _ value: Int) -> some View {
        Button {
            model.editReflection(rating: draft.rating == value ? 0 : value)
            Haptics.light()
        } label: {
            Text(label).font(Typeface.font(13, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(ink.opacity(draft.rating == value ? 0.24 : 0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(draft.rating == value ? 0.65 : 0), lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.rating == value ? .isSelected : [])
    }
}
