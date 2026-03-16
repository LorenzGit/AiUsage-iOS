import Combine
import Foundation
import WatchConnectivity

/// Manages WatchConnectivity on the iPhone side.
/// Sends usage snapshots to the paired Apple Watch and handles refresh requests.
final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    /// Called by AppModel when a Watch-initiated refresh is requested.
    var onRefreshRequest: (() async -> WidgetSnapshot)?

    // MARK: - Observable watch status

    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false
    @Published private(set) var isReachable: Bool = false

    /// Human-readable status for the UI.
    var watchStatus: WatchStatus {
        guard WCSession.isSupported() else { return .unsupported }
        if !isPaired { return .notPaired }
        if !isWatchAppInstalled { return .appNotInstalled }
        if isReachable { return .connected }
        return .installed
    }

    enum WatchStatus: Equatable {
        case unsupported
        case notPaired
        case appNotInstalled
        case installed
        case connected

        var label: String {
            switch self {
            case .unsupported:      return "Watch not supported"
            case .notPaired:        return "No Apple Watch paired"
            case .appNotInstalled:  return "Watch app not installed"
            case .installed:        return "Watch app installed"
            case .connected:        return "Watch app connected"
            }
        }

        var systemImage: String {
            switch self {
            case .unsupported:      return "applewatch.slash"
            case .notPaired:        return "applewatch.slash"
            case .appNotInstalled:  return "applewatch.and.arrow.forward"
            case .installed:        return "applewatch"
            case .connected:        return "applewatch.radiowaves.left.and.right"
            }
        }

        var hint: String? {
            switch self {
            case .notPaired:        return "Pair an Apple Watch in Settings to use this feature."
            case .appNotInstalled:  return "Open the Watch app on your iPhone to install AI Usage."
            default:                return nil
            }
        }
    }

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
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }

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
        DispatchQueue.main.async {
            self.refreshStatus(from: session)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for multi-watch switching
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshStatus(from: session)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
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

    // MARK: - Private

    private func refreshStatus(from session: WCSession) {
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }
}
