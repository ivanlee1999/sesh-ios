import XCTest
import Foundation
import UIKit
import WatchConnectivity
import SeshCore
import SeshStore
@testable import sesh

/// Opt-in, isolated simulator harness. Ordinary test runs never contact a server.
/// The operator drives the local web fixture and reads this host's Documents
/// evidence while its real AppModel/WatchConnectivity delegate remains alive.
@MainActor
final class SharedServerWatchTests: XCTestCase {
    private struct Sample: Codable {
        var observedAt: Millis
        var deviceId: String
        var timer: TimerState
        var remainingMs: Int
        var targetAt: Millis?
        var pending: Int
        var sharedStatus: String?
        var server: RemoteTimer?
        var serverReadError: String?
        var syncError: String?
        var watchSnapshot: WatchSnapshot?
        var outgoingWatchContext: WatchSnapshot?
        var watchActivation: Int
        var watchPaired: Bool
        var watchInstalled: Bool
        var watchReachable: Bool
        var command: String?
    }

    private struct Evidence: Codable {
        var serverURL = "http://127.0.0.1:3039"
        var status = "starting"
        var initialCanonicalVerified = false
        var initialDeadlineDifferenceMs: Millis?
        var lastUpdatedAt: Millis = 0
        var samples: [Sample] = []
    }

    private func now() -> Millis { Millis(Date().timeIntervalSince1970 * 1000) }

    private func readFixtureTimer() async throws -> RemoteTimer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:3039/api/timer")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "SharedE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local fixture timer GET failed"])
        }
        return try JSONDecoder().decode(RemoteTimer.self, from: data)
    }

    private func write(_ evidence: Evidence, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: url, options: .atomic)
    }

    private func sample(_ model: AppModel, command: String? = nil) async -> Sample {
        let observedAt = now()
        var remote: RemoteTimer?
        var readError: String?
        do { remote = try await readFixtureTimer() }
        catch { readError = String(describing: error) }
        let outgoing = (WCSession.default.applicationContext["snapshot"] as? Data)
            .flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
        return Sample(observedAt: observedAt, deviceId: model.deviceIdentity,
            timer: model.timer, remainingMs: model.timer.remainingMs(now: observedAt),
            targetAt: model.timer.targetDate(now: observedAt).map { Millis($0.timeIntervalSince1970 * 1000) },
            pending: (try? model.repository.pendingCount()) ?? -1,
            sharedStatus: model.sharedTimerStatus, server: remote, serverReadError: readError,
            syncError: model.syncStatus.lastError,
            watchSnapshot: try? model.repository.watchSnapshot(), outgoingWatchContext: outgoing,
            watchActivation: Int(WCSession.default.activationState.rawValue),
            watchPaired: WCSession.default.isPaired, watchInstalled: WCSession.default.isWatchAppInstalled,
            watchReachable: WCSession.default.isReachable, command: command)
    }

    func testLocalWebServerPhoneAndWatchHarness() async throws {
        guard ProcessInfo.processInfo.environment["SESH_SHARED_E2E"] == "1" else {
            throw XCTSkip("Set SESH_SHARED_E2E=1 only for the isolated local fixture/paired simulator run.")
        }
        // The host application's own model must also stay on the fixture;
        // never let its default account URL participate in this test run.
        guard ProcessInfo.processInfo.environment["SESH_QA_SERVER_URL"] == "http://127.0.0.1:3039" else {
            XCTFail("The test host must use the isolated SESH_QA_SERVER_URL.")
            return
        }
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let output = documents.appendingPathComponent("shared-e2e.json")
        let commandFile = documents.appendingPathComponent("shared-e2e-command")
        let finishFile = documents.appendingPathComponent("shared-e2e-finish")
        // Clear only this harness's stale control files, never app/user data.
        try? FileManager.default.removeItem(at: commandFile)
        try? FileManager.default.removeItem(at: finishFile)
        let folder = documents.appendingPathComponent("shared-e2e-database-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.onDisk(folder: folder)
        let model = AppModel(database: database, serverURL: URL(string: "http://127.0.0.1:3039")!)
        var evidence = Evidence()
        try write(evidence, to: output)
        let signInError = await model.signIn(username: "fixture", password: "fixture")
        XCTAssertNil(signInError)
        guard signInError == nil else {
            evidence.status = "sign-in-failed"
            evidence.samples.append(await sample(model))
            try write(evidence, to: output)
            return
        }
        await model.start()
        model.setForeground(true)
        defer { model.setForeground(false) }

        // A web-created running fixture is required. The harness never creates,
        // takes over, finishes, or resets a server session to prepare itself.
        let initialTimeout = Date().addingTimeInterval(60)
        var initial: Sample?
        while Date() < initialTimeout {
            let current = await sample(model)
            evidence.samples.append(current)
            evidence.lastUpdatedAt = now()
            if let server = current.server, server.phase == "running", server.startedAt != nil,
               model.timer.phase == .running, model.timer.startedAt == server.startedAt {
                initial = current
                break
            }
            evidence.status = "waiting-for-web-session"
            try write(evidence, to: output)
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let initial, let server = initial.server else {
            evidence.status = "initial-adoption-failed"
            try write(evidence, to: output)
            XCTFail("The phone did not automatically adopt the running local web fixture within 60 seconds.")
            return
        }
        let phoneDeadline = try XCTUnwrap(initial.targetAt)
        let serverDeadline = server.updatedAt + Millis(server.remainingMs)
        evidence.initialDeadlineDifferenceMs = phoneDeadline - serverDeadline
        evidence.initialCanonicalVerified = model.timer.startedAt == server.startedAt
            && abs(phoneDeadline - serverDeadline) <= 250
            && model.timer.intention == server.intention
        XCTAssertEqual(model.timer.startedAt, server.startedAt)
        XCTAssertEqual(model.timer.intention, server.intention)
        XCTAssertLessThanOrEqual(abs(phoneDeadline - serverDeadline), 250)
        evidence.status = "observing"
        evidence.lastUpdatedAt = now()
        try write(evidence, to: output)

        let timeout = Date().addingTimeInterval(180)
        var lastSampleAt = Date.distantPast
        while Date() < timeout {
            if FileManager.default.fileExists(atPath: finishFile.path) { break }
            var processed: String?
            if let data = try? Data(contentsOf: commandFile),
               let text = String(data: data, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: commandFile)
                switch command {
                case "pause": model.pause()
                case "resume": model.resume()
                case "sync": await model.syncNow(refreshExternalTasks: false)
                case "refreshWatch": model.refreshWatch()
                default:
                    XCTFail("Unsupported isolated fixture command: \(command)")
                }
                processed = command
            }
            if processed != nil || Date().timeIntervalSince(lastSampleAt) >= 1 {
                evidence.samples.append(await sample(model, command: processed))
                evidence.lastUpdatedAt = now()
                try write(evidence, to: output)
                lastSampleAt = Date()
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        evidence.samples.append(await sample(model))
        evidence.status = FileManager.default.fileExists(atPath: finishFile.path) ? "finished-by-fixture-operator" : "observation-window-complete"
        evidence.lastUpdatedAt = now()
        try write(evidence, to: output)
    }
}
