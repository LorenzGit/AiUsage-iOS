import Foundation
// source https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts
// source https://github.com/openai/codex/issues/5673
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