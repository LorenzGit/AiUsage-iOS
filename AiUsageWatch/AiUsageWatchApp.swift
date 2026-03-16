import SwiftUI

@main
struct AiUsageWatchApp: App {
    @State private var sessionManager = WatchSessionManager.shared

    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchDashboardView(sessionManager: sessionManager)
        }
    }
}
