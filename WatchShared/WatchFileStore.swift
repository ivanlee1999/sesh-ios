import Foundation
import SeshCore
import Darwin

enum WatchFileStore {
    static let group = "group.us.liyifan.sesh.watch"
    static func access<T>(_ body: (inout WatchDocument) throws -> T) throws -> T {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let lock = directory.appendingPathComponent("timer.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let file = directory.appendingPathComponent("timer.json")
        var document: WatchDocument
        if FileManager.default.fileExists(atPath: file.path) {
            document = try JSONDecoder().decode(WatchDocument.self, from: Data(contentsOf: file))
        } else { document = WatchDocument() }
        let original = document
        let result = try body(&document)
        if original != document {
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
        }
        return result
    }
    static func read() throws -> WatchDocument { try access { $0 } }
}
