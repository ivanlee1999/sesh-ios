import Foundation
import Security
import SeshCore

/**
 Where the session token lives.

 The keychain rather than `UserDefaults`, because this token is the whole
 account: anything holding it can read every session and write to the connected
 Things and Todoist accounts. `afterFirstUnlock` so a sync triggered in the
 background — the app refreshing while the phone is in a pocket — can still
 reach it, which `whenUnlocked` would prevent.

 The password is never stored. Sign-in exchanges it for a token immediately, and
 the token is swapped for a fresh one long before it expires.
 */
actor TokenStore: TokenProvider {
    private let service = "us.liyifan.sesh.token"
    private let account = "session"
    private var cached: String?
    private var expiry: Millis = 0

    init() {
        let existing = Self.read(service: service, account: account)
        cached = existing?.token
        expiry = existing?.expiresAt ?? 0
    }

    func currentToken() async -> String? { cached }

    func expiresAt() async -> Millis { expiry }

    func store(_ response: TokenResponse) async {
        cached = response.token
        expiry = response.expiresAt
        Self.write(token: response.token, expiresAt: response.expiresAt, service: service, account: account)
    }

    func clear() async {
        cached = nil
        expiry = 0
        Self.delete(service: service, account: account)
    }

    var isSignedIn: Bool { cached?.isEmpty == false }

    // ── Keychain ────────────────────────────────────────────────────────

    private struct Stored: Codable {
        let token: String
        let expiresAt: Millis
    }

    private static func read(service: String, account: String) -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func write(token: String, expiresAt: Millis, service: String, account: String) {
        guard let data = try? JSONEncoder().encode(Stored(token: token, expiresAt: expiresAt)) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/**
 The handful of preferences that are this device's business and nobody else's.

 Kept out of the synced settings on purpose, exactly as the web app keeps them
 out: which calendar view was last open, and how many sessions have been
 finished today, are facts about this phone this morning. Pushing them to every
 device would make them wrong everywhere at once.
 */
enum DeviceDefaults {
    private static let store = UserDefaults.standard

    enum Key: String {
        case serverURL = "sesh.serverURL"
        case onboarded = "sesh.onboarded"
        case calendarView = "sesh.calendarView"
        case categoryRecency = "sesh.categoryRecency"
        case pomodoroCycle = "sesh.pomodoroCycle"
    }

    static var serverURL: String {
        get { store.string(forKey: Key.serverURL.rawValue) ?? "https://sesh.liyifan.us" }
        set { store.set(newValue, forKey: Key.serverURL.rawValue) }
    }

    static var hasOnboarded: Bool {
        get { store.bool(forKey: Key.onboarded.rawValue) }
        set { store.set(newValue, forKey: Key.onboarded.rawValue) }
    }

    static var calendarView: String {
        get { store.string(forKey: Key.calendarView.rawValue) ?? "month" }
        set { store.set(newValue, forKey: Key.calendarView.rawValue) }
    }

    /// Category slugs, most recently used first — how the chips are ordered.
    static var categoryRecency: [String] {
        get { store.stringArray(forKey: Key.categoryRecency.rawValue) ?? [] }
        set { store.set(Array(newValue.prefix(12)), forKey: Key.categoryRecency.rawValue) }
    }

    static func markCategoryUsed(_ name: String) {
        guard !name.isEmpty else { return }
        categoryRecency = [name] + categoryRecency.filter { $0 != name }
    }

    static var pomodoroCycle: PomodoroCycle {
        get {
            guard let data = store.data(forKey: Key.pomodoroCycle.rawValue),
                  let cycle = try? JSONDecoder().decode(PomodoroCycle.self, from: data)
            else { return PomodoroCycle() }
            return cycle
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            store.set(data, forKey: Key.pomodoroCycle.rawValue)
        }
    }
}
