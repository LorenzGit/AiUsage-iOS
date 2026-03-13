import Foundation

struct CopilotAPIClient: ProviderAPIClient {
    /// Fetches Copilot quota snapshots from GitHub's internal endpoint.
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        guard !credentials.accessToken.isEmpty else { throw ProviderFetchError.missingToken }

        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            throw ProviderFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("token \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(CopilotUsageResponse.self, from: data)
        let premiumUsed = decoded.quotaSnapshots.premiumInteractions.map { 100 - $0.percentRemaining }
        let chatUsed = decoded.quotaSnapshots.chat.map { 100 - $0.percentRemaining }
        let premiumResetsAt = nextMonthlyResetDate()

        return ProviderUsageSnapshot(
            provider: .copilot,
            usedPercent: clamp(premiumUsed),
            secondaryUsedPercent: clamp(chatUsed),
            sessionRemainingPercent: remaining(fromUsed: premiumUsed),
            weeklyRemainingPercent: remaining(fromUsed: chatUsed),
            sessionResetsAt: premiumResetsAt,
            statusText: decoded.copilotPlan.capitalized,
            updatedAt: Date()
        )
    }

    /// Copilot Premium resets on the first day of each month.
    private func nextMonthlyResetDate(now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent

        var startOfMonthComponents = calendar.dateComponents([.year, .month], from: now)
        startOfMonthComponents.day = 1
        startOfMonthComponents.hour = 0
        startOfMonthComponents.minute = 0
        startOfMonthComponents.second = 0

        guard let startOfCurrentMonth = calendar.date(from: startOfMonthComponents) else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: startOfCurrentMonth)
    }

    private struct CopilotUsageResponse: Decodable {
        let quotaSnapshots: QuotaSnapshots
        let copilotPlan: String

        enum CodingKeys: String, CodingKey {
            case quotaSnapshots = "quota_snapshots"
            case copilotPlan = "copilot_plan"
        }

        struct QuotaSnapshots: Decodable {
            let premiumInteractions: QuotaSnapshot?
            let chat: QuotaSnapshot?

            enum CodingKeys: String, CodingKey {
                case premiumInteractions = "premium_interactions"
                case chat
            }
        }

        struct QuotaSnapshot: Decodable {
            let percentRemaining: Double

            enum CodingKeys: String, CodingKey {
                case percentRemaining = "percent_remaining"
            }
        }
    }
}

