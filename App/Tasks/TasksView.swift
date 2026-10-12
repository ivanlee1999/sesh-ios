import SwiftUI
import SeshCore

/**
 The real to-do lists, not a second one.

 sesh never owned these tasks and does not pretend to: they come from Things and
 Todoist, the only things it writes back are a completion and the minutes spent,
 and everything else is somebody else's app to change.

 Offline the list is simply the last one fetched, said out loud in the header
 rather than hidden — "cached 12 min ago" is more use than a spinner that will
 never resolve. Ticking something off and adding a to-do both work; they are
 queued and land when there is signal.
 */
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var filter: Filter = .today
    @State private var sort: Sort = .date
    @State private var datedOnly = false
    @State private var selection: Set<String> = []
    @State private var composerText = ""
    @State private var isRefreshing = false

    enum Filter: String, Hashable, CaseIterable {
        case today, upcoming, all
        var label: String { rawValue.capitalized }
    }

    enum Sort: String, Hashable, CaseIterable {
        case date, priority, project
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
            Hairline()

            if visibleTasks.isEmpty {
                emptyState
            } else {
                list
            }

            if !selection.isEmpty { selectionBar }
        }
        .background(theme.palette.background)
        .task { if model.tasks.isEmpty { await refresh() } }
    }

    // ── Header ──────────────────────────────────────────────────────────

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").titleStyle()
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.textSecondary)
            }

            if let caption = cacheCaption {
                Text(caption).metaStyle().foregroundStyle(theme.palette.textTertiary)
            }

            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { option in
                    CategoryChip(
                        label: "\(option.label) · \(count(for: option))",
                        color: theme.isDark ? "#3a3836" : "#e7e3de",
                        isSelected: filter == option
                    ) {
                        Haptics.light()
                        filter = option
                    }
                }
            }

            HStack(spacing: 14) {
                Button(datedOnly ? "Dated only ✓" : "Dated only") {
                    datedOnly.toggle()
                }
                .font(Typeface.font(12.5, .medium))
                .foregroundStyle(datedOnly ? theme.accent : theme.palette.textSecondary)

                Button("Sort · \(sort.label)") {
                    let all = Sort.allCases
                    let next = all.firstIndex(of: sort).map { all[($0 + 1) % all.count] } ?? .date
                    sort = next
                }
                .font(Typeface.font(12.5, .medium))
                .foregroundStyle(theme.palette.textSecondary)

                Spacer()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var cacheCaption: String? {
        let fetched = model.taskSources.compactMap(\.fetchedAt).max()
        guard let fetched else { return "Not fetched yet" }
        let age = Int((Double(model.nowMs() - fetched) / 60_000).rounded())
        if let error = model.taskSources.compactMap(\.error).first {
            return "Showing the cached list · \(error)"
        }
        return age <= 1 ? "Up to date" : "Cached \(age) min ago"
    }

    // ── Composer ────────────────────────────────────────────────────────

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary)

            TextField("Add a to-do to Things", text: $composerText)
                .font(Typeface.font(15))
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit(submitComposer)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func submitComposer() {
        let title = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // The destination follows the list you are looking at: filing everything
        // under Today would quietly turn someone's Today list into an inbox.
        model.createTask(title: title, when: filter == .today ? "today" : "inbox")
        composerText = ""
        Haptics.light()
    }

    // ── List ────────────────────────────────────────────────────────────

    private var list: some View {
        List {
            ForEach(visibleTasks) { task in
                TaskRow(
                    task: task,
                    isSelected: selection.contains(task.ref.encoded),
                    onToggleSelect: { toggleSelection(task) },
                    onComplete: { model.completeTask(task) },
                    onFocus: { focus(on: [task]) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                .listRowBackground(theme.palette.background)
                .listRowSeparatorTint(theme.palette.line)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(model.taskSources.contains { $0.connected } ? "Nothing here" : "No task source connected")
                .rowTitleStyle()
                .foregroundStyle(theme.palette.text)
            Text(model.taskSources.contains { $0.connected }
                 ? "Anything you add lands in Things."
                 : "Connect Things or Todoist in Settings to see your real work here.")
                .metaStyle()
                .foregroundStyle(theme.palette.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    // ── Selection ───────────────────────────────────────────────────────

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected").metaStyle().foregroundStyle(theme.palette.textSecondary)
            Spacer()
            Button("Clear") { selection.removeAll() }
                .seshButton(.quiet, size: 36)
                .fixedSize()
            Button("Focus") {
                focus(on: visibleTasks.filter { selection.contains($0.ref.encoded) })
            }
            .seshButton(.primary, size: 36)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.palette.surface)
        .overlay(alignment: .top) { Hairline() }
    }

    private func toggleSelection(_ task: ExternalTask) {
        let key = task.ref.encoded
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }

    /**
     Hand a set of tasks to the timer.

     The lead task decides the category and the length — its own estimate,
     clamped to something the dial can show — and the title is every task joined,
     because a session against three things is honestly about three things.
     */
    private func focus(on tasks: [ExternalTask]) {
        guard !tasks.isEmpty else { return }
        let lead = tasks[0]
        let category = lead.category.flatMap { label in
            model.categories.first { $0.name == label || $0.label.caseInsensitiveCompare(label) == .orderedSame }
        }
        model.linkTasks(
            tasks.map { $0.ref.encoded },
            leadCategory: category?.name,
            title: tasks.map(\.content).joined(separator: " · ")
        )
        if let minutes = lead.suggestedMinutes {
            model.setPlannedMinutes(minutes, for: .focus, longBreak: false)
        }
        selection.removeAll()
        model.selectedTab = .focus
        Haptics.medium()
    }

    // ── Filtering ───────────────────────────────────────────────────────

    private var clock: DayClock { DayClock() }

    private func matches(_ task: ExternalTask, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .today: return task.dueKind(clock: clock) == .today
        case .upcoming:
            let kind = task.dueKind(clock: clock)
            return kind == .tomorrow || kind == .upcoming
        }
    }

    private func count(for filter: Filter) -> Int {
        model.tasks.filter { matches($0, filter) }.count
    }

    private var visibleTasks: [ExternalTask] {
        var result = model.tasks.filter { matches($0, filter) }
        if datedOnly { result = result.filter { $0.dueDate != nil } }

        switch sort {
        case .date:
            // Undated work always sits last: it has not been asked for yet.
            result.sort { a, b in
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?): return x == y ? a.content < b.content : x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.content < b.content
                }
            }
        case .priority:
            result.sort { $0.priority == $1.priority ? $0.content < $1.content : $0.priority < $1.priority }
        case .project:
            result.sort {
                let left = $0.projectName ?? ""
                let right = $1.projectName ?? ""
                return left == right ? $0.content < $1.content : left < right
            }
        }
        return result
    }

    private func refresh() async {
        isRefreshing = true
        await model.refreshTasks()
        model.reload()
        isRefreshing = false
    }
}

struct TaskRow: View {
    let task: ExternalTask
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onComplete: () -> Void
    let onFocus: () -> Void

    @Environment(\.theme) private var theme

    private var providerColor: Color {
        task.resolvedProvider == .things ? Color(hex: "#1A79E5") : Color(hex: "#E44332")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onComplete) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.palette.lineStrong, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.content)
                    .rowTitleStyle()
                    .foregroundStyle(theme.palette.text)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Circle().fill(providerColor).frame(width: 6, height: 6)
                    Text(metaLine)
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }

            Spacer(minLength: 6)

            if isSelected {
                Button("Focus", action: onFocus)
                    .seshButton(.tonal, size: 32)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelect)
        .background(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(theme.accent.opacity(0.08))
                    .padding(.horizontal, -8)
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let project = task.projectName, !project.isEmpty { parts.append(project) }
        if let due = task.dueLabel, !due.isEmpty { parts.append(due) }
        if let duration = task.duration, duration.amount > 0 { parts.append("\(duration.amount)m") }
        return parts.joined(separator: " · ")
    }
}

/// The same list, as a sheet, for picking what a session is against.
struct TaskPickerSheet: View {
    var forReflection = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if model.tasks.isEmpty {
                    Text("No cached tasks. Connect Things or Todoist in Settings, then sync to choose tasks.")
                        .foregroundStyle(theme.palette.textSecondary)
                }
                ForEach(model.tasks) { task in
                    Button {
                        let key = task.ref.encoded
                        if chosen.contains(key) { chosen.remove(key) } else { chosen.insert(key) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.content).rowTitleStyle()
                                Text(task.projectName ?? "").metaStyle().foregroundStyle(theme.palette.textTertiary)
                            }
                            Spacer()
                            if chosen.contains(task.ref.encoded) {
                                Image(systemName: "checkmark").foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Link tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") {
                        let tasks = model.tasks.filter { chosen.contains($0.ref.encoded) }
                        if forReflection {
                            model.editReflection(taskRefs: chosen.sorted())
                        } else {
                            model.linkTasks(
                                chosen.sorted(), leadCategory: nil,
                                title: tasks.isEmpty ? nil : tasks.map(\.content).joined(separator: " · ")
                            )
                        }
                        dismiss()
                    }
                }
            }
        }
        .onAppear { chosen = Set(TaskRef.split(forReflection ? model.reflecting?.todoistTaskId : model.timer.taskRefs)) }
    }
}
