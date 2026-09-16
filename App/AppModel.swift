import Foundation
import Observation
import SwiftUI
import SeshCore
import SeshStore
#if canImport(UIKit)
import UIKit
#endif

/**
 What the app knows, and the only thing the screens talk to.

 Every mutation here follows the same order, and the order is the whole point:
 write locally, then tell the sync engine there is something to send. Never the
 other way around, and never waiting on the network in between. A tap must land
 in the same frame whether the phone is on wifi or in a lift.

 So there are no loading spinners in this app — not as a style choice, but
 because there is nothing to wait for. The screens read the database; the
 database is always there.
 */
@MainActor
@Observable
final class AppModel {
    // ── What the screens read ───────────────────────────────────────────

    private(set) var sessions: [Session] = []
    private(set) var categories: [CategoryRecord] = []
    private(set) var tasks: [ExternalTask] = []
    private(set) var settings: AppSettings = .defaults
    private(set) var timer: TimerState = .idle
    /// A session running on some other device, offered rather than adopted.
    private(set) var remoteTimer: RemoteTimer?

    var authState: AuthState = .unknown
    private(set) var syncStatus = SyncStatus()
    private(set) var taskSources: [TaskSourceState] = []

    /// The finished session awaiting a rating; the poster is up while this is set.
    var reflecting: Session?
    var selectedTab: Tab = .focus
    var banner: String?

    enum AuthState: Equatable {
        case unknown
        case signedIn
        case signedOut
    }

    enum Tab: String, CaseIterable, Hashable {
        case focus, tasks, calendar, insights, settings

        var label: String {
            switch self {
            case .focus: return "Focus"
            case .tasks: return "Tasks"
            case .calendar: return "Calendar"
            case .insights: return "Insights"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .focus: return "timer"
            case .tasks: return "checklist"
            case .calendar: return "calendar"
            case .insights: return "chart.bar"
            case .settings: return "gearshape"
            }
        }
    }

    struct SyncStatus: Equatable {
        var isRunning = false
        var pending = 0
        var lastSyncedAt: Millis?
        var lastError: String?
        var isOffline = false
    }

    struct TaskSourceState: Identifiable, Equatable {
        let provider: TaskProvider
        var connected: Bool
        var fetchedAt: Millis?
        var error: String?

        var id: String { provider.rawValue }
    }

    // ── Wiring ──────────────────────────────────────────────────────────

    let repository: SeshRepository
    let tokens: TokenStore
    private let client: APIClient
    private let engine: SyncEngine
    private let store: DatabaseSyncStore
    private let liveActivity = LiveActivityController()

    private var deviceId: String = ""
    private var syncTask: Task<Void, Never>?
    private var pendingSync: Task<Void, Never>?

    init(database: AppDatabase, serverURL: URL) {
        let tokens = TokenStore()
        let repository = SeshRepository(database: database)
        let store = DatabaseSyncStore(database: database)
        let client = APIClient(baseURL: serverURL, tokens: tokens)

        self.tokens = tokens
        self.repository = repository
        self.store = store
        self.client = client
        self.engine = SyncEngine(store: store, transport: client)
    }

    func start() async {
        deviceId = (try? store.deviceId()) ?? UUID().uuidString
        let signedIn = await tokens.isSignedIn
        authState = signedIn ? .signedIn : .signedOut
        reload()
        restoreTimer()
        if authState == .signedIn { sync() }
    }

    /// Re-read everything the screens show. Cheap: it is a local database.
    func reload() {
        sessions = (try? repository.sessions()) ?? []
        categories = (try? repository.categories()) ?? []
        settings = (try? repository.settings()) ?? .defaults
        tasks = (try? repository.cachedTasks()) ?? []
        remoteTimer = try? repository.remoteTimer()
        syncStatus.pending = (try? repository.pendingCount()) ?? 0
        if let state = try? repository.syncState() {
            syncStatus.lastSyncedAt = state.lastPullAt
            syncStatus.lastError = state.lastError
        }
        taskSources = loadTaskSources()
    }

    private func loadTaskSources() -> [TaskSourceState] {
        let rows = (try? repository.taskSources()) ?? []
        return TaskProvider.allCases.map { provider in
            let row = rows.first { $0.provider == provider.rawValue }
            return TaskSourceState(
                provider: provider,
                connected: row?.error == nil && row?.fetchedAt != nil,
                fetchedAt: row?.fetchedAt,
                error: row?.error
            )
        }
    }

    // ── Sign in ─────────────────────────────────────────────────────────

    func signIn(username: String, password: String) async -> String? {
        do {
            _ = try await client.signIn(username: username, password: password)
            authState = .signedIn
            sync()
            return nil
        } catch APIError.unauthorized {
            return "That username and password did not work."
        } catch APIError.offline {
            return "Could not reach the server. Check the address and your connection."
        } catch {
            return "Sign in failed: \(error)"
        }
    }

    func signOut() async {
        await tokens.clear()
        authState = .signedOut
    }

    // ── Sync ────────────────────────────────────────────────────────────

    /// Ask for a sync. Coalesced: several calls in a row make one run.
    func sync(debounce: Duration = .seconds(2)) {
        guard authState == .signedIn else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard authState == .signedIn, !syncStatus.isRunning else { return }
        syncStatus.isRunning = true
        defer { syncStatus.isRunning = false }

        await refreshTokenIfNeeded()
        let outcome = await engine.run()

        if outcome.signedOut {
            authState = .signedOut
            banner = "Signed out. Your work is safe on this phone — sign in to sync it."
        }
        syncStatus.isOffline = outcome.lastError?.contains("offline") ?? false
        syncStatus.lastError = outcome.lastError
        try? store.recordSyncError(outcome.lastError)

        await refreshTasks()
        reload()
    }

    private func refreshTokenIfNeeded() async {
        let expiry = await tokens.expiresAt()
        guard expiry > 0 else { return }
        let response = TokenResponse(token: "", expiresAt: expiry, username: nil, authDisabled: nil)
        guard response.needsRefresh(now: nowMs()) else { return }
        _ = try? await client.refreshToken()
    }

    /// Pull both task lists into the cache. Failing is fine; the cache stands.
    func refreshTasks() async {
        guard authState == .signedIn else { return }
        do {
            let data = try await client.tasksSnapshot()
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            for provider in TaskProvider.allCases {
                guard let entry = json[provider.rawValue] as? [String: Any] else { continue }
                let rawTasks = entry["tasks"] as? [[String: Any]] ?? []
                let decoded: [ExternalTask] = rawTasks.compactMap { item in
                    guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                    return try? JSONDecoder().decode(ExternalTask.self, from: itemData)
                }
                let status = (entry["status"] as? [String: Any])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) }
                try repository.replaceTaskCache(
                    provider: provider,
                    tasks: decoded,
                    status: status,
                    error: entry["error"] as? String
                )
            }
        } catch {
            // The cached list is what the person sees either way.
        }
    }

    // ── The timer ───────────────────────────────────────────────────────

    private func restoreTimer() {
        timer = (try? repository.loadTimer()) ?? .idle
        if timer.isActive {
            Task {
                await TimerNotifications.reschedule(for: timer, settings: settings, now: nowMs())
                liveActivity.update(state: timer, accentHex: accentHex, now: nowMs())
            }
        }
        applyWakeLock()
    }

    func start(kind: SessionKind, minutes: Int? = nil, longBreak: Bool = false) {
        let target = (minutes ?? settings.duration(for: kind, longBreak: longBreak)) * 60_000
        var next = timer
        next.start(
            kind: kind,
            intention: kind.isFocus ? next.intention : "",
            category: next.category.isEmpty ? (defaultCategory?.name ?? "") : next.category,
            targetMs: target,
            taskRefs: kind.isFocus ? next.taskRefs : nil,
            now: nowMs()
        )
        commit(next)
        DeviceDefaults.markCategoryUsed(next.category)
        Haptics.medium()
        liveActivity.start(state: next, accentHex: accentHex, now: nowMs())
    }

    func pause() {
        var next = timer
        next.pause(now: nowMs())
        commit(next)
        Haptics.light()
    }

    func resume() {
        var next = timer
        next.resume(now: nowMs())
        commit(next)
        Haptics.light()
    }

    func abandon() {
        var next = timer
        next.abandon()
        commit(next)
        Task { await liveActivity.end() }
        Haptics.light()
    }

    func setIntention(_ text: String) {
        var next = timer
        if next.isActive {
            // Mid-session, moving the topic drops the task link: the minutes
            // should not be written back to work you have moved off.
            next.changeTopic(text)
        } else {
            next.intention = text
        }
        commit(next, mirror: next.isActive)
    }

    func setCategory(_ name: String) {
        var next = timer
        next.category = name
        DeviceDefaults.markCategoryUsed(name)
        commit(next, mirror: next.isActive)
    }

    func setPlannedMinutes(_ minutes: Int, for kind: SessionKind, longBreak: Bool) {
        // Dragging the dial sets the length *and* remembers it, exactly as on
        // the web: the dial is the setting, not a one-off override.
        let key: AppSettings.Key = kind.isFocus ? .focusDuration : (longBreak ? .longBreakDuration : .breakDuration)
        var updated = settings
        switch key {
        case .focusDuration: updated.focusDuration = minutes
        case .longBreakDuration: updated.longBreakDuration = minutes
        default: updated.breakDuration = minutes
        }
        settings = updated
        try? repository.setSetting(key: key.rawValue, value: .number(Double(minutes)))

        var next = timer
        next.targetMs = minutes * 60_000
        commit(next, mirror: false)
        sync()
    }

    func linkTasks(_ refs: [String], leadCategory: String?, title: String?) {
        var next = timer
        next.taskRefs = TaskRef.encodeList(refs)
        if let title, !title.isEmpty { next.intention = title }
        if let leadCategory, !leadCategory.isEmpty { next.category = leadCategory }
        commit(next, mirror: next.isActive)
    }

    /**
     End the session and write it down.

     `manual` distinguishes pressing Finish from the timer simply reaching its
     target, because the two credit different amounts — see `TimerState`.
     */
    func finish(manual: Bool) {
        guard let draft = timer.draftSession(now: nowMs(), manual: manual) else { return }
        let wasFocus = timer.kind.isFocus

        Task { await liveActivity.end() }
        Haptics.success()
        Task { await Chime.shared.play(focus: wasFocus, enabled: settings.soundEnabled) }

        if wasFocus {
            try? repository.save(draft)

            var cycle = DeviceDefaults.pomodoroCycle
            let key = DayKey.key(for: Date())
            let count = cycle.increment(on: key)
            DeviceDefaults.pomodoroCycle = cycle
            let longBreak = cycle.isLongBreakDue(after: count, every: settings.sessionsBeforeLongBreak)

            if settings.autoStartBreak {
                // The poster floats over a break that has already begun, so no
                // time is lost deciding whether to take one.
                reflecting = draft
                start(kind: .rest, longBreak: longBreak)
            } else {
                reflecting = draft
                var next = timer
                next.abandon()
                commit(next)
            }
        } else {
            var next = timer
            next.abandon()
            commit(next)
            if settings.autoStartFocus {
                start(kind: .focus)
            }
        }

        reload()
        sync()
    }

    /// The rating, given after the fact. Re-saves the same session.
    func rate(_ session: Session, rating: Int) {
        try? repository.updateSession(id: session.id, rating: rating)
        reflecting = nil
        reload()
        sync()
    }

    func editReflecting(intention: String) {
        guard var session = reflecting else { return }
        session.intention = intention
        reflecting = session
        try? repository.updateSession(id: session.id, intention: intention)
        reload()
        sync()
    }

    func dismissPoster() {
        reflecting = nil
    }

    /// Adopt a timer that is running on another device, having been asked to.
    func takeOverRemoteTimer() {
        guard let remote = remoteTimer, remote.isRunning, remote.startedAt != nil else { return }

        let now = nowMs()
        let isPaused = remote.phase == "paused"

        /*
         The session is re-based onto this device's clock rather than adopted
         exactly as the other device recorded it.

         How long it has run comes from the server's own reckoning — its
         remaining figure against its target — because the wall time since it
         started includes any stretch the other device spent paused, and
         counting that as focus would be a lie. `startedAt` becomes whatever
         makes that much elapsed time true as of now.

         The pause has to be re-based too, and that is the part easy to get
         wrong: the server's `pausedAt` is an instant on *its* clock, so
         carrying it over would have this device subtract the whole span since
         then a second time, on top of the elapsed figure already accounting
         for it. A pause adopted now begins now.
         */
        let elapsed = max(0, remote.targetMs - remote.remainingMs(now: now))

        let next = TimerState(
            phase: isPaused ? .paused : .running,
            kind: SessionKind(rawValue: remote.sessionType),
            intention: remote.intention,
            category: remote.category,
            targetMs: remote.targetMs,
            startedAt: now - Millis(elapsed),
            pausedAt: isPaused ? now : nil,
            pausedTotalMs: 0,
            taskRefs: remote.todoistTaskId
        )

        commit(next)
        remoteTimer = nil
    }

    private func commit(_ next: TimerState, mirror: Bool = true) {
        timer = next
        try? repository.saveTimer(next, deviceId: deviceId, mirror: mirror)
        applyWakeLock()
        Task {
            await TimerNotifications.reschedule(for: next, settings: settings, now: nowMs())
            if next.isActive {
                liveActivity.update(state: next, accentHex: accentHex, now: nowMs())
            }
        }
        if mirror { sync() }
    }

    private func applyWakeLock() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && timer.phase == .running
        #endif
    }

    // ── Sessions, categories, settings ──────────────────────────────────

    func updateSession(_ session: Session, intention: String? = nil, category: String? = nil, rating: Int? = nil) {
        try? repository.updateSession(id: session.id, intention: intention, category: category, rating: rating)
        reload()
        sync()
    }

    func deleteSession(_ session: Session) {
        try? repository.deleteSession(id: session.id)
        reload()
        sync()
    }

    func saveCategory(id: String?, label: String, color: String) {
        _ = try? repository.saveCategory(id: id, label: label, color: color)
        reload()
        sync()
    }

    /// Returns the number of sessions standing behind it when the delete is
    /// refused, so the sheet can say why rather than appearing to do nothing.
    func deleteCategory(_ category: CategoryRecord) -> Int? {
        do {
            try repository.deleteCategory(id: category.id)
        } catch let refusal as SeshRepository.CategoryInUse {
            return refusal.sessionCount
        } catch {
            return nil
        }
        reload()
        sync()
        return nil
    }

    func updateSetting(_ key: AppSettings.Key, _ apply: (inout AppSettings) -> Void) {
        var updated = settings
        apply(&updated)
        settings = updated
        try? repository.setSetting(key: key.rawValue, value: updated.value(for: key))
        applyWakeLock()
        sync()
    }

    // ── Tasks ───────────────────────────────────────────────────────────

    func completeTask(_ task: ExternalTask) {
        Haptics.light()
        try? repository.completeTask(ref: task.ref.encoded)
        reload()
        sync(debounce: .seconds(1))
    }

    func createTask(title: String, when: String) {
        try? repository.createTask(title: title, when: when)
        reload()
        sync(debounce: .seconds(1))
    }

    // ── Connecting the sources ──────────────────────────────────────────

    func connectThings(email: String, password: String) async throws {
        try await client.connectThings(email: email, password: password)
    }

    func disconnectThings() async throws {
        try await client.disconnectThings()
    }

    /**
     Google Calendar, by device code.

     The web app's OAuth redirect returns to the server's own domain, which an
     app has no way to intercept — so this uses the flow Google made for exactly
     this shape of client: show a short code, let the person approve it in a
     browser, and poll until they have. The tokens land on the server, which is
     where calendar syncing happens regardless of which device asked.
     */
    func startGoogleConnect() async throws -> (userCode: String, verificationURL: URL, deviceCode: String, interval: Int) {
        let data = try await client.startGoogleDeviceFlow()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let urlString = (json["verification_url"] ?? json["verification_uri"]) as? String,
              let url = URL(string: urlString)
        else { throw APIError.decoding("Google did not return a device code") }

        return (userCode, url, deviceCode, json["interval"] as? Int ?? 5)
    }

    /// Poll until approved, or until the code expires. Returns true on success.
    func awaitGoogleApproval(deviceCode: String, interval: Int) async -> Bool {
        // Google's codes last around fifteen minutes; this gives up a little before.
        let deadline = Date().addingTimeInterval(13 * 60)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(max(2, interval)))
            guard let data = try? await client.pollGoogleDeviceFlow(deviceCode: deviceCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if json["success"] as? Bool == true {
                updateSetting(.calendarSync) { $0.calendarSync = true }
                return true
            }
            // "authorization_pending" simply means they have not finished yet.
            if let error = json["error"] as? String, error != "authorization_pending", error != "slow_down" {
                return false
            }
        }
        return false
    }

    // ── Derived ─────────────────────────────────────────────────────────

    var insights: Insights {
        Insights.compute(sessions: sessions)
    }

    var defaultCategory: CategoryRecord? {
        categories.first { $0.isDefault } ?? categories.first
    }

    func category(named name: String) -> CategoryRecord? {
        categories.first { $0.name == name }
    }

    /// Recently used first, then the stored order — the chips reorder themselves.
    var orderedCategories: [CategoryRecord] {
        let recency = DeviceDefaults.categoryRecency
        return categories.sorted { a, b in
            let indexA = recency.firstIndex(of: a.name) ?? Int.max
            let indexB = recency.firstIndex(of: b.name) ?? Int.max
            if indexA != indexB { return indexA < indexB }
            return a.sortOrder < b.sortOrder
        }
    }

    var activeColor: String {
        category(named: timer.category)?.color ?? defaultCategory?.color ?? Accent.defaultAccent
    }

    var accentHex: String {
        Accent.accent(for: activeColor, dark: settings.darkMode || timer.isActive).base
    }

    var theme: Theme {
        Theme.make(
            categoryColor: activeColor,
            dark: settings.darkMode,
            inSession: timer.isActive && reflecting == nil
        )
    }

    /// Which session of the day this is, for the eyebrow.
    var sessionNumberToday: Int {
        let key = DayKey.key(for: Date())
        let done = sessions.filter {
            $0.type.isFocus && DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == key
        }
        return done.count + 1
    }

    /// This device's own id, so a mirrored timer can be told from someone else's.
    var deviceIdentity: String { deviceId }

    func nowMs() -> Millis { Millis(Date().timeIntervalSince1970 * 1000) }
}
