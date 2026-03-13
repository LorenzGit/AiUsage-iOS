import Foundation

struct KimiAPIClient: ProviderAPIClient {
    /// Fetches Kimi FEATURE_CODING limits and maps session/weekly windows.
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        guard !credentials.accessToken.isEmpty else { throw ProviderFetchError.missingToken }
        guard let url = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages") else {
            throw ProviderFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(credentials.accessToken)", forHTTPHeaderField: "Cookie")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.httpBody = Data("{\"scope\":[\"FEATURE_CODING\"]}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        guard let usage = decoded.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw ProviderFetchError.notSupported(message: "Kimi returned no FEATURE_CODING usage.")
        }

        let weeklyRemaining = parseRemainingPercent(limit: usage.detail.limit, remaining: usage.detail.remaining)
        let weeklyUsed = weeklyRemaining.map { 100 - $0 }

        let sessionDetail = usage.limits?.first?.detail
        let sessionRemaining = parseRemainingPercent(
            limit: sessionDetail?.limit ?? "",
            remaining: sessionDetail?.remaining
        )
        let sessionUsed = sessionRemaining.map { 100 - $0 }

        return ProviderUsageSnapshot(
            provider: .kimi,
            usedPercent: sessionUsed.map(clampFlexible),
            secondaryUsedPercent: weeklyUsed.map(clampFlexible),
            sessionRemainingPercent: sessionRemaining,
            weeklyRemainingPercent: weeklyRemaining,
            sessionResetsAt: parseISO8601Date(sessionDetail?.resetTime),
            weeklyResetsAt: parseISO8601Date(usage.detail.resetTime),
            statusText: "Coding quota",
            updatedAt: Date()
        )
    }

    private func parseRemainingPercent(limit: String, remaining: String?) -> Double? {
        guard let limitValue = Double(limit), limitValue > 0 else { return nil }
        guard let remaining, let remainingValue = Double(remaining) else { return nil }
        return (remainingValue / limitValue) * 100
    }

    private struct KimiUsageResponse: Decodable {
        let usages: [KimiUsage]
    }

    private struct KimiUsage: Decodable {
        let scope: String
        let detail: KimiUsageDetail
        let limits: [KimiRateLimit]?
    }

    private struct KimiUsageDetail: Decodable {
        let limit: String
        let remaining: String?
        let resetTime: String
    }

    private struct KimiRateLimit: Decodable {
        let detail: KimiUsageDetail
    }
}

