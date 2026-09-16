import Foundation

// ── What the engine needs from the world ────────────────────────────────

public enum APIError: Error, Equatable, Sendable {
    case unauthorized
    case offline
    case server(status: Int, message: String?)
    case decoding(String)

    /// Weather, rather than a refusal: worth trying again unchanged.
    public var isTransient: Bool {
        switch self {
        case .offline: return true
        case .server(let status, _): return status >= 500 || status == 429
        case .unauthorized, .decoding: return false
        }
    }
}

/// One queued command against an external task provider.
public struct TaskCommand: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case complete
        case addDuration
        case create
    }

    public let kind: Kind
    public let provider: TaskProvider
    /// Absent when creating — the task does not exist yet.
    public let taskId: String?
    public let minutes: Int?
    public let title: String?
    public let when: String?

    public init(
        kind: Kind, provider: TaskProvider, taskId: String? = nil,
        minutes: Int? = nil, title: String? = nil, when: String? = nil
    ) {
        self.kind = kind
        self.provider = provider
        self.taskId = taskId
        self.minutes = minutes
        self.title = title
        self.when = when
    }
}

public protocol SyncTransport: Sendable {
    func sync(_ request: SyncRequest) async throws -> SyncResponse
    /**
     `opId` is sent as the idempotency key, which is what makes a retry after a
     lost reply safe: without it, a repeated "add 25 minutes" adds fifty.
     */
    func runTaskCommand(_ command: TaskCommand, opId: String) async throws
}

/// One record in the outbox: something done here that the server has not heard about.
public struct OutboxRecord: Equatable, Sendable {
    public let opId: String
    public let op: OutboxPayload
    public let attempts: Int
    public let createdAt: Millis

    public init(opId: String, op: OutboxPayload, attempts: Int = 0, createdAt: Millis = 0) {
        self.opId = opId
        self.op = op
        self.attempts = attempts
        self.createdAt = createdAt
    }
}

public enum OutboxPayload: Equatable, Sendable {
    /// Replicated state, pushed through `/api/sync`.
    case data(SyncOp)
    /// A command to Todoist or Things, which is not state and cannot go in a batch.
    case task(TaskCommand)
}

/**
 Everything the engine needs to keep. Deliberately a protocol: the engine's
 decisions are worth testing without a database, and the database is worth
 changing without touching them.
 */
public protocol SyncStore: AnyObject, Sendable {
    func deviceId() throws -> String
    func cursor() throws -> Int
    func setCursor(_ cursor: Int) throws

    /// Ops whose next attempt is due, oldest first.
    func dueOps(now: Millis, limit: Int) throws -> [OutboxRecord]
    func removeOp(_ opId: String) throws
    func deferOp(_ opId: String, attempts: Int, nextAttemptAt: Millis, error: String?) throws

    /// Apply one page of server changes, honouring `Merge.decide` per row.
    func apply(_ changes: SyncChanges) throws
    /// Repoint local rows and queued ops from one category slug to another.
    func remapCategory(from oldSlug: String, to newSlug: String) throws
    /// Remember what the server says the timer is doing, for the take-over banner.
    func setRemoteTimer(_ timer: RemoteTimer?) throws
}

// ── The engine ──────────────────────────────────────────────────────────

public struct SyncOutcome: Equatable, Sendable {
    public var pushed = 0
    public var dropped = 0
    public var deferred = 0
    public var pagesPulled = 0
    public var signedOut = false
    public var lastError: String?
}

/**
 The conversation with the server, run to completion or abandoned cleanly.

 An actor because everything here is a read-modify-write against one queue and
 one cursor: two of these running at once would push the same op twice and
 advance the cursor past a page nobody applied.

 The shape is deliberately boring. Push what we did, apply what came back,
 advance the cursor, repeat while there is more. The interesting decisions all
 live in `MergePolicy`, where they can be read.
 */
public actor SyncEngine {
    private let store: SyncStore
    private let transport: SyncTransport
    private let clock: @Sendable () -> Millis
    private let opsPerRequest: Int

    public init(
        store: SyncStore,
        transport: SyncTransport,
        opsPerRequest: Int = 100,
        clock: @escaping @Sendable () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.transport = transport
        self.opsPerRequest = opsPerRequest
        self.clock = clock
    }

    @discardableResult
    public func run(maxRounds: Int = 20) async -> SyncOutcome {
        var outcome = SyncOutcome()

        do {
            let deviceId = try store.deviceId()

            for _ in 0..<maxRounds {
                let due = try store.dueOps(now: clock(), limit: opsPerRequest)
                let dataOps = due.compactMap { record -> (String, SyncOp)? in
                    if case .data(let op) = record.op { return (record.opId, op) }
                    return nil
                }

                let response = try await transport.sync(SyncRequest(
                    deviceId: deviceId,
                    cursor: try store.cursor(),
                    ops: dataOps.map(\.1)
                ))

                try handle(
                    results: response.results,
                    sent: Dictionary(dataOps, uniquingKeysWith: { first, _ in first }),
                    outcome: &outcome
                )
                try store.apply(response.changes)
                try store.setCursor(response.cursor)
                try store.setRemoteTimer(response.timer)
                outcome.pagesPulled += 1

                // Task commands go one at a time to their own endpoints; they are
                // commands to other people's servers, not rows to replicate.
                let stop = try await runTaskCommands(due, outcome: &outcome)
                if stop { return outcome }

                let moreQueued = try !store.dueOps(now: clock(), limit: 1).isEmpty
                if !response.hasMore && !moreQueued { break }
            }
        } catch let error as APIError {
            if error == .unauthorized {
                outcome.signedOut = true
            }
            outcome.lastError = String(describing: error)
        } catch {
            outcome.lastError = error.localizedDescription
        }

        return outcome
    }

    private func handle(
        results: [OpResult],
        sent: [String: SyncOp],
        outcome: inout SyncOutcome
    ) throws {
        for result in results {
            switch OpDisposition.forResult(result) {
            case .drop:
                try store.removeOp(result.opId)
                outcome.pushed += 1
            case .remap(let category):
                /*
                 The slug this op named is taken, or gone. The server says which
                 category won; what it cannot say is which slug we asked for, so
                 that is read back off the op we sent. Everything pointing at the
                 old slug — rows and the ops still queued behind this one — is
                 repointed before the op is dropped, or the next one would be
                 refused for exactly the same reason.
                 */
                if let asked = Self.categorySlug(of: sent[result.opId]), asked != category.name {
                    try store.remapCategory(from: asked, to: category.name)
                }
                try store.removeOp(result.opId)
                outcome.dropped += 1
            case .retry:
                outcome.deferred += 1
            case .signedOut:
                outcome.signedOut = true
            }
        }
    }

    /// The category slug an op named, wherever it keeps it.
    static func categorySlug(of op: SyncOp?) -> String? {
        guard let op else { return nil }
        switch op.kind {
        case .categoryUpsert, .categoryDelete:
            return op.payload["name"]?.stringValue
        default:
            return op.payload["category"]?.stringValue
        }
    }

    /// Returns true when the run should stop entirely.
    private func runTaskCommands(_ due: [OutboxRecord], outcome: inout SyncOutcome) async throws -> Bool {
        for record in due {
            guard case .task(let command) = record.op else { continue }
            do {
                try await transport.runTaskCommand(command, opId: record.opId)
                try store.removeOp(record.opId)
                outcome.pushed += 1
            } catch let error as APIError {
                if error == .unauthorized {
                    outcome.signedOut = true
                    outcome.lastError = String(describing: error)
                    return true
                }
                if error.isTransient {
                    // Keep it, and stop: the network is against us and the rest
                    // of the queue would only fail the same way.
                    try store.deferOp(
                        record.opId,
                        attempts: record.attempts + 1,
                        nextAttemptAt: Backoff.nextAttempt(after: record.attempts + 1, now: clock()),
                        error: String(describing: error)
                    )
                    outcome.deferred += 1
                    outcome.lastError = String(describing: error)
                    return true
                }
                // A refusal will not improve with age.
                try store.removeOp(record.opId)
                outcome.dropped += 1
                outcome.lastError = String(describing: error)
            }
        }
        return false
    }
}
