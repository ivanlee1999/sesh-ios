import SwiftUI
import SeshCore

/**
 The shell.

 The tab bar disappears while a session runs — the running screen is full-bleed
 and there is nowhere else to be — which is the one structural idea carried over
 wholesale from the web app.

 Note what is *not* gated on signing in: everything. The database is local, so
 the timer, the history and the insights all work signed out; only syncing
 stops. Being signed out is a sync problem, not a reason to lock someone out of
 their own morning.
 */
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasOnboarded = DeviceDefaults.hasOnboarded
    @State private var showingSignIn = false

    var body: some View {
        let theme = model.theme

        ZStack {
            if !hasOnboarded {
                OnboardingView { hasOnboarded = true }
            } else {
                // Straight in. There is no signed-out screen because there is
                // no signed-in one either: this is a standalone app that can
                // also talk to a server, and the timer, the history and the
                // insights are all local. Signing in is offered in Settings,
                // for the one thing it buys — the same sessions on a laptop.
                shell
            }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .tint(theme.accent)
        .animation(Motion.standard, value: model.timer.isActive)
        .sheet(isPresented: $showingSignIn) { LoginView().environment(model) }
        .onChange(of: scenePhase) { _, phase in
            // Coming back is the moment most likely to have something to send,
            // and the moment the timer needs re-reading from the clock.
            if phase == .active {
                model.reload()
                model.sync(debounce: .seconds(0))
            }
        }
    }

    private var shell: some View {
        // The banner sits above the TabView rather than over it. Floated in a
        // ZStack it covered whatever each screen puts at the top, which is a
        // title on four of the five; a `safeAreaInset` on the TabView does not
        // reach the NavigationStack inside each tab, so it clipped them just
        // the same. Stacked, the space is really taken, and when there is
        // nothing to say the banner is an EmptyView and costs no height.
        VStack(spacing: 0) {
            statusBanner

            TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })) {
                FocusView()
                    // On the content, not on the TabView: `.toolbar(_:for:
                    // .tabBar)` addresses the bar of the *enclosing* container,
                    // so hanging it off the TabView hides nothing and the
                    // running screen keeps a tab bar it is not supposed to have.
                    .toolbar((model.timer.isActive || model.reflecting != nil) ? .hidden : .visible, for: .tabBar)
                    .tag(AppModel.Tab.focus)
                    .tabItem { Label(AppModel.Tab.focus.label, systemImage: AppModel.Tab.focus.symbol) }

                NavigationStack { TasksView() }
                    .tag(AppModel.Tab.tasks)
                    .tabItem { Label(AppModel.Tab.tasks.label, systemImage: AppModel.Tab.tasks.symbol) }

                NavigationStack { CalendarSceneView() }
                    .tag(AppModel.Tab.calendar)
                    .tabItem { Label(AppModel.Tab.calendar.label, systemImage: AppModel.Tab.calendar.symbol) }

                NavigationStack { InsightsView() }
                    .tag(AppModel.Tab.insights)
                    .tabItem { Label(AppModel.Tab.insights.label, systemImage: AppModel.Tab.insights.symbol) }

                NavigationStack { SettingsView() }
                    .tag(AppModel.Tab.settings)
                    .tabItem { Label(AppModel.Tab.settings.label, systemImage: AppModel.Tab.settings.symbol) }
            }
        }
    }

    /// The only ambient status in the app, and only when there is something to say.
    @ViewBuilder
    private var statusBanner: some View {
        if !model.timer.isActive && model.reflecting == nil {
            // Only for a phone that was signed in and is not any more. Never
            // having signed in is not a problem to report; it is how the app
            // is meant to work, and a standing warning about it would be
            // nagging someone to fix something that is not broken.
            if model.authState == .signedOut && model.expectsSignIn {
                banner(
                    text: "Signed out — your work is safe here",
                    action: "Sign in",
                    tone: .warn
                ) { showingSignIn = true }
            } else if model.syncStatus.pending > 0 && model.syncStatus.isOffline {
                banner(
                    text: "Offline · \(model.syncStatus.pending) waiting to sync",
                    action: nil,
                    tone: .quiet
                ) {}
            }
        }
    }

    private enum Tone { case warn, quiet }

    private func banner(text: String, action: String?, tone: Tone, perform: @escaping () -> Void) -> some View {
        let theme = model.theme
        return HStack(spacing: 10) {
            Image(systemName: tone == .warn ? "exclamationmark.circle" : "icloud.slash")
                .font(.system(size: 12, weight: .semibold))
            Text(text).metaStyle()
            Spacer(minLength: 4)
            if let action {
                Button(action, action: perform)
                    .font(Typeface.font(12.5, .semibold))
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(tone == .warn ? theme.palette.warn : theme.palette.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(theme.palette.surface, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
