import SwiftUI
import BackgroundTasks
import SeshCore
import SeshStore

@main
struct SeshApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// The identifier must also be listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskId = "us.liyifan.sesh.refresh"

    init() {
        let database: AppDatabase
        do {
            let folder = URL.applicationSupportDirectory.appendingPathComponent("sesh", isDirectory: true)
            database = try AppDatabase.onDisk(folder: folder)
        } catch {
            /*
             A database that will not open is not something to paper over: every
             session this app records lives there, and carrying on against an
             in-memory stand-in would silently throw away the person's morning.
             */
            fatalError("sesh could not open its database: \(error)")
        }

        #if DEBUG
        // Isolated simulator tests never need the production account or data.
        let serverAddress = ProcessInfo.processInfo.environment["SESH_QA_SERVER_URL"] ?? DeviceDefaults.serverURL
        #else
        let serverAddress = DeviceDefaults.serverURL
        #endif
        let server = URL(string: serverAddress) ?? URL(string: "https://sesh.liyifan.us")!
        _model = State(initialValue: AppModel(database: database, serverURL: server))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskId)) {
            // Best-effort, and deliberately not depended on: the sessions are
            // already safe locally, and this only shortens how long they wait.
            await model.syncNow()
        }
        .onChange(of: scenePhase) { _, phase in
            model.setForeground(phase == .active)
            if phase == .background { scheduleRefresh() }
            if phase == .active { model.refreshWatch() }
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
