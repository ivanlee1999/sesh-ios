import SwiftUI
import SeshCore

/**
 What just happened, said plainly.

 A full-bleed panel in the category's own colour, because finishing deserves a
 moment rather than a toast that slides away. The sentence in the middle is the
 part that matters: it says exactly where the time went and what was written
 back, rather than leaving someone to guess whether their twenty-five minutes
 reached Things.

 It floats over a break that has already started, when auto-start is on, so
 nothing is lost to reading it.
 */
struct PosterView: View {
    let session: Session

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var title: String = ""
    @State private var didAppear = false

    private var accent: AccentTheme {
        Accent.accent(for: model.category(named: session.category)?.color ?? Accent.defaultAccent, dark: false)
    }

    var body: some View {
        ZStack {
            Color(hex: accent.base).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(ink)
                        .scaleEffect(didAppear ? 1 : 0.6)
                        .opacity(didAppear ? 1 : 0)
                        .animation(Motion.spring.delay(0.05), value: didAppear)

                    Text("Session logged")
                        .eyebrowStyle()
                        .foregroundStyle(ink.opacity(0.75))

                    Text("\(session.minutes)")
                        .numeralStyle(96, weight: .bold)
                        .foregroundStyle(ink)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text("minutes · \(model.category(named: session.category)?.label ?? session.category)")
                        .metaStyle()
                        .foregroundStyle(ink.opacity(0.8))

                    TextField("Untitled session", text: $title)
                        .font(Typeface.font(17, .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ink)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(ink.opacity(0.25)).frame(height: 1)
                        }
                        .onSubmit { model.editReflecting(intention: title) }

                    Text(writeBackSentence)
                        .metaStyle()
                        .foregroundStyle(ink.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    ratingRow

                    destinations
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            title = session.intention
            didAppear = true
        }
    }

    private var ink: Color { Color(hex: accent.on) }

    // ── The sentence ────────────────────────────────────────────────────

    /**
     Where the time went, in words.

     The web app is careful about this and so is this: naming the tasks when
     there are tasks, and saying plainly that nothing was written back when
     there are none — rather than staying silent and letting someone assume it
     worked.
     */
    private var writeBackSentence: String {
        let refs = TaskRef.decodeList(session.todoistTaskId)
        let categoryLabel = model.category(named: session.category)?.label ?? session.category

        guard !refs.isEmpty else {
            return "Logged to \(categoryLabel). No task linked, so nothing was written back."
        }

        let linked = model.tasks.filter { task in refs.contains(task.ref) }
        let lead = linked.first?.content ?? "your task"
        let others = max(0, refs.count - 1)
        let tail = others == 0 ? "" : " and \(others) more"
        let mirrored = model.settings.calendarSync ? " Mirrored to Google Calendar." : ""

        return "+\(session.minutes) min will be written back to \"\(lead)\"\(tail).\(mirrored)"
    }

    // ── Rating ──────────────────────────────────────────────────────────

    private var ratingRow: some View {
        VStack(spacing: 10) {
            Text("How did it go?")
                .metaStyle()
                .foregroundStyle(ink.opacity(0.8))

            HStack(spacing: 8) {
                ratingButton("Focused", 5)
                ratingButton("So-so", 3)
                ratingButton("Scattered", 1)
            }
        }
        .padding(.top, 4)
    }

    private func ratingButton(_ label: String, _ value: Int) -> some View {
        Button {
            Haptics.light()
            model.rate(session, rating: value)
        } label: {
            Text(label)
                .font(Typeface.font(13, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(ink)
                .background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // ── Where next ──────────────────────────────────────────────────────

    @ViewBuilder
    private var destinations: some View {
        VStack(spacing: 8) {
            if model.timer.isActive {
                // A break is already running underneath, so the lead action is
                // simply to get out of the way.
                Button("Back to the dial") { model.dismissPoster() }
                    .seshButton(.ink)
                Button("Skip to next focus") {
                    model.dismissPoster()
                    model.start(kind: .focus)
                }
                .seshButton(.quiet, size: 44)
            } else {
                Button("Start break · \(model.settings.breakDuration) min") {
                    model.dismissPoster()
                    model.start(kind: .rest)
                }
                .seshButton(.ink)

                Button("Next focus") {
                    model.dismissPoster()
                    model.start(kind: .focus)
                }
                .seshButton(.quiet, size: 44)

                Button("Back to the dial") { model.dismissPoster() }
                    .seshButton(.quiet, size: 44)
            }
        }
        .tint(ink)
        .padding(.top, 6)
    }
}
