import Foundation

/**
 Who wins when both sides changed the same thing.

 Pulled out as plain functions because these are the decisions that lose
 people's work when they are wrong, and they should be readable and testable
 without a database, a network or a clock.
 */

/// What this client currently holds for a row.
public struct LocalRowState: Equatable, Sendable {
    public let updatedAt: Millis
    /// True when this row has an edit that has not reached the server yet.
    public let dirty: Bool

    public init(updatedAt: Millis, dirty: Bool) {
        self.updatedAt = updatedAt
        self.dirty = dirty
    }
}

public enum MergeDecision: Equatable, Sendable {
    /// Take the server's copy.
    case takeRemote
    /// Keep ours: it is newer and still unsent, and it will win on the next push.
    case keepLocal
    /// Gone elsewhere; drop it here too.
    case deleteLocal
}

public enum Merge {
    /**
     The one rule, stated once.

     A clean row always takes the server's copy — there is nothing of ours to
     lose. A dirty row only survives if it is genuinely newer than what came
     back, and when it is we leave it alone rather than merging field by field:
     it is about to be pushed, and the server settles it there.

     A tombstone is not special-cased into always winning. Someone who edits a
     session on a plane, having not yet heard that it was deleted at home, has
     expressed the more recent intention, and their edit revives the row when it
     lands. Deleting it here first would throw that away before it was ever sent.
     */
    public static func decide(
        local: LocalRowState?,
        remoteUpdatedAt: Millis,
        remoteDeleted: Bool
    ) -> MergeDecision {
        guard let local else {
            // Nothing here yet. A tombstone for a row we never had is simply nothing to do.
            return remoteDeleted ? .deleteLocal : .takeRemote
        }

        if local.dirty && local.updatedAt > remoteUpdatedAt {
            return .keepLocal
        }

        return remoteDeleted ? .deleteLocal : .takeRemote
    }
}

/**
 How long to wait before trying a failed operation again.

 Doubling, with a ceiling, and never giving up: an op is the only copy of
 something the person did, so it is retried until it succeeds or the server
 refuses it outright. A queue that quietly dropped its head after a few
 failures would lose exactly the work it exists to protect.
 */
public enum Backoff {
    public static let base: Millis = 5_000
    public static let ceiling: Millis = 15 * 60 * 1_000
    /// After this many failures the op is surfaced in Settings — still queued, but no longer silent.
    public static let complainAfter = 8

    public static func nextAttempt(after attempts: Int, now: Millis) -> Millis {
        let exponent = min(attempts, 20)
        let delay = min(ceiling, base * Millis(truncating: NSDecimalNumber(decimal: pow(2, exponent))))
        return now + max(base, delay)
    }

    public static func shouldSurface(attempts: Int) -> Bool {
        attempts >= complainAfter
    }
}

/**
 What to do with an operation the server has answered.

 The distinction that matters is between "this will never work" and "try again
 later". A refusal is final and the op is dropped, because repeating it forever
 would block everything queued behind it. Anything that smells of weather —
 a 5xx, a dropped connection — is kept.
 */
public enum OpDisposition: Equatable, Sendable {
    /// Done with. Remove it from the queue.
    case drop
    /// Keep it and try again later.
    case retry
    /// Stop the whole run: we are signed out and nothing else will work either.
    case signedOut
    /// Dropped, but the client must repoint rows at another category first.
    case remap(to: RemoteCategory)

    public static func forResult(_ result: OpResult) -> OpDisposition {
        switch result.status {
        case .applied, .duplicate, .stale:
            // All three mean the server is finished with this op: it landed, it
            // had already landed, or it lost to a newer edit that the pull is
            // carrying back to us.
            return .drop
        case .rejected:
            if let category = result.category { return .remap(to: category) }
            return .drop
        }
    }
}
