import XCTest
@testable import SeshCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/**
 The client against a real sesh-web, rather than against a stub of one.

 Skipped unless `SESH_TEST_SERVER` is set, because it needs a server running:

 ```sh
 cd ../sesh-web
 APP_AUTH_USERNAME=ivan APP_AUTH_PASSWORD=testpass NEXTAUTH_SECRET=test npx next dev -p 3099
 SESH_TEST_SERVER=http://127.0.0.1:3099 SESH_TEST_USER=ivan SESH_TEST_PASSWORD=testpass swift test
 ```

 Everything else in this suite proves the client agrees with itself. This is the
 only thing that proves it agrees with the server — that the token is accepted,
 that the ops are shaped the way the endpoint reads them, and that a retry after
 a lost reply really is free.
 */
final class LiveServerTests: XCTestCase {
    private var baseURL: URL!
    private var client: APIClient!
    private var tokens: MemoryTokenStore!

    actor MemoryTokenStore: TokenProvider {
        private var token: String?
        var cleared = false

        func currentToken() async -> String? { token }
        func store(_ response: TokenResponse) async { token = response.token }
        func clear() async { token = nil; cleared = true }
    }

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["SESH_TEST_SERVER"], let url = URL(string: raw) else {
            throw XCTSkip("Set SESH_TEST_SERVER to run the live-server tests")
        }
        baseURL = url
        tokens = MemoryTokenStore()
        client = APIClient(baseURL: url, tokens: tokens)
    }

    private var credentials: (user: String, password: String) {
        let env = ProcessInfo.processInfo.environment
        return (env["SESH_TEST_USER"] ?? "ivan", env["SESH_TEST_PASSWORD"] ?? "testpass")
    }

    @discardableResult
    private func signIn() async throws -> TokenResponse {
        try await client.signIn(username: credentials.user, password: credentials.password)
    }

    func testSignsInAndIsHandedAUsableToken() async throws {
        let response = try await signIn()
        XCTAssertFalse(response.token.isEmpty)
        XCTAssertGreaterThan(response.expiresAt, Millis(Date().timeIntervalSince1970 * 1000))
        XCTAssertFalse(response.needsRefresh(now: Millis(Date().timeIntervalSince1970 * 1000)))
    }

    func testTheWrongPasswordIsRefusedRatherThanTolerated() async {
        do {
            _ = try await client.signIn(username: credentials.user, password: "definitely-not-it")
            XCTFail("a bad password must not produce a token")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRefreshesWithoutSeeingThePasswordAgain() async throws {
        try await signIn()
        let refreshed = try await client.refreshToken()
        XCTAssertFalse(refreshed.token.isEmpty)
    }

    func testPullsTheWholeHistoryByPaging() async throws {
        try await signIn()

        var cursor = 0
        var ids = Set<String>()
        var pages = 0
        while pages < 30 {
            let response = try await client.sync(SyncRequest(deviceId: "swift-test", cursor: cursor, limit: 40))
            response.changes.sessions.forEach { ids.insert($0.id) }
            cursor = response.cursor
            pages += 1
            if !response.hasMore { break }
        }

        XCTAssertGreaterThan(ids.count, 0)
        XCTAssertGreaterThan(cursor, 0)
    }

    func testASessionFinishedOfflineArrivesIntactAndOnlyOnce() async throws {
        try await signIn()

        // Catch up first, so the pull below is only about what this test does.
        var cursor = 0
        while true {
            let page = try await client.sync(SyncRequest(deviceId: "swift-test", cursor: cursor, limit: 1000))
            cursor = page.cursor
            if !page.hasMore { break }
        }

        // A session the phone ran with no signal: built by the same engine the
        // app uses, not by hand.
        let startedAt = Millis(Date().timeIntervalSince1970 * 1000) - 1_800_000
        var timer = TimerState()
        timer.start(kind: .focus, intention: "Written from a Swift test", category: "development",
                    targetMs: 1_500_000, taskRefs: nil, now: startedAt)
        let drafted = try XCTUnwrap(timer.draftSession(now: startedAt + 1_500_000, manual: false))

        let opId = "swift-live-\(startedAt)"
        let op = SyncOp(opId: opId, kind: .sessionComplete, payload: [
            "id": .string(drafted.id),
            "intention": .string(drafted.intention),
            "category": .string(drafted.category),
            "type": .string(drafted.type.rawValue),
            "targetMs": .number(Double(drafted.targetMs)),
            "actualMs": .number(Double(drafted.actualMs)),
            "overflowMs": .number(Double(drafted.overflowMs)),
            "startedAt": .number(Double(drafted.startedAt)),
            "endedAt": .number(Double(drafted.endedAt)),
            "notes": .string(""),
            "rating": .number(5),
            "todoistTaskId": .null,
            "updatedAt": .number(Double(Date().timeIntervalSince1970 * 1000)),
        ])

        let first = try await client.sync(SyncRequest(deviceId: "swift-test", cursor: cursor, ops: [op]))
        XCTAssertEqual(first.results.first?.status, .applied)

        // The reply is lost and the phone tries again. This must not produce a
        // second session for the same hour.
        let second = try await client.sync(SyncRequest(deviceId: "swift-test", cursor: first.cursor, ops: [op]))
        XCTAssertEqual(second.results.first?.status, .duplicate)

        // And it comes back looking like what was sent.
        let pulled = try await client.sync(SyncRequest(deviceId: "swift-test", cursor: cursor, limit: 100))
        let landed = try XCTUnwrap(pulled.changes.sessions.first { $0.id == drafted.id })
        XCTAssertEqual(landed.intention, "Written from a Swift test")
        XCTAssertEqual(landed.actualMs, drafted.actualMs)
        XCTAssertEqual(landed.rating, 5)
        XCTAssertNil(landed.deletedAt)

        // Tidy up after ourselves: this is somebody's real history.
        let deleted = try await client.sync(SyncRequest(
            deviceId: "swift-test", cursor: pulled.cursor,
            ops: [SyncOp(opId: "\(opId)-delete", kind: .sessionDelete, payload: ["id": .string(drafted.id)])]
        ))
        XCTAssertEqual(deleted.results.first?.status, .applied)
    }

    func testTheEngineDrivesARealServer() async throws {
        try await signIn()

        let store = FakeStore()
        store.device = "swift-engine-test"
        let engine = SyncEngine(store: store, transport: client)

        let outcome = await engine.run(maxRounds: 30)

        XCTAssertFalse(outcome.signedOut)
        XCTAssertNil(outcome.lastError)
        XCTAssertGreaterThan(outcome.pagesPulled, 0)
        XCTAssertGreaterThan(store.storedCursor, 0)
        // The timer row always comes back, even when nothing is running.
        XCTAssertNotNil(store.remoteTimer)
    }

    func testAnUnauthenticatedClientIsTurnedAway() async {
        let anonymous = APIClient(baseURL: baseURL, tokens: MemoryTokenStore())
        do {
            _ = try await anonymous.sync(SyncRequest(deviceId: "swift-test", cursor: 0))
            XCTFail("the server must not serve an unauthenticated sync")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
