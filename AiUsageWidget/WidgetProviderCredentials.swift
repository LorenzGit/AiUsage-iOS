import Foundation

// Mirror of app credentials model for widget-only provider fetches.
struct ProviderCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let accountID: String?
    let cookieHeader: String?
    let geminiAuthorizationHeader: String?
    let geminiAPIKey: String?

    init(
        accessToken: String,
        refreshToken: String? = nil,
        accountID: String? = nil,
        cookieHeader: String? = nil,
        geminiAuthorizationHeader: String? = nil,
        geminiAPIKey: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.cookieHeader = cookieHeader
        self.geminiAuthorizationHeader = geminiAuthorizationHeader
        self.geminiAPIKey = geminiAPIKey
    }
}
