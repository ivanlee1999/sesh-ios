import Foundation
import SeshCore
import ActivityKit
import UIKit

/// One canonical sitting, shared by every ActivityKit surface. The deadline is
/// absolute, so neither polling nor Watch mirroring makes the clock drift.
struct LiveActivityPresentation: Equatable {
    let sessionStart: Millis
    let content: SeshActivityAttributes.ContentState

    init?(timer: TimerState, accentHex: String, now: Millis) {
        guard timer.isActive, let start = timer.startedAt else { return nil }
        sessionStart = start
        let remaining = Double(timer.remainingMs(now: now)) / 1000
        var title = ""
        for character in timer.intention {
            let piece = String(character)
            guard title.utf8.count + piece.utf8.count <= 512 else { break }
            title += piece
        }
        content = .init(
            endDate: Date(timeIntervalSince1970: Double(start + Millis(timer.pausedTotalMs) + Millis(timer.targetMs)) / 1000),
            pausedRemaining: timer.phase == .paused ? remaining : nil,
            title: title.isEmpty ? (timer.kind.isFocus ? "Focus" : "Break") : title,
            accentHex: accentHex.utf8.count <= 16 ? accentHex : "#E99B78", isFocus: timer.kind.isFocus)
    }

    var staleDate: Date? { content.isPaused ? nil : content.endDate }
}

struct LiveActivityRecord {
    let id: String
    let sessionStart: Millis
    let content: SeshActivityAttributes.ContentState
    let staleDate: Date?
}

@MainActor
protocol LiveActivityDriving: AnyObject {
    var isEnabled: Bool { get }
    var canStart: Bool { get }
    var records: [LiveActivityRecord] { get }
    var onDismiss: ((Millis) -> Void)? { get set }
    func request(_ presentation: LiveActivityPresentation) throws
    func update(id: String, presentation: LiveActivityPresentation) async
    func end(id: String) async
}

/// The sole owner of ActivityKit transitions. Latest desired state wins even
/// when a previous update/end is suspended. System activities survive relaunch;
/// recover and deduplicate them instead of relying on an in-memory handle.
@MainActor
final class LiveActivityController {
    private let driver: any LiveActivityDriving
    private let defaults: UserDefaults?
    private var desired: LiveActivityPresentation?
    private var generation = 0
    private var worker: Task<Void, Never>?
    private var dismissedStart: Millis?
    private(set) var lastRequestError: String?
    private static let dismissalKey = "sesh.liveActivity.dismissedSession"

    init(driver: (any LiveActivityDriving)? = nil, defaults: UserDefaults? = .standard) {
        self.driver = driver ?? SystemLiveActivityDriver()
        self.defaults = defaults
        dismissedStart = (defaults?.object(forKey: Self.dismissalKey) as? NSNumber)?.int64Value
        self.driver.onDismiss = { [weak self] start in
            self?.dismissedStart = start
            self?.defaults?.set(start, forKey: Self.dismissalKey)
        }
    }

    func reconcile(state: TimerState, accentHex: String, now: Millis) {
        let next = LiveActivityPresentation(timer: state, accentHex: accentHex, now: now)
        if next != desired { desired = next; generation += 1 }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    /// Deterministic regression-test seam; production callers never wait on UI.
    func waitUntilSettled() async { await worker?.value }

    private func drain() async {
        while true {
            let revision = generation
            let wanted = desired
            let records = driver.records
            let match = wanted.flatMap { p in records.first { $0.sessionStart == p.sessionStart } }
            for record in records where record.id != match?.id {
                await driver.end(id: record.id)
                if revision != generation { break }
            }
            if revision != generation { continue }
            if let wanted {
                if let match {
                    if match.content != wanted.content || match.staleDate != wanted.staleDate {
                        await driver.update(id: match.id, presentation: wanted)
                    }
                } else if driver.isEnabled && driver.canStart && dismissedStart != wanted.sessionStart {
                    do { try driver.request(wanted); lastRequestError = nil }
                    catch { lastRequestError = error.localizedDescription }
                }
            }
            if revision == generation {
                #if DEBUG
                recordFixtureDiagnostics()
                #endif
                worker = nil; return
            }
        }
    }

    #if DEBUG
    /// Opt-in evidence from the isolated simulator fixture only. Never emitted
    /// by Release builds or a phone using the production server.
    private func recordFixtureDiagnostics() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SESH_LIVE_ACTIVITY_QA"] == "1",
              environment["SESH_QA_SERVER_URL"] == "http://127.0.0.1:3039" else { return }
        let records: [[String: Any]] = driver.records.map {
            ["id": $0.id, "sessionStart": $0.sessionStart,
             "endMs": Int64(($0.content.endDate.timeIntervalSince1970 * 1000).rounded()),
             "pausedRemaining": $0.content.pausedRemaining.map { $0 as Any } ?? NSNull(),
             "title": $0.content.title, "hasStaleDate": $0.staleDate != nil]
        }
        let value: [String: Any] = ["records": records, "canStart": driver.canStart,
            "enabled": driver.isEnabled, "requestError": lastRequestError.map { $0 as Any } ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("live-activity-qa.json"), options: .atomic)
        }
    }
    #endif
}

@MainActor
private final class SystemLiveActivityDriver: LiveActivityDriving {
    var onDismiss: ((Millis) -> Void)?
    private var observers: [String: Task<Void, Never>] = [:]
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    // Local requests require visible foreground execution. Existing activities
    // may update/end during permitted background runtime; remote starts retry
    // on foreground. No push tokens or new capabilities are introduced.
    var canStart: Bool { UIApplication.shared.applicationState == .active }
    var records: [LiveActivityRecord] {
        Activity<SeshActivityAttributes>.activities.compactMap { activity in
            observe(activity)
            guard activity.activityState == .active || activity.activityState == .stale else { return nil }
            return .init(id: activity.id, sessionStart: Self.start(activity), content: activity.content.state, staleDate: activity.content.staleDate)
        }
    }

    func request(_ presentation: LiveActivityPresentation) throws {
        let activity = try Activity.request(
            attributes: SeshActivityAttributes(sessionStart: Date(timeIntervalSince1970: Double(presentation.sessionStart) / 1000)),
            content: ActivityContent(state: presentation.content, staleDate: presentation.staleDate), pushType: nil)
        observe(activity)
    }
    func update(id: String, presentation: LiveActivityPresentation) async {
        guard let activity = Activity<SeshActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: presentation.content, staleDate: presentation.staleDate))
    }
    func end(id: String) async {
        guard let activity = Activity<SeshActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        observers.removeValue(forKey: id)?.cancel()
    }
    private static func start(_ activity: Activity<SeshActivityAttributes>) -> Millis {
        Millis((activity.attributes.sessionStart.timeIntervalSince1970 * 1000).rounded())
    }
    private func observe(_ activity: Activity<SeshActivityAttributes>) {
        guard observers[activity.id] == nil else { return }
        observers[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .dismissed { self?.onDismiss?(Self.start(activity)) }
                if state == .dismissed || state == .ended { break }
            }
        }
    }
}
