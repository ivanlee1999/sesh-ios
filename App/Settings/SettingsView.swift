import SwiftUI
import UserNotifications
import SeshCore
import SeshStore

/**
 The settings, and the honest account of what is and is not working.

 The sync section is the one that earns its place: an offline-first app has to
 say what it is holding and what went wrong, or the person has no way to tell
 "nothing to send" from "quietly failing to send it".
 */
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var showingCategories = false
    @State private var showingThings = false
    @State private var showingGoogle = false
    @State private var notificationsAllowed = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            timerSection
            alertsSection
            coloursSection
            sourcesSection
            syncSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.palette.background)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingCategories) { CategoriesSheet() }
        .sheet(isPresented: $showingThings) { ThingsSheet() }
        .sheet(isPresented: $showingGoogle) { GoogleConnectSheet() }
        .task { notificationsAllowed = await TimerNotifications.authorizationStatus() == .authorized }
    }

    // ── Timer ───────────────────────────────────────────────────────────

    private var timerSection: some View {
        Section("Timer") {
            SeshStepper(
                title: "Focus length",
                value: binding(\.focusDuration, key: .focusDuration),
                range: 5...90
            )
            SeshStepper(
                title: "Short break",
                value: binding(\.breakDuration, key: .breakDuration),
                range: 1...30
            )
            SeshStepper(
                title: "Long break",
                value: binding(\.longBreakDuration, key: .longBreakDuration),
                range: 5...60
            )
            SeshStepper(
                title: "Long break after",
                value: binding(\.sessionsBeforeLongBreak, key: .sessionsBeforeLongBreak),
                range: 2...8,
                step: 1,
                unit: "sessions"
            )
        }
    }

    // ── Alerts ──────────────────────────────────────────────────────────

    private var alertsSection: some View {
        Section("Alerts") {
            HStack {
                Text("Your name").rowTitleStyle()
                Spacer()
                TextField("there", text: nameBinding)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.palette.textSecondary)
            }

            SeshToggle(
                title: "Timer alerts",
                detail: notificationsAllowed
                    ? "Fires at your target and every five minutes after, with or without a network."
                    : "Allow notifications so a session can tell you it is over while the app is closed.",
                isOn: Binding(
                    get: { notificationsAllowed },
                    set: { wanted in
                        guard wanted else { return }
                        Task { notificationsAllowed = await TimerNotifications.requestAuthorization() }
                    }
                )
            )

            SeshToggle(title: "Completion sound", isOn: binding(\.soundEnabled, key: .soundEnabled))
            SeshToggle(
                title: "Mirror to Google Calendar",
                detail: "Focus sessions become events on a calendar named sesh. Breaks are left out.",
                isOn: binding(\.calendarSync, key: .calendarSync)
            )
            SeshToggle(title: "Dark interface", isOn: binding(\.darkMode, key: .darkMode))
            SeshToggle(title: "Auto-start breaks", isOn: binding(\.autoStartBreak, key: .autoStartBreak))
            SeshToggle(title: "Auto-start focus", isOn: binding(\.autoStartFocus, key: .autoStartFocus))
            SeshToggle(
                title: "Keep screen awake",
                detail: "While a session is running.",
                isOn: binding(\.keepScreenAwake, key: .keepScreenAwake)
            )
        }
    }

    // ── Colours ─────────────────────────────────────────────────────────

    private var coloursSection: some View {
        Section("Colours") {
            ForEach(model.categories) { category in
                HStack(spacing: 12) {
                    Circle().fill(Color(hex: category.color)).frame(width: 18, height: 18)
                    Text(category.label).rowTitleStyle()
                    Spacer()
                    Text("\((try? model.repository.sessionCount(forCategory: category.name)) ?? 0)")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            Button("Edit categories") { showingCategories = true }
                .foregroundStyle(theme.accent)
        }
    }

    // ── Sources ─────────────────────────────────────────────────────────

    private var sourcesSection: some View {
        Section("Sources") {
            SeshToggle(
                title: "Todoist",
                detail: "Applies to every device, not just this one.",
                isOn: binding(\.todoistEnabled, key: .todoistEnabled)
            )

            Button {
                showingThings = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Things 3").rowTitleStyle().foregroundStyle(theme.palette.text)
                        Text(thingsStatus).metaStyle().foregroundStyle(theme.palette.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.syncStatus.isOffline)

            Button {
                showingGoogle = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Calendar").rowTitleStyle().foregroundStyle(theme.palette.text)
                        Text(model.settings.calendarSync ? "Mirroring focus sessions" : "Not connected")
                            .metaStyle().foregroundStyle(theme.palette.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.syncStatus.isOffline)

            Button("Refresh task lists") {
                Task { await model.refreshTasks(); model.reload() }
            }
            .foregroundStyle(theme.accent)
            .disabled(model.syncStatus.isOffline)
        }
    }

    private var thingsStatus: String {
        guard let source = model.taskSources.first(where: { $0.provider == .things }) else { return "Not connected" }
        if let error = source.error { return error }
        return source.connected ? "Connected" : "Not connected"
    }

    // ── Sync ────────────────────────────────────────────────────────────

    private var syncSection: some View {
        Section("Sync") {
            HStack {
                Text("Waiting to send").rowTitleStyle()
                Spacer()
                Text("\(model.syncStatus.pending)")
                    .numeralStyle(14)
                    .foregroundStyle(model.syncStatus.pending > 0 ? theme.accent : theme.palette.textTertiary)
            }

            HStack {
                Text("Last synced").rowTitleStyle()
                Spacer()
                Text(lastSyncedLabel).metaStyle().foregroundStyle(theme.palette.textTertiary)
            }

            if let error = model.syncStatus.lastError {
                Text(error)
                    .metaStyle()
                    .foregroundStyle(theme.palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(model.syncStatus.isRunning ? "Syncing…" : "Sync now") {
                Task { await model.syncNow() }
            }
            .foregroundStyle(theme.accent)
            .disabled(model.syncStatus.isRunning)
        }
    }

    private var lastSyncedLabel: String {
        guard let at = model.syncStatus.lastSyncedAt else { return "Never" }
        let minutes = Int((Double(model.nowMs() - at) / 60_000).rounded())
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }

    // ── About ───────────────────────────────────────────────────────────

    private var aboutSection: some View {
        Section {
            Button("Replay the intro") {
                DeviceDefaults.hasOnboarded = false
            }
            .foregroundStyle(theme.accent)

            if let url = exportURL {
                ShareLink(item: url) { Text("Export sessions") }
            } else {
                Button("Export sessions") { exportURL = writeExport() }
                    .foregroundStyle(theme.accent)
            }

            Button("Sign out", role: .destructive) {
                Task { await model.signOut() }
            }
        } footer: {
            Text("Server: \(DeviceDefaults.serverURL)")
                .metaStyle()
                .foregroundStyle(theme.palette.textTertiary)
        }
    }

    /// Straight from the local database, so it works with no signal.
    private func writeExport() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(model.sessions) else { return nil }
        let name = "sesh-sessions-\(DayKey.key(for: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    // ── Bindings ────────────────────────────────────────────────────────

    private func binding(_ path: WritableKeyPath<AppSettings, Int>, key: AppSettings.Key) -> Binding<Int> {
        Binding(
            get: { model.settings[keyPath: path] },
            set: { value in model.updateSetting(key) { $0[keyPath: path] = value } }
        )
    }

    private func binding(_ path: WritableKeyPath<AppSettings, Bool>, key: AppSettings.Key) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: path] },
            set: { value in model.updateSetting(key) { $0[keyPath: path] = value } }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.settings.displayName },
            set: { value in model.updateSetting(.displayName) { $0.displayName = value } }
        )
    }
}

// ── Categories ──────────────────────────────────────────────────────────

struct CategoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var newLabel = ""
    @State private var refusal: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.categories) { category in
                    CategoryEditorRow(category: category)
                }
                .onDelete { offsets in
                    for index in offsets {
                        let category = model.categories[index]
                        if let count = model.deleteCategory(category) {
                            // Refused rather than cascaded: those sessions are
                            // filed under this slug and would lose their name.
                            refusal = "\(category.label) is used by \(count) session\(count == 1 ? "" : "s"). Re-file them first."
                        }
                    }
                }

                Section("Add") {
                    HStack {
                        TextField("New category", text: $newLabel)
                            .textFieldStyle(.plain)
                        Button("Add") {
                            guard !newLabel.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            model.saveCategory(id: nil, label: newLabel, color: Swatches.all.randomElement() ?? "#c0522d")
                            newLabel = ""
                        }
                        .foregroundStyle(theme.accent)
                    }
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Still in use", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
        }
    }
}

private struct CategoryEditorRow: View {
    let category: CategoryRecord
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var label: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label", text: $label)
                .textFieldStyle(.plain)
                .onAppear { label = category.label }
                .onSubmit { model.saveCategory(id: category.id, label: label, color: category.color) }

            HStack(spacing: 8) {
                ForEach(Swatches.all, id: \.self) { swatch in
                    Button {
                        model.saveCategory(id: category.id, label: label.isEmpty ? category.label : label, color: swatch)
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if swatch.caseInsensitiveCompare(category.color) == .orderedSame {
                                    Circle().stroke(theme.palette.text, lineWidth: 2).padding(-3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// ── Things ──────────────────────────────────────────────────────────────

/**
 Signing in to Things.

 Online only, and said so plainly rather than failing at the end: Things
 authenticates against its own cloud on every request, so there is nothing
 useful to queue.
 */
struct ThingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Things account email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } footer: {
                    Text("The account is saved on the server and shared with your other devices. Things issues no token and re-checks the password on every request, so it is stored encrypted there rather than hashed — and never on this phone.")
                }

                if let message {
                    Text(message).metaStyle().foregroundStyle(theme.palette.warn)
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        Task { await disconnect() }
                    }
                }
            }
            .navigationTitle("Things 3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Connecting…" : "Connect") { Task { await connect() } }
                        .disabled(busy || email.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        do {
            try await model.connectThings(email: email, password: password)
            await model.refreshTasks()
            model.reload()
            dismiss()
        } catch {
            message = Self.explain(error)
        }
    }

    private func disconnect() async {
        do {
            try await model.disconnectThings()
            model.reload()
            dismiss()
        } catch {
            message = Self.explain(error)
        }
    }

    /// Things' own refusals are worth repeating; everything else is weather.
    static func explain(_ error: Error) -> String {
        guard let api = error as? APIError else { return "\(error)" }
        switch api {
        case .offline: return "No connection. Things needs one to sign in — there is nothing useful to queue."
        case .unauthorized: return "sesh signed you out. Sign in again first."
        case .server(_, let message): return message ?? "Things refused the sign-in."
        case .decoding: return "Things sent something unexpected."
        }
    }
}
