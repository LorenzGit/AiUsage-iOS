import Foundation

public enum WidgetSnapshotStore {
    public static let appGroupID = "group.aiusage.gamojo.com"
    private static let fileName = "widget-snapshot.json"
    private static let refreshCredentialsFileName = "widget-refresh-credentials.json"

    public static func save(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL() else { return }
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Keep MVP simple: fail silently.
        }
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public static func saveRefreshCredentials(_ credentialsByProvider: [ProviderID: WidgetRefreshCredentials]) {
        guard let url = refreshCredentialsURL() else { return }
        let payload = WidgetRefreshCredentialsPayload(credentialsByProvider: credentialsByProvider)
        do {
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Keep MVP simple: fail silently.
        }
    }

    public static func loadRefreshCredentials() -> [ProviderID: WidgetRefreshCredentials] {
        guard let url = refreshCredentialsURL() else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let payload = try? decoder.decode(WidgetRefreshCredentialsPayload.self, from: data) else { return [:] }
        return payload.credentialsByProvider
    }

    private static func snapshotURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            return nil
        }
        return container.appendingPathComponent(fileName)
    }

    private static func refreshCredentialsURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            return nil
        }
        return container.appendingPathComponent(refreshCredentialsFileName)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct WidgetRefreshCredentials: Codable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let cookieHeader: String?
    public let geminiAuthorizationHeader: String?
    public let geminiAPIKey: String?

    public init(
        accessToken: String,
        accountID: String? = nil,
        cookieHeader: String? = nil,
        geminiAuthorizationHeader: String? = nil,
        geminiAPIKey: String? = nil
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.cookieHeader = cookieHeader
        self.geminiAuthorizationHeader = geminiAuthorizationHeader
        self.geminiAPIKey = geminiAPIKey
    }
}

private struct WidgetRefreshCredentialsPayload: Codable {
    let credentialsByProvider: [ProviderID: WidgetRefreshCredentials]
}

public enum ProviderOrderStore {
    private static let defaultsKey = "provider-order-v1"

    public static func load() -> [ProviderID] {
        guard let stored = defaults.array(forKey: defaultsKey) as? [String] else {
            return ProviderID.allCases
        }
        let providers = stored.compactMap(ProviderID.init(rawValue:))
        return normalized(providers)
    }

    public static func save(_ providers: [ProviderID]) {
        let normalizedProviders = normalized(providers)
        defaults.set(normalizedProviders.map(\.rawValue), forKey: defaultsKey)
    }

    public static func normalized(_ providers: [ProviderID]) -> [ProviderID] {
        var seen = Set<ProviderID>()
        var ordered: [ProviderID] = []

        for provider in providers where seen.insert(provider).inserted {
            ordered.append(provider)
        }
        for provider in ProviderID.allCases where seen.insert(provider).inserted {
            ordered.append(provider)
        }

        return ordered
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) ?? .standard
    }
}

public enum ProviderWidgetVisibilityStore {
    private static let defaultsKey = "provider-widget-visibility-v1"

    public static func load() -> [ProviderID: Bool] {
        let raw = defaults.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
        var visibility: [ProviderID: Bool] = [:]
        for provider in ProviderID.allCases {
            visibility[provider] = raw[provider.rawValue] ?? true
        }
        return visibility
    }

    public static func save(_ visibility: [ProviderID: Bool]) {
        var raw: [String: Bool] = [:]
        for provider in ProviderID.allCases {
            raw[provider.rawValue] = visibility[provider] ?? true
        }
        defaults.set(raw, forKey: defaultsKey)
    }

    public static func isEnabled(_ provider: ProviderID) -> Bool {
        load()[provider] ?? true
    }

    public static func enabledProviders(in orderedProviders: [ProviderID]) -> [ProviderID] {
        orderedProviders.filter { isEnabled($0) }
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) ?? .standard
    }
}
