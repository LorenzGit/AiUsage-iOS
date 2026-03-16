import Foundation

struct ClaudeAPIClient: ProviderAPIClient {
    /// Fetches Claude usage via OAuth token or claude.ai sessionKey cookie.
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader = credentials.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !accessToken.isEmpty {
            do {
                return try await fetchOAuthUsage(accessToken: accessToken)
            } catch {
                if !cookieHeader.isEmpty {
                    return try await fetchWebUsage(cookieHeader: cookieHeader)
                }
                throw error
            }
        }

        if !cookieHeader.isEmpty {
            return try await fetchWebUsage(cookieHeader: cookieHeader)
        }

        throw ProviderFetchError.missingToken
    }

    private func fetchOAuthUsage(accessToken: String) async throws -> ProviderUsageSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ProviderFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 {
            throw ProviderFetchError.unauthorized
        }
        if http.statusCode == 403 {
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if body.contains("user:profile") {
                throw ProviderFetchError.notSupported(
                    message: "Claude token is missing `user:profile` scope. Re-auth in Claude Code and paste the OAuth token again."
                )
            }
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
        let primaryUsed = decoded.fiveHour?.utilization
        let secondaryUsed = decoded.sevenDay?.utilization
        let oauthExtraUtilization = decoded.extraUsage?.isEnabled == true ? decoded.extraUsage?.utilization : nil
        let tertiaryUsed = oauthExtraUtilization
            ?? decoded.sevenDaySonnet?.utilization
            ?? decoded.sevenDayOpus?.utilization

        return ProviderUsageSnapshot(
            provider: .claude,
            usedPercent: clamp(primaryUsed),
            secondaryUsedPercent: clamp(secondaryUsed),
            tertiaryUsedPercent: clamp(tertiaryUsed),
            sessionRemainingPercent: remaining(fromUsed: primaryUsed),
            weeklyRemainingPercent: remaining(fromUsed: secondaryUsed),
            tertiaryRemainingPercent: remaining(fromUsed: tertiaryUsed),
            sessionResetsAt: parseISO8601Date(decoded.fiveHour?.resetsAt),
            weeklyResetsAt: parseISO8601Date(decoded.sevenDay?.resetsAt),
            statusText: inferredClaudePlan(from: decoded.rateLimitTier) ?? "OAuth usage",
            updatedAt: Date()
        )
    }

    private func fetchWebUsage(cookieHeader: String) async throws -> ProviderUsageSnapshot {
        let sessionKey = try extractClaudeSessionKey(from: cookieHeader)
        let orgID = try await fetchClaudeOrganizationID(sessionKey: sessionKey)
        let usage = try await fetchClaudeWebUsage(orgID: orgID, sessionKey: sessionKey)
        let extraUtilization = await fetchClaudeWebExtraUsageUtilization(orgID: orgID, sessionKey: sessionKey)

        let tertiaryUsed = extraUtilization ?? usage.sevenDaySonnet?.utilization ?? usage.sevenDayOpus?.utilization

        return ProviderUsageSnapshot(
            provider: .claude,
            usedPercent: clamp(usage.fiveHour?.utilization),
            secondaryUsedPercent: clamp(usage.sevenDay?.utilization),
            tertiaryUsedPercent: clamp(tertiaryUsed),
            sessionRemainingPercent: remaining(fromUsed: usage.fiveHour?.utilization),
            weeklyRemainingPercent: remaining(fromUsed: usage.sevenDay?.utilization),
            tertiaryRemainingPercent: remaining(fromUsed: tertiaryUsed),
            sessionResetsAt: parseISO8601Date(usage.fiveHour?.resetsAt),
            weeklyResetsAt: parseISO8601Date(usage.sevenDay?.resetsAt),
            statusText: "Web usage",
            updatedAt: Date()
        )
    }

    private func fetchClaudeOrganizationID(sessionKey: String) async throws -> String {
        guard let url = URL(string: "https://claude.ai/api/organizations") else {
            throw ProviderFetchError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            if let rawBody = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !rawBody.isEmpty
            {
                let snippet = String(rawBody.prefix(260))
                throw ProviderFetchError.notSupported(
                    message: "Claude HTTP \(http.statusCode): \(snippet)"
                )
            }
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let raw = try JSONSerialization.jsonObject(with: data)
        if let array = raw as? [[String: Any]],
           let id = firstOrganizationID(in: array)
        {
            return id
        }
        if let dict = raw as? [String: Any] {
            if let id = readOrganizationID(from: dict) {
                return id
            }
            if let array = dict["organizations"] as? [[String: Any]],
               let id = firstOrganizationID(in: array)
            {
                return id
            }
        }
        throw ProviderFetchError.invalidResponse
    }

    private func fetchClaudeWebUsage(orgID: String, sessionKey: String) async throws -> ClaudeWebUsageResponse {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/usage") else {
            throw ProviderFetchError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ClaudeWebUsageResponse.self, from: data)
        guard decoded.fiveHour?.utilization != nil else {
            throw ProviderFetchError.invalidResponse
        }
        return decoded
    }

    private func fetchClaudeWebExtraUsageUtilization(orgID: String, sessionKey: String) async -> Double? {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/overage_spend_limit") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try requireHTTP(response)
            guard (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(ClaudeWebOverageResponse.self, from: data)
            guard decoded.isEnabled == true else { return nil }
            return decoded.utilization
        } catch {
            return nil
        }
    }

    private func extractClaudeSessionKey(from rawHeader: String) throws -> String {
        let trimmed = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderFetchError.missingToken
        }

        let withoutCookiePrefix: String = {
            let lower = trimmed.lowercased()
            if lower.hasPrefix("cookie:") {
                return String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }()

        if !withoutCookiePrefix.contains("="),
           withoutCookiePrefix.lowercased().hasPrefix("sk-ant-")
        {
            return withoutCookiePrefix
        }

        for pair in withoutCookiePrefix.split(separator: ";") {
            let chunk = String(pair).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty, let separator = chunk.firstIndex(of: "=") else { continue }
            let name = String(chunk[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = chunk.index(after: separator)
            let value = String(chunk[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "sessionkey", !value.isEmpty {
                return value
            }
        }

        throw ProviderFetchError.notSupported(
            message: "Claude cookie must include `sessionKey=...`."
        )
    }

    private func firstOrganizationID(in organizations: [[String: Any]]) -> String? {
        for org in organizations {
            if let id = readOrganizationID(from: org) {
                return id
            }
        }
        return nil
    }

    private func readOrganizationID(from payload: [String: Any]) -> String? {
        let keys = ["uuid", "id", "organization_id"]
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func inferredClaudePlan(from rateLimitTier: String?) -> String? {
        guard let tier = rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !tier.isEmpty
        else {
            return nil
        }
        if tier.contains("max") { return "Claude Max" }
        if tier.contains("pro") { return "Claude Pro" }
        if tier.contains("team") { return "Claude Team" }
        if tier.contains("enterprise") { return "Claude Enterprise" }
        return nil
    }

    private struct ClaudeOAuthUsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let extraUsage: ExtraUsage?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
            case rateLimitTier = "rate_limit_tier"
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct ExtraUsage: Decodable {
            let isEnabled: Bool?
            let utilization: Double?

            enum CodingKeys: String, CodingKey {
                case isEnabled = "is_enabled"
                case utilization
            }
        }
    }

    private struct ClaudeWebUsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
    }

    private struct ClaudeWebOverageResponse: Decodable {
        let isEnabled: Bool?
        let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case utilization
        }
    }
}

