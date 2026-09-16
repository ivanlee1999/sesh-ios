import XCTest
@testable import SeshCore

/**
 The wire types, held against responses a real server actually sent.

 Captured from `sesh-web` with `POST /api/sync` rather than written by hand:
 a protocol test that invents its own input only proves the client agrees with
 itself. These fixtures are what came back — field for field, including the
 fields the server leaves out.
 */
final class SyncProtocolTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "json"),
            "Missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    private func decodeSync(_ name: String) throws -> SyncResponse {
        try JSONDecoder().decode(SyncResponse.self, from: fixture(name))
    }

    /// Op ids carry a capture-time suffix; match on the stem.
    private func result(_ stem: String, in response: SyncResponse) throws -> OpResult {
        try XCTUnwrap(response.results.first { $0.opId.hasPrefix("fx-\(stem)") }, "no result for \(stem)")
    }

    func testDecodesARealSyncResponse() throws {
        let response = try decodeSync("sync-response")

        XCTAssertEqual(response.results.count, 5)
        XCTAssertFalse(response.changes.sessions.isEmpty)
        XCTAssertGreaterThan(response.cursor, 0)
        XCTAssertGreaterThan(response.serverTime, 0)
    }

    func testReadsEveryOutcomeTheServerReports() throws {
        let response = try decodeSync("sync-response")

        XCTAssertEqual(try result("delete", in: response).status, .applied)

        // An edit older than the server's copy loses, and says so rather than
        // silently winning or silently vanishing.
        XCTAssertEqual(try result("stale", in: response).status, .stale)

        // Sent twice; the second time the first answer stands. This is what
        // makes a lost reply safe to retry.
        XCTAssertEqual(try result("linked", in: response).status, .duplicate)

        let unknown = try result("unknown-kind", in: response)
        XCTAssertEqual(unknown.status, .rejected)
        XCTAssertEqual(unknown.error, "Unknown op kind: nonsense.kind")

        // A slug another category already answers to. The winner comes back
        // attached, which is what lets the client repoint instead of retrying.
        let clash = try result("category-clash", in: response)
        XCTAssertEqual(clash.status, .rejected)
        XCTAssertEqual(clash.category?.name, "development")
        XCTAssertEqual(clash.category?.isDefault, true)
    }

    func testASessionSurvivesTheRoundTripIntoTheAppsOwnModel() throws {
        let response = try decodeSync("sync-response")
        let remote = try XCTUnwrap(response.changes.sessions.first { $0.todoistTaskId != nil })
        let session = remote.session

        XCTAssertEqual(session.id, remote.id)
        XCTAssertEqual(session.type, .focus)
        XCTAssertEqual(session.startedAt, remote.startedAt)
        // The comma-joined refs decode back into both providers.
        XCTAssertEqual(session.taskRefs.map(\.provider), [.things, .todoist])
    }

    func testATombstoneArrivesAsARowRatherThanAnAbsence() throws {
        // The whole point of the design: a deletion that happened while this
        // client was away reaches it as something it can act on.
        let sessions = try decodeSync("sync-response").changes.sessions

        let deleted = try XCTUnwrap(sessions.first { $0.deletedAt != nil })
        XCTAssertEqual(deleted.type, .rest)
        XCTAssertGreaterThan(try XCTUnwrap(deleted.deletedAt), 0)

        let live = try XCTUnwrap(sessions.first { $0.deletedAt == nil })
        XCTAssertGreaterThan(live.updatedAt, 0)
    }

    func testDecodesCategoriesAndSettings() throws {
        let changes = try decodeSync("sync-running-timer").changes

        let category = try XCTUnwrap(changes.categories.first)
        XCTAssertFalse(category.name.isEmpty)
        XCTAssertTrue(category.color.hasPrefix("#"))

        let setting = try XCTUnwrap(changes.settings.first)
        XCTAssertFalse(setting.key.isEmpty)
        // Settings hold mixed types; the value must survive as whatever it was.
        switch setting.value {
        case .bool, .number, .string, .null, .array, .object:
            XCTAssertTrue(true)
        }
    }

    func testRecognisesATimerRunningOnAnotherDevice() throws {
        let timer = try XCTUnwrap(decodeSync("sync-running-timer").timer)

        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.deviceId, "other-laptop")
        XCTAssertTrue(timer.belongsToAnotherDevice("this-iphone"))
        // Never mistaken for our own, which is what stops it being adopted silently.
        XCTAssertFalse(timer.belongsToAnotherDevice("other-laptop"))
    }

    func testRebuildsAnotherDevicesCountdownFromTheServersClock() throws {
        let timer = try XCTUnwrap(decodeSync("sync-running-timer").timer)
        // Two minutes after the server wrote it, two minutes less remain.
        XCTAssertEqual(timer.remainingMs(now: timer.updatedAt + 120_000), timer.remainingMs - 120_000)
    }

    func testDecodesTheTokenResponse() throws {
        let token = try JSONDecoder().decode(TokenResponse.self, from: fixture("token"))
        XCTAssertFalse(token.token.isEmpty)
        XCTAssertGreaterThan(token.expiresAt, 0)
        XCTAssertEqual(token.username, "ivan")
    }

    func testKnowsWhenToRefreshBeforeExpiry() {
        let now: Millis = 1_700_000_000_000
        let fresh = TokenResponse(token: "t", expiresAt: now + 30 * 86_400_000, username: nil, authDisabled: nil)
        let stale = TokenResponse(token: "t", expiresAt: now + 2 * 86_400_000, username: nil, authDisabled: nil)

        XCTAssertFalse(fresh.needsRefresh(now: now))
        XCTAssertTrue(stale.needsRefresh(now: now))
    }

    func testEncodesRequestsTheServerWillUnderstand() throws {
        let request = SyncRequest(
            deviceId: "iphone",
            cursor: 141,
            limit: 500,
            ops: [SyncOp(opId: "op-1", kind: .sessionComplete, payload: [
                "id": .string("manual-1700000000000"),
                "startedAt": .number(1_700_000_000_000),
                "rating": .number(5),
                "todoistTaskId": .null,
            ])]
        )

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(request)
        ) as? [String: Any]

        XCTAssertEqual(json?["deviceId"] as? String, "iphone")
        XCTAssertEqual(json?["cursor"] as? Int, 141)
        let ops = try XCTUnwrap(json?["ops"] as? [[String: Any]])
        XCTAssertEqual(ops.first?["kind"] as? String, "session.complete")
        let payload = try XCTUnwrap(ops.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, "manual-1700000000000")
        XCTAssertTrue(payload["todoistTaskId"] is NSNull)
    }

    func testTheTasksSnapshotReportsEachSourceSeparately() throws {
        // Either provider may be down or unconfigured without costing the other
        // its list, so each carries its own error.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: fixture("tasks-snapshot")) as? [String: Any]
        )
        XCTAssertNotNil(json["fetchedAt"])
        for provider in ["things", "todoist"] {
            let entry = try XCTUnwrap(json[provider] as? [String: Any], "missing \(provider)")
            XCTAssertNotNil(entry["tasks"])
        }
    }
}

final class MalformedNumberTests: XCTestCase {
    /**
     A fractional millisecond, which is how this was found: a client sent
     `Date.now()` through a float path, SQLite kept the column as a REAL because
     the value was not losslessly an integer, and from then on every client
     pulling that row got `1789517179528.8936`. A strict decoder threw away the
     entire page it arrived in — 113 other sessions included.
     */
    func testAFractionalTimestampDoesNotCostTheWholePage() throws {
        let json = """
        {"id":"manual-1","intention":"","category":"deep","type":"focus",
         "targetMs":1500000,"actualMs":1500000,"overflowMs":0,
         "startedAt":1789515379528,"endedAt":1789516879528,"notes":"","rating":5,
         "todoistTaskId":null,"updatedAt":1789517179528.8936,"deletedAt":null}
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(RemoteSession.self, from: json)
        XCTAssertEqual(session.updatedAt, 1_789_517_179_529)
        XCTAssertEqual(session.startedAt, 1_789_515_379_528)
    }

    func testAMissingOptionalFieldIsNotAFailure() throws {
        let json = """
        {"id":"manual-2","category":"deep","targetMs":0,"actualMs":0,"overflowMs":0,
         "startedAt":1,"endedAt":2,"rating":0,"updatedAt":2}
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(RemoteSession.self, from: json)
        XCTAssertEqual(session.intention, "")
        XCTAssertEqual(session.type, .focus)
        XCTAssertNil(session.deletedAt)
    }
}
