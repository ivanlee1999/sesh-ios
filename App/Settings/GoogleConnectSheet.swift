import SwiftUI
import SeshCore
#if canImport(UIKit)
import UIKit
#endif

/**
 Connecting Google Calendar from a phone.

 A code to type, not a redirect to catch. The web app sends the browser to
 Google and back to its own domain, which works there and cannot work here — so
 this uses the device flow, which exists for precisely this: read a short code,
 approve it wherever it is convenient, and the app finds out by asking.
 */
struct GoogleConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var phase: Phase = .starting
    @State private var pollTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case starting
        case waiting(code: String, url: URL)
        case connected
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch phase {
                case .starting:
                    ProgressView().controlSize(.large)
                    Text("Asking Google for a code…").metaStyle().foregroundStyle(theme.palette.textTertiary)

                case let .waiting(code, url):
                    Text("Enter this code").eyebrowStyle().foregroundStyle(theme.palette.textSecondary)

                    Text(code)
                        .numeralStyle(34, weight: .bold)
                        .tracking(4)
                        .foregroundStyle(theme.palette.text)
                        .textSelection(.enabled)

                    Text(url.host ?? url.absoluteString)
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)

                    VStack(spacing: 8) {
                        Button("Open Google") { openURL(url) }
                            .seshButton(.primary)
                        Button("Copy code") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = code
                            #endif
                            Haptics.light()
                        }
                        .seshButton(.tonal)
                    }

                    Text("Leave this open — sesh will notice once you have approved it.")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                        .multilineTextAlignment(.center)

                case .connected:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(theme.palette.good)
                    Text("Connected").titleStyle(20)
                    Text("Focus sessions will appear on a calendar named sesh. Breaks are left out.")
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                        .multilineTextAlignment(.center)

                case let .failed(message):
                    Text("That did not work").titleStyle(20)
                    Text(message)
                        .metaStyle()
                        .foregroundStyle(theme.palette.textTertiary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { start() }.seshButton(.tonal)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(theme.palette.background)
            .navigationTitle("Google Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .connected ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .task { start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        pollTask?.cancel()
        phase = .starting
        pollTask = Task {
            do {
                let flow = try await model.startGoogleConnect()
                phase = .waiting(code: flow.userCode, url: flow.verificationURL)
                let ok = await model.awaitGoogleApproval(deviceCode: flow.deviceCode, interval: flow.interval)
                phase = ok ? .connected : .failed("Google did not confirm the code in time.")
            } catch {
                phase = .failed(ThingsSheet.explain(error))
            }
        }
    }
}
