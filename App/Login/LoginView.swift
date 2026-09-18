import SwiftUI
import SeshCore

/**
 The way in.

 The server address is editable because this app is one person's, pointed at
 their own server — there is no hosted sesh to assume. The password is traded
 for a token straight away and never kept; the token lives in the keychain and
 renews itself long before it expires.
 */
struct LoginView: View {
    /**
     Offered when this screen is the only thing on screen, on a fresh install.

     Without it the promise two lines further down — that sessions stay on this
     phone either way — is not keepable: signing in would be the one way past a
     screen you reach before you own a single session, so a server that is
     down, unreachable, or simply not yours yet locks you out of a timer that
     never needed it. Nil when the screen is a sheet, which can already be
     dismissed.
     */
    var onDefer: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var server = DeviceDefaults.serverURL
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 40)

                    Text("sesh").titleStyle(34)
                    Text("Sign in to the server you run.")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)

                    VStack(spacing: 14) {
                        field("Server", text: $server, field: .server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        field("Username", text: $username, field: .username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        SecureField("Password", text: $password)
                            .font(Typeface.font(16))
                            .textFieldStyle(.plain)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Hairline() }
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await signIn() } }
                    }
                    .padding(.top, 10)

                    if let error {
                        Text(error)
                            .metaStyle()
                            .foregroundStyle(theme.palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(busy ? "Signing in…" : "Sign in") {
                        Task { await signIn() }
                    }
                    .seshButton(.primary)
                    .disabled(busy || username.isEmpty || password.isEmpty)
                    .padding(.top, 6)

                    Text("Your sessions stay on this phone either way. Signing in is what lets them reach your other devices.")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let onDefer {
                        Button("Start without a server") { onDefer() }
                            .font(Typeface.font(15, .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accent)
                            .padding(.top, 2)
                    }
                }
                .padding(24)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .font(Typeface.font(16))
            .textFieldStyle(.plain)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Hairline() }
            .focused($focus, equals: field)
            .submitLabel(.next)
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        error = nil

        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed) != nil else {
            error = "That server address does not look like a URL."
            return
        }
        DeviceDefaults.serverURL = trimmed

        error = await model.signIn(username: username, password: password)
        if error == nil { password = "" }
    }
}

/**
 Three pages, once.

 The web app's third page asks you to add it to the Home Screen; this one is
 already there, so it asks for the thing this app actually needs instead — the
 permission that lets a session tell you it is over while the phone is in a
 pocket, with no network involved.
 */
struct OnboardingView: View {
    @Environment(\.theme) private var theme
    let onFinish: () -> Void

    @State private var page = 0

    private let pages = [
        ("One dial.", "Everything else gets out of the way."),
        ("Your real tasks.", "Things and Todoist, not a second to-do list."),
        ("Works with no signal.", "Alerts fire even offline. Everything syncs when you are back."),
    ]

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 4) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index <= page ? theme.accent : theme.palette.fill2)
                            .frame(height: 3)
                    }
                }
                .padding(.top, 20)

                Spacer()

                Text(pages[page].0).titleStyle(32)
                Text(pages[page].1)
                    .font(Typeface.font(17))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                HStack {
                    Button("Skip") { finish() }
                        .foregroundStyle(theme.palette.textTertiary)
                        .buttonStyle(.plain)
                    Spacer()
                    Button(page == pages.count - 1 ? "Start focusing" : "Next") {
                        if page == pages.count - 1 {
                            finish()
                        } else {
                            withAnimation(Motion.standard) { page += 1 }
                        }
                    }
                    .seshButton(.primary)
                    .fixedSize()
                }
            }
            .padding(24)
        }
    }

    private func finish() {
        Task {
            // Asked for here rather than at the first session, so the first
            // session is not interrupted by a permission sheet.
            _ = await TimerNotifications.requestAuthorization()
            DeviceDefaults.hasOnboarded = true
            onFinish()
        }
    }
}
