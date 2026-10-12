import Foundation
import GRDB
import SeshCore

extension SeshRepository {
    private func watchTimer(_ db: Database) throws -> TimerState {
        guard let row = try TimerRecord.fetchOne(db, key: 1) else { return .idle }
        return try JSONDecoder().decode(TimerState.self, from: Data(row.state.utf8))
    }

    private func revision(_ db: Database, timer: TimerState) throws -> Int64 {
        let state = String(decoding: try JSONEncoder().encode(timer), as: UTF8.self)
        // Compare decoded values, never dictionary key ordering in encoded JSON.
        if let row = try Row.fetchOne(db, sql: "SELECT revision, state FROM watchRevision WHERE id = 1") {
            let old: Int64 = row["revision"]
            let encoded: String = row["state"]
            let previous = try JSONDecoder().decode(TimerState.self, from: Data(encoded.utf8))
            if previous == timer { return old }
            try db.execute(sql: "UPDATE watchRevision SET revision = ?, state = ?, alertsOnWatch = 0 WHERE id = 1", arguments: [old + 1, state])
            return old + 1
        }
        try db.execute(sql: "INSERT INTO watchRevision (id, revision, state) VALUES (1, 1, ?)", arguments: [state])
        return 1
    }

    private func watchPreferences(_ db: Database) throws -> WatchPreferences {
        var settings = AppSettings.defaults
        for row in try SettingRecord.fetchAll(db) {
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(row.value.utf8)) {
                settings.apply(key: row.key, value: value)
            }
        }
        var prefs = WatchPreferences()
        prefs.focusMinutes = max(1, min(180, settings.focusDuration))
        prefs.breakMinutes = max(1, min(180, settings.breakDuration))
        prefs.longBreakMinutes = max(1, min(180, settings.longBreakDuration))
        prefs.autoStartBreak = settings.autoStartBreak
        prefs.autoStartFocus = settings.autoStartFocus
        prefs.soundEnabled = settings.soundEnabled
        prefs.sessionsBeforeLongBreak = settings.sessionsBeforeLongBreak
        prefs.categories = try CategoryRecord.live.fetchAll(db).map { .init(name: $0.name, label: $0.label) }
        let today = DayKey.key(for: Date(timeIntervalSince1970: Double(now()) / 1000))
        prefs.focusCount = try SessionRecord.live.fetchAll(db).filter {
            $0.session.type.isFocus && DayKey.key(for: Date(timeIntervalSince1970: Double($0.startedAt) / 1000)) == today
        }.count
        return prefs
    }

    public func watchSnapshot() throws -> WatchSnapshot {
        try writer.write { db in
            let timer = try watchTimer(db)
            var snapshot = WatchSnapshot(revision: try revision(db, timer: timer), timer: timer,
                                         preferences: try watchPreferences(db))
            snapshot.alertsOnWatch = try Bool.fetchOne(db, sql: "SELECT alertsOnWatch FROM watchRevision WHERE id = 1") ?? false
            return snapshot
        }
    }

    /// One transaction covers replay, receipts, history, timer and server outbox.
    /// A lost reply can safely replay the complete batch after either app relaunches.
    public func receiveWatch(_ batch: WatchBatch, deviceId: String) throws -> WatchSnapshot {
        guard batch.commands.count <= 1000, batch.recovered.count <= 1000 else {
            throw WatchTransitionError.invalidTransition
        }
        return try writer.write { db in
            var timer = try watchTimer(db)
            let current = try revision(db, timer: timer)
            var preferences = try watchPreferences(db)
            var accepted: [String] = []
            var receiptRevision = batch.revision
            var remaining: [WatchCommand] = []
            var seenNew = false
            for command in batch.commands {
                if let receipt = try Int64.fetchOne(db, sql: "SELECT revision FROM watchReceipt WHERE id = ?", arguments: [command.id]) {
                    accepted.append(command.id)
                    if !seenNew { receiptRevision = receipt }
                } else { seenNew = true; remaining.append(command) }
            }
            var response = WatchSnapshot(revision: current, timer: timer, preferences: preferences, accepted: accepted)
            if !remaining.isEmpty && current != receiptRevision {
                response.conflict = true
                return response
            }
            var completed: [Session] = []
            do {
                for command in remaining {
                    if let session = try WatchReducer.apply(command, timer: &timer, preferences: &preferences) {
                        completed.append(session)
                    }
                }
            } catch {
                response.conflict = true
                return response
            }
            if remaining.isEmpty && receiptRevision == current && !batch.watchCanAlert {
                // Permission may have been revoked on Watch since the handshake.
                // Relinquishing ownership restores the phone fallback.
                try db.execute(sql: "UPDATE watchRevision SET alertsOnWatch = 0 WHERE id = 1")
            }
            // Recovery is an explicit history import, independent of an active timer.
            for session in completed + batch.recovered {
                guard session.id == Session.id(startedAt: session.startedAt), session.startedAt > 0,
                      session.endedAt >= session.startedAt, (0...5).contains(session.rating) else {
                    throw WatchTransitionError.invalidTransition
                }
                if try SessionRecord.fetchOne(db, key: session.id) == nil {
                    try SessionRecord(session: session, updatedAt: now(), dirty: true).insert(db)
                    try enqueue(db, op: SyncOp(kind: .sessionComplete, payload: Self.payload(for: session, updatedAt: now(), full: true)))
                }
            }
            var nextRevision = current
            if !remaining.isEmpty {
                let encoded = String(decoding: try JSONEncoder().encode(timer), as: UTF8.self)
                try TimerRecord(id: 1, state: encoded, updatedAt: now()).save(db)
                // Even an idle -> start -> save -> idle batch advances the epoch.
                nextRevision = current + 1
                try db.execute(sql: "UPDATE watchRevision SET revision = ?, state = ?, alertsOnWatch = ? WHERE id = 1", arguments: [nextRevision, encoded, batch.watchCanAlert])
                try enqueue(db, op: SyncOp(kind: .timerMirror, payload: timer.mirrorPayload(now: now(), deviceId: deviceId)), coalesceKey: "timer")
                for command in remaining {
                    try db.execute(sql: "INSERT INTO watchReceipt (id, revision) VALUES (?, ?)", arguments: [command.id, nextRevision])
                    accepted.append(command.id)
                }
            }
            response = WatchSnapshot(revision: nextRevision, timer: timer,
                                     preferences: try watchPreferences(db), accepted: accepted)
            response.alertsOnWatch = try Bool.fetchOne(db, sql: "SELECT alertsOnWatch FROM watchRevision WHERE id = 1") ?? false
            response.recoveredIDs = batch.recovered.map(\.id)
            return response
        }
    }
}
