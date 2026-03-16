import SwiftUI

@main
struct AiUsageApp: App {
    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
