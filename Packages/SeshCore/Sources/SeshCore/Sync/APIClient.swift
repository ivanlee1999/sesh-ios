import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the token lives, so the client never has to know about a keychain.
public protocol TokenProvider: Sendable {
    func currentToken() async -> String?
    func store(_ response: TokenResponse) async
    /// Called when the server stops accepting what we hold.
    func clear() async
}

/**
 The one place this app talks to sesh-web.

 Everything goes out with a bearer token rather than a cookie, because there is
 no cookie jar here and — more to the point — the task routes only ever minted
 their cookie on an HTML page visit, which a native app never makes. The server
 accepts the app session token in its place.

 Failures are sorted into the two kinds that matter to a queue: weather, which
 is worth waiting out, and refusal, which is not. `APIError.isTransient` is
 what the sync engine reads to decide whether an operation stays queued.
 */
public actor APIClient: SyncTransport {
    private let baseURL: URL
    private let session: URLSession
    private let tokens: TokenProvider
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL, tokens: TokenProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    // ── Auth ────────────────────────────────────────────────────────────

    /// Trade credentials for a token. The only call that ever sees a password.
    public func signIn(username: String, password: String) async throws -> TokenResponse {
        let response: TokenResponse = try await send(
            path: "/api/auth/token",
            method: "POST",
            body: try encoder.encode(["username": username, "password": password]),
            authenticated: false
        )
        await tokens.store(response)
        return response
    }

    /**
     Swap a valid token for a fresh one. Done well before expiry so a phone that
     syncs rarely is never caught holding a dead token with work queued behind
     it — and so the password never has to be kept on the device.
     */
    @discardableResult
    public func refreshToken() async throws -> TokenResponse {
        let response: TokenResponse = try await send(path: "/api/auth/token", method: "POST", body: nil)
        await tokens.store(response)
        return response
    }

    // ── Sync ────────────────────────────────────────────────────────────

    public func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await send(path: "/api/sync", method: "POST", body: try encoder.encode(request))
    }

    public func runTaskCommand(_ command: TaskCommand, opId: String) async throws {
        let provider = command.provider.rawValue
        let path: String
        var body: Data?

        switch command.kind {
        case .complete:
            guard let taskId = command.taskId else { throw APIError.decoding("A completion needs a task id") }
            path = "/api/\(provider)/tasks/\(escaped(taskId))/close"
        case .addDuration:
            guard let taskId = command.taskId else { throw APIError.decoding("A duration needs a task id") }
            path = "/api/\(provider)/tasks/\(escaped(taskId))/duration"
            body = try JSONSerialization.data(withJSONObject: ["add_minutes": command.minutes ?? 0])
        case .create:
            guard let title = command.title else { throw APIError.decoding("A to-do needs a title") }
            path = "/api/\(provider)/tasks?tz=\(escaped(TimeZone.current.identifier))"
            body = try JSONSerialization.data(withJSONObject: ["title": title, "when": command.when ?? "inbox"])
        }

        // The op id doubles as the idempotency key: this is what makes a retry
        // after a lost reply safe rather than a second helping of minutes.
        _ = try await sendRaw(path: path, method: "POST", body: body, idempotencyKey: opId)
    }

    public func tasksSnapshot(timeZone: TimeZone = .current) async throws -> Data {
        try await sendRaw(path: "/api/tasks/snapshot?tz=\(escaped(timeZone.identifier))", method: "GET", body: nil)
    }

    /**
     Sign in to Things Cloud.

     The credentials go to the server, not to Things directly: the account is
     shared across every device, and Things authenticates with the password on
     every single request, so it is the server that has to keep it. Nothing is
     stored on this phone.
     */
    public func connectThings(email: String, password: String) async throws {
        _ = try await sendRaw(
            path: "/api/things/config",
            method: "PUT",
            body: try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        )
    }

    public func disconnectThings() async throws {
        _ = try await sendRaw(path: "/api/things/config", method: "DELETE", body: nil)
    }

    /// Whether Things is reachable right now — its own liveness, not ours.
    public func thingsStatus() async throws -> Data {
        try await sendRaw(path: "/api/things/status", method: "GET", body: nil)
    }

    /**
     Google Calendar, through the device-code flow.

     The only one of the three that fits a phone: the OAuth redirect the web app
     uses returns to the server's own domain, which an app cannot intercept.
     This hands back a short code to type into a browser, then polls until it is
     approved. The tokens end up on the server, which is where calendar syncing
     happens anyway.
     */
    public func startGoogleDeviceFlow() async throws -> Data {
        try await sendRaw(path: "/api/auth/device", method: "POST", body: nil)
    }

    public func pollGoogleDeviceFlow(deviceCode: String) async throws -> Data {
        try await sendRaw(
            path: "/api/auth/device/poll",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["device_code": deviceCode])
        )
    }

    // ── Plumbing ────────────────────────────────────────────────────────

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func send<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool = true
    ) async throws -> T {
        let data = try await sendRaw(path: path, method: method, body: body, authenticated: authenticated)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(path): \(error)")
        }
    }

    @discardableResult
    private func sendRaw(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool = true,
        idempotencyKey: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.decoding("Bad path \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if authenticated, let token = await tokens.currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // No signal, aeroplane mode, a server that is not there. All of it
            // is weather, and the queue keeps its work.
            throw APIError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.decoding("Not an HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            // What we hold is no longer accepted. Local data stays; syncing stops
            // until somebody signs in again.
            await tokens.clear()
            throw APIError.unauthorized
        default:
            throw APIError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    /// The server's own words, when it offers any — its JSON `error`, not its HTML.
    static func errorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["error"] as? String
        else { return nil }
        return String(message.prefix(200))
    }
}
