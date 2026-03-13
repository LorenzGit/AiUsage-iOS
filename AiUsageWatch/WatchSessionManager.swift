import Foundation
import Observation
import WatchConnectivity

/// Manages WatchConnectivity on the Watch side.
/// Receives usage snapshots from the iPhone and caches them locally.
@MainActor @Observable
final class WatchSessionManager: NSObject {
    static let shared = WatchSessionManager()

    var snapshot: WidgetSnapshot?
    var lastUpdated: Date?
    var isRefreshing = false

    private let cacheKey = "aiusage.watch.cached_snapshot"
    private let cacheTimeKey = "aiusage.watch.cached_snapshot_time"

    private override init() {
        super.init()
        loadCached()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let delegate = SessionDelegate(manager: self)
        self.sessionDelegate = delegate
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    /// Request the iPhone to refresh all providers and send back the result.
    func requestRefresh() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        isRefreshing = true
        session.sendMessage(["action": "refresh"], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.handleSnapshotPayload(reply)
                self?.isRefreshing = false
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.isRefreshing = false
            }
        })
    }

    var isPhoneReachable: Bool {
        guard WCSession.isSupported() else { return false }
        return WCSession.default.isReachable
    }

    // MARK: - Private

    /// Prevent delegate from being deallocated
    private var sessionDelegate: SessionDelegate?

    fileprivate func handleSnapshotPayload(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return
        }
        snapshot = decoded
        lastUpdated = Date()
        cache(decoded)
    }

    private func cache(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimeKey)
    }

    private func loadCached() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return
        }
        snapshot = decoded
        let ts = UserDefaults.standard.double(forKey: cacheTimeKey)
        if ts > 0 { lastUpdated = Date(timeIntervalSince1970: ts) }
    }
}

// MARK: - WCSessionDelegate (must be NSObject, not @MainActor)

private class SessionDelegate: NSObject, WCSessionDelegate {
    weak var manager: WatchSessionManager?

    init(manager: WatchSessionManager) {
        self.manager = manager
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            manager?.handleSnapshotPayload(applicationContext)
        }
    }

    func session(_ session: WCSession,
                 didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            manager?.handleSnapshotPayload(userInfo)
        }
    }
}
