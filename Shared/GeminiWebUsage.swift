import Foundation

struct GeminiWebUsage: Codable {
    struct Window: Codable {
        let usedPercent: Double
        let resetsAt: Date?

        init?(input: [String: Any]) {
            guard let used = input["usedPercent"] as? Double, used.isFinite, (0...100).contains(used) else {
                return nil
            }
            usedPercent = used
            resetsAt = (input["resetsAt"] as? Double).flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
            }
        }
    }

    let session: Window
    let weekly: Window
    let importedAt: Date

    init?(results: [String: Any], importedAt: Date = .now) {
        guard results["outcome"] as? String == "ready",
              let sessionData = results["session"] as? [String: Any],
              let weeklyData = results["weekly"] as? [String: Any],
              let session = Window(input: sessionData),
              let weekly = Window(input: weeklyData) else {
            return nil
        }
        self.session = session
        self.weekly = weekly
        self.importedAt = importedAt
    }
}

enum GeminiWebUsageStore {
    static let appGroupID = "group.aiusage.gamojo.com"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("gemini-web-usage.json")
    }

    static func load() -> GeminiWebUsage? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(GeminiWebUsage.self, from: data)
    }

    static func save(_ usage: GeminiWebUsage) throws {
        guard let fileURL else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(usage).write(to: fileURL, options: .atomic)
    }
}

enum GeminiSyncRequest {
    static let appURL = URL(string: "aiusage://gemini/sync")!
    private static let lifetime: TimeInterval = 120

    static func createURL(for page: URL) throws -> URL {
        let id = UUID()
        guard let file = requestFile(id),
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if let files = try? FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ) {
            for previous in files where previous.lastPathComponent.hasPrefix("gemini-sync-") {
                try? FileManager.default.removeItem(at: previous)
            }
        }
        try Data().write(to: file, options: .atomic)
        let navigation = String(Int(Date().timeIntervalSince1970 * 1000))
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "aiusage_sync", value: navigation)]
        components.fragment = "aiusage-sync=\(id.uuidString.lowercased())"
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    static func isPending(_ id: UUID) -> Bool {
        guard let file = requestFile(id) else { return false }
        return !isExpired(file)
    }

    static func consume(_ id: UUID) -> Bool {
        guard let file = requestFile(id), !isExpired(file) else { return false }
        do {
            try FileManager.default.removeItem(at: file)
            return true
        } catch {
            return false
        }
    }

    private static func requestFile(_ id: UUID) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GeminiWebUsageStore.appGroupID)?
            .appendingPathComponent("gemini-sync-\(id.uuidString)")
    }

    private static func isExpired(_ file: URL) -> Bool {
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return true
        }
        return Date().timeIntervalSince(modified) > lifetime
    }
}
