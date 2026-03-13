import Foundation
import WatchConnectivity

/// Manages WatchConnectivity on the iPhone side.
/// Sends usage snapshots to the paired Apple Watch and handles refresh requests.
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    /// Called by AppModel when a Watch-initiated refresh is requested.
    var onRefreshRequest: (() async -> WidgetSnapshot)?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the latest snapshot to the Watch via applicationContext (latest-wins)
    /// and transferUserInfo (queued reliable delivery).
    func sendSnapshot(_ snapshot: WidgetSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        guard let data = try? JSONEncoder().encode(snapshot),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // applicationContext: Watch gets latest on launch
        try? session.updateApplicationContext(json)

        // transferUserInfo: reliable queued delivery even if Watch app isn't running
        session.transferUserInfo(json)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // No-op; activation is fire-and-forget
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for multi-watch switching
        session.activate()
    }

    /// Handle refresh requests from the Watch.
    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["action"] as? String == "refresh" else {
            replyHandler(["error": "unknown action"])
            return
        }

        Task { @MainActor in
            guard let refresher = self.onRefreshRequest else {
                replyHandler(["error": "no refresh handler"])
                return
            }
            let snapshot = await refresher()
            if let data = try? JSONEncoder().encode(snapshot),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                replyHandler(json)
            } else {
                replyHandler(["error": "encode failed"])
            }
        }
    }
}
