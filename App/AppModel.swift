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
    private(set) var timerConflict: TimerState?
    private(set) var recoveredTimer: TimerState?
    private(set) var recoveredTimers: [TimerState] = []

    var sharedTimerStatus: String? {
        guard authState == .signedIn else { return nil }
        if timerConflict != nil { return "Another device changed the session" }
        if syncStatus.pending > 0 { return "Waiting to sync" }
        if syncStatus.lastError != nil { return "Offline · showing last synced session" }
        return timer.isActive ? "Shared session" : nil
    }

    var authState: AuthState = .unknown

    /**
     Whether this phone is meant to be signed in at all — see
     `DeviceDefaults.expectsSignIn`. Mirrored here so the screens can observe
     it; `UserDefaults` on its own would go stale until something else redrew.

     Signing in is an extra this app can do, not a step on the way in, so
     everything reads `authState == .signedOut && expectsSignIn` before saying
     a word about it.
     */
    private(set) var expectsSignIn = DeviceDefaults.expectsSignIn

    private(set) var syncStatus = SyncStatus()
    private(set) var taskSources: [TaskSourceState] = []

    /// The finished session awaiting a rating; the poster is up while this is set.
    var reflecting: Session? { timer.reflection }
    private(set) var reflectionError: String?
    private(set) var savingReflection = false
    var selectedTab: Tab = .focus
    var banner: String?
    private(set) var controlError: String?

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
    private let liveActivity: LiveActivityController
    private let watchBridge = PhoneWatchBridge()

    private var deviceId: String = ""
    private var syncTask: Task<Void, Never>?
    private var pendingSync: Task<Void, Never>?
    private var unpersistedTimer: TimerState?
    private var lastTaskRefresh: Date?

    init(database: AppDatabase, serverURL: URL, liveActivity: LiveActivityController? = nil) {
        let tokens = TokenStore()
        let repository = SeshRepository(database: database)
        let store = DatabaseSyncStore(database: database)
        let client = APIClient(baseURL: serverURL, tokens: tokens)

        self.liveActivity = liveActivity ?? LiveActivityController()
        self.tokens = tokens
        self.repository = repository
        self.store = store
        self.client = client
        self.engine = SyncEngine(store: store, transport: client)
        // WatchConnectivity may wake iOS in the background before any view task.
        // Install its delegate at app initialization, with durable identity/state.
        self.deviceId = (try? repository.deviceId()) ?? UUID().uuidString
        self.timer = (try? repository.loadTimer()) ?? .idle
        self.settings = (try? repository.settings()) ?? .defaults
        watchBridge.activate(model: self)
    }

    func start() async {
        deviceId = (try? store.deviceId()) ?? UUID().uuidString
        let signedIn = await tokens.isSignedIn
        authState = signedIn ? .signedIn : .signedOut
        expectsSignIn = DeviceDefaults.expectsSignIn
        reload()
        restoreTimer()
        if authState == .signedIn { sync() }
        setForeground(true)
    }

    /// Re-read everything the screens show. Cheap: it is a local database.
    func reload() {
        sessions = (try? repository.sessions()) ?? []
        categories = (try? repository.categories()) ?? []
        settings = (try? repository.settings()) ?? .defaults
        tasks = (try? repository.cachedTasks()) ?? []
        remoteTimer = try? repository.remoteTimer()
        timerConflict = try? repository.timerConflict()
        recoveredTimer = try? repository.recoveredTimer()
        recoveredTimers = (try? repository.recoveredTimers()) ?? []
        let previous = timer
        if unpersistedTimer == nil { timer = (try? repository.loadTimer()) ?? timer }
        if previous != timer {
            applyWakeLock()
            let current = timer
            Task {
                if (try? repository.watchSnapshot().alertsOnWatch) == true { await TimerNotifications.cancelAll() }
                else { await TimerNotifications.reschedule(for: current, settings: settings, now: nowMs()) }
            }
        }
        syncStatus.pending = (try? repository.pendingCount()) ?? 0
        if let state = try? repository.syncState() {
            syncStatus.lastSyncedAt = state.lastPullAt
            syncStatus.lastError = state.lastError
        }
        taskSources = loadTaskSources()
        watchBridge.publish()
        refreshLiveActivity()
    }

    private func refreshLiveActivity() {
        // Detached reflection edits never replace the canonical sitting here.
        let canonical = (try? repository.loadTimer()) ?? timer
        liveActivity.reconcile(state: canonical, accentHex: accentHex, now: nowMs())
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
            // From here on, being signed out is worth mentioning.
            DeviceDefaults.expectsSignIn = true
            expectsSignIn = true
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

    /**
     Sign out on purpose, which returns this phone to being a standalone app.

     The expectation goes with it: leaving deliberately is not the same as a
     session lapsing underneath you, and only the second is worth a banner.
     Nothing local is touched — the sessions were never the server's.
     */
    func signOut() async {
        await tokens.clear()
        authState = .signedOut
        DeviceDefaults.expectsSignIn = false
        expectsSignIn = false
    }

    // ── Sync ────────────────────────────────────────────────────────────

    /// Ask for a sync. Coalesced: several calls in a row make one run.
    func sync(debounce: Duration = .seconds(2)) {
        guard authState != .signedOut else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow(refreshExternalTasks: Bool = true) async {
        if authState == .unknown { authState = await tokens.isSignedIn ? .signedIn : .signedOut }
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

        reload()
        if refreshExternalTasks && (lastTaskRefresh.map { Date().timeIntervalSince($0) >= 60 } ?? true) {
            lastTaskRefresh = Date()
            await refreshTasks()
            reload()
        }
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
                if (try? repository.watchSnapshot().alertsOnWatch) == true { await TimerNotifications.cancelAll() }
                else { await TimerNotifications.reschedule(for: timer, settings: settings, now: nowMs()) }
            }
        }
        applyWakeLock()
        refreshLiveActivity()
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
        guard commit(next) else { return }
        DeviceDefaults.markCategoryUsed(next.category)
        Haptics.medium()
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
        guard commit(next) else { return }
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
        guard timer.isActive, reflecting == nil else { return }
        if !timer.kind.isFocus {
            abandon()
            if settings.autoStartFocus { start(kind: .focus) }
            return
        }

        var next = timer
        let count = sessions.filter {
            $0.type.isFocus && DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == DayKey.key(for: Date())
        }.count + 1
        let longBreak = count % max(1, settings.sessionsBeforeLongBreak) == 0
        let breakTarget = settings.autoStartBreak
            ? settings.duration(for: .rest, longBreak: longBreak) * 60_000 : nil
        next.beginReflection(now: nowMs(), manual: manual, breakTargetMs: breakTarget)
        guard next.reflection != nil else { return }
        reflectionError = nil
        let frozen = next
        do {
            // Starting a break must not complete the draft: task credit uses the
            // final links chosen on the reflection screen, at Save time only.
            try repository.saveTimer(next, deviceId: deviceId)
            unpersistedTimer = nil
            timer = next
            applyWakeLock()
            reload()
            sync()
            Task {
                await TimerNotifications.reschedule(for: next, settings: settings, now: nowMs())
                await Chime.shared.play(focus: true, enabled: settings.soundEnabled)
            }
            Haptics.success()
        } catch {
            // Keep the freeze and draft visible so a storage error cannot eat notes.
            timer = frozen
            unpersistedTimer = frozen
            reflectionError = "Could not save on this phone. Your reflection is still here — try Save again."
        }
    }

    func editReflection(intention: String? = nil, notes: String? = nil, rating: Int? = nil,
                        taskRefs: [String]? = nil) {
        guard var draft = reflecting else { return }
        if let intention { draft.intention = intention }
        if let notes { draft.notes = notes }
        if let rating { draft.rating = max(0, min(5, rating)) }
        if let taskRefs {
            draft.todoistTaskId = TaskRef.encodeList(taskRefs)
            let linked = tasks.filter { taskRefs.contains($0.ref.encoded) }
            if !linked.isEmpty {
                draft.intention = linked.map(\.content).joined(separator: " · ")
                if let category = linked.first?.category,
                   let match = categories.first(where: { $0.name == category || $0.label.caseInsensitiveCompare(category) == .orderedSame }) {
                    draft.category = match.name
                }
            }
        }
        var next = timer
        next.reflection = draft
        timer = next
        if unpersistedTimer != nil {
            // Keep a failed draft detached: editing a character must not
            // replace a newer shared sitting now persisted by sync.
            unpersistedTimer = next
            reflectionError = "This reflection is waiting to save. Tap Save to retry."
            return
        }
        do {
            _ = try repository.editReflection(draft)
            unpersistedTimer = nil
            reflectionError = nil
            reload()
        } catch {
            unpersistedTimer = next
            reflectionError = "Could not keep this edit on disk. Your notes are still here — retry Save."
        }
    }

    /// A synchronous transaction guards rapid taps; sync retries use the same session ID.
    @discardableResult
    func saveReflection() -> Bool {
        guard let draft = reflecting, !savingReflection else { return false }
        savingReflection = true
        defer { savingReflection = false }
        if unpersistedTimer != nil {
            do {
                // A failed disk write may outlive a newer Mac session. Save the
                // retained journal work against the current canonical timer in
                // one transaction, keeping that newer timer intact.
                _ = try repository.saveDetachedReflection(draft, deviceId: deviceId)
                unpersistedTimer = nil; reflectionError = nil
                reload(); sync()
                return true
            } catch {
                reflectionError = "Could not save on this phone. Your notes are still here — try again."
                return false
            }
        }
        var next = timer
        next.reflection = nil
        if next.phase == .reflect || next.startedAt == draft.startedAt { next.abandon() }
        do {
            // If a draft edit could not persist, save it first; finalization still
            // checks the durable ID before committing history and clearing the timer.
            guard try repository.save(draft, replacingTimer: next, deviceId: deviceId, requiringReflection: true) else { return false }
            unpersistedTimer = nil
            reflectionError = nil
            reload()
            sync()
            return true
        } catch {
            unpersistedTimer = timer
            reflectionError = "Could not save on this phone. Your notes are still here — try again."
            return false
        }
    }

    func returnToPausedSession() {
        guard unpersistedTimer == nil else {
            reflectionError = "Save this reflection before returning to a session."
            return
        }
        guard timer.phase == .reflect else { return }
        var next = timer
        next.returnFromReflection()
        do {
            try repository.saveTimer(next, deviceId: deviceId)
            timer = next
            unpersistedTimer = nil
            reflectionError = nil
            applyWakeLock()
            refreshLiveActivity()
            watchBridge.publish()
            sync()
        } catch {
            reflectionError = "Could not return to the session. Your reflection is still here."
        }
    }

    func saveRecoveredWork(_ local: TimerState) -> String? {
        guard let draft = local.reflection else { return "This copy has no completed work to save. You can export it." }
        do {
            try repository.saveRecoveredSession(draft)
            reload(); sync()
            return nil
        } catch { return "Could not save recovered work. Its copy remains on this phone." }
    }

    /// Acknowledging a conflict keeps the canonical timer and the saved recovery.
    func resolveTimerConflict() {
        try? repository.resolveTimerConflict()
        reload()
    }

    /// Foreground polling makes changes on an open Mac visible without interaction.
    /// Background synchronization remains best-effort, scheduled by SeshApp.
    func setForeground(_ active: Bool) {
        syncTask?.cancel(); syncTask = nil
        guard active else { return }
        refreshLiveActivity()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow(refreshExternalTasks: false)
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    @discardableResult
    private func commit(_ requested: TimerState, mirror: Bool = true) -> Bool {
        var next = requested
        next.controlSessionStart = timer.startedAt
        do { try repository.saveTimer(next, deviceId: deviceId, mirror: mirror) }
        catch {
            controlError = "Could not save that action. Your previous session is unchanged."
            return false
        }
        timer = next
        controlError = nil
        applyWakeLock()
        refreshLiveActivity()
        watchBridge.publish()
        Task {
            await TimerNotifications.reschedule(for: next, settings: settings, now: nowMs())
        }
        if mirror { sync() }
        watchBridge.publish()
        return true
    }

    func refreshWatch() { watchBridge.publish() }

    func watchStateDidChange(_ snapshot: WatchSnapshot) {
        if unpersistedTimer == nil {
            timer = snapshot.timer
            reflectionError = nil
        }
        reload()
        applyWakeLock()
        sync()
        Task {
            if snapshot.alertsOnWatch { await TimerNotifications.cancelAll() }
            else { await TimerNotifications.reschedule(for: snapshot.timer, settings: settings, now: nowMs()) }
        }
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

    /// Returns why it was refused, so the sheet can say so rather than
    /// appearing to ignore what was typed.
    @discardableResult
    func saveCategory(id: String?, label: String, color: String) -> String? {
        do {
            _ = try repository.saveCategory(id: id, label: label, color: color)
        } catch let refusal as SeshRepository.CategoryNameTaken {
            return "\(refusal.label) already uses that name."
        } catch {
            return nil
        }
        reload()
        sync()
        return nil
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
