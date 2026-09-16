import Foundation

public enum TaskProvider: String, Codable, Sendable, CaseIterable {
    case todoist
    case things
}

/**
 A reference to a task in somebody else's app.

 The encoding is inherited and must be matched exactly: a Todoist id is bare,
 anything else is namespaced (`things:UUID`), and a session pointing at several
 tasks joins them with commas into the one legacy `todoist_task_id` column.
 Neither a Todoist id nor a Things uuid contains a comma, and a list of one
 encodes to exactly the bare ref it always was — which is why every existing
 row keeps working untouched.
 */
public struct TaskRef: Equatable, Hashable, Sendable {
    public let provider: TaskProvider
    public let id: String

    public init(provider: TaskProvider, id: String) {
        self.provider = provider
        self.id = id
    }

    public var encoded: String {
        provider == .todoist ? id : "\(provider.rawValue):\(id)"
    }

    public static func decode(_ ref: String?) -> TaskRef? {
        guard let ref, !ref.isEmpty else { return nil }
        if let separator = ref.firstIndex(of: ":"), separator != ref.startIndex {
            let prefix = String(ref[ref.startIndex..<separator])
            // Only a prefix we recognise counts as a provider — a Todoist id
            // containing a colon must not be mistaken for a namespaced ref.
            if let provider = TaskProvider(rawValue: prefix) {
                return TaskRef(provider: provider, id: String(ref[ref.index(after: separator)...]))
            }
        }
        return TaskRef(provider: .todoist, id: ref)
    }

    public static func split(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func decodeList(_ value: String?) -> [TaskRef] {
        split(value).compactMap { decode($0) }
    }

    public static func encodeList(_ refs: [String]) -> String? {
        let cleaned = refs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
    }
}
