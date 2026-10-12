import Foundation
import GRDB
import SeshCore

/**
 The phone's own database.

 Deliberately shaped like the server's, down to the column names, because the
 two are replicas of one another and every difference between them is somewhere
 a bug can hide. What it adds are the three columns the server does not need:
 `dirty`, marking a row this device has changed and not yet pushed; and the
 outbox and cursor that make catching up possible at all.

 This is the source of truth while the app is running. The server is not asked
 whether a session may be saved — it is told, eventually.
 */
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// The database in the app's Application Support directory.
    public static func onDisk(folder: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var configuration = Configuration()
        // Foreign keys are off deliberately: sessions reference a category by
        // slug, exactly as on the server, and a rename has to be free to sweep
        // them rather than be refused by a constraint.
        configuration.foreignKeysEnabled = false
        let pool = try DatabasePool(path: folder.appendingPathComponent("sesh.sqlite").path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// An empty database in memory, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.primaryKey("id", .text)
                t.column("intention", .text).notNull().defaults(to: "")
                t.column("category", .text).notNull().defaults(to: "")
                t.column("type", .text).notNull().defaults(to: "focus")
                t.column("targetMs", .integer).notNull().defaults(to: 0)
                t.column("actualMs", .integer).notNull().defaults(to: 0)
                t.column("overflowMs", .integer).notNull().defaults(to: 0)
                t.column("startedAt", .integer).notNull()
                t.column("endedAt", .integer).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("taskRefs", .text)
                t.column("updatedAt", .integer).notNull().defaults(to: 0)
                t.column("deletedAt", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "session_on_startedAt", on: "session", columns: ["startedAt"])

            try db.create(table: "category") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("label", .text).notNull().defaults(to: "")
                t.column("color", .text).notNull().defaults(to: "")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .integer).notNull().defaults(to: 0)
                t.column("deletedAt", .integer)
                t.column("dirty", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                // The value as JSON, exactly as the server stores it.
                t.column("value", .text).notNull().defaults(to: "null")
                t.column("updatedAt", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: false)
            }

            // One row. The running timer, which this device owns.
            try db.create(table: "timerRow") { t in
                t.primaryKey("id", .integer)
                t.column("state", .text).notNull()
                t.column("updatedAt", .integer).notNull().defaults(to: 0)
            }

            // What the server last said some *other* device was doing, so the
            // Focus screen can offer to take it over rather than adopt it.
            try db.create(table: "remoteTimerRow") { t in
                t.primaryKey("id", .integer)
                t.column("payload", .text)
                t.column("seenAt", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "cachedTask") { t in
                t.primaryKey("ref", .text)
                t.column("provider", .text).notNull()
                t.column("json", .text).notNull()
                // Ticked off here but not yet at the provider — hidden from the list,
                // and restored if the command is ultimately refused.
                t.column("pendingComplete", .boolean).notNull().defaults(to: false)
                // Made here and not yet real anywhere else.
                t.column("pendingCreate", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "taskSource") { t in
                t.primaryKey("provider", .text)
                t.column("fetchedAt", .integer)
                t.column("statusJSON", .text)
                t.column("error", .text)
            }

            try db.create(table: "outboxItem") { t in
                t.primaryKey("opId", .text)
                t.column("kind", .text).notNull()
                t.column("payload", .text).notNull()
                // Set for ops where only the newest matters — the timer mirror.
                t.column("coalesceKey", .text)
                t.column("createdAt", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAt", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }
            try db.create(index: "outboxItem_on_nextAttemptAt", on: "outboxItem", columns: ["nextAttemptAt"])

            try db.create(table: "syncStateRow") { t in
                t.primaryKey("id", .integer)
                t.column("deviceId", .text).notNull()
                t.column("cursor", .integer).notNull().defaults(to: 0)
                t.column("lastPullAt", .integer)
                t.column("lastError", .text)
            }

            // The singletons, created once so every later write is an update.
            try db.execute(sql: """
                INSERT OR IGNORE INTO syncStateRow (id, deviceId, cursor) VALUES (1, ?, 0)
                """, arguments: [UUID().uuidString])
            try db.execute(sql: "INSERT OR IGNORE INTO remoteTimerRow (id, payload, seenAt) VALUES (1, NULL, 0)")
        }

        /**
         The categories a phone starts with.

         Until now they only ever arrived by syncing, which was fine when
         signing in was the way in and is wrong now that it is not: with no
         server there were no categories at all, so every session was filed
         under the empty string and the app said things like "Logged to ." A
         standalone app has to come with its own.

         The slugs, labels, colours and order are the server's own seed,
         copied. That is the point — sessions are filed by slug, so a phone
         that later signs in has to already agree about what `deep` means
         rather than arrive with five categories of its own invention.

         Skipped when the table has anything in it, so an install that has
         already synced is left alone.
         */
        migrator.registerMigration("seedDefaultCategories") { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category") == 0 else { return }

            let defaults: [(String, String, String, Bool)] = [
                ("deep", "Deep Work", "#BE6E45", true),
                ("writing", "Writing", "#6E86B0", false),
                ("study", "Study", "#7E9476", false),
                ("reading", "Reading", "#C8943A", false),
                ("design", "Design", "#9B6F8C", false),
            ]

            for (order, row) in defaults.enumerated() {
                let (name, label, color, isDefault) = row
                try db.execute(
                    sql: """
                    INSERT INTO category (id, name, label, color, sortOrder, isDefault, updatedAt, deletedAt, dirty)
                    VALUES (?, ?, ?, ?, ?, ?, 0, NULL, 0)
                    """,
                    // Not dirty, and never pushed: these are this phone's
                    // starting point, not an edit anybody made. A server that
                    // has its own `deep` wins on the next pull.
                    arguments: [UUID().uuidString, name, label, color, order, isDefault]
                )
            }
        }

        migrator.registerMigration("watchCompanion") { db in
            try db.create(table: "watchRevision") { t in
                t.primaryKey("id", .integer)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("alertsOnWatch", .boolean).notNull().defaults(to: false)
                t.column("state", .text).notNull()
            }
            try db.create(table: "watchReceipt") { t in
                t.primaryKey("id", .text)
                t.column("revision", .integer).notNull()
            }
        }

        return migrator
    }
}
