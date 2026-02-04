import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ProviderFetchError: LocalizedError {
    case missingToken
    case unauthorized
    case server(statusCode: Int)
    case notSupported(message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Missing access token."
        case .unauthorized:
            return "Unauthorized. Token is invalid or expired."
        case let .server(statusCode):
            return "Server error: HTTP \(statusCode)."
        case .notSupported(let message):
            return message
        case .invalidResponse:
            return "Could not parse provider response."
        }
    }
}

protocol ProviderAPIClient: Sendable {
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot
}

enum ProviderAPIClientFactory {
    static func client(for provider: ProviderID) -> any ProviderAPIClient {
        switch provider {
        case .codex: return CodexAPIClient()
        case .claude: return ClaudeAPIClient()
        case .gemini: return GeminiAPIClient()
        case .copilot: return CopilotAPIClient()
        case .kimi: return KimiAPIClient()
        }
    }
}

struct CodexAPIClient: ProviderAPIClient {
    /// Fetches Codex usage windows and stitches optional code-review data from fallback endpoints.
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader = credentials.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !accessToken.isEmpty || !cookieHeader.isEmpty else {
            throw ProviderFetchError.notSupported(
                message: "Connect a ChatGPT session in Settings first."
            )
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw ProviderFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")

        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        // Fallback order for third bar (Code Review):
        // 1) same payload with flexible key lookup
        // 2) codex usage API
        // 3) dashboard HTML scrape as last resort
        let fallbackCodeReview = Self.extractCodeReviewWindow(from: data)
        let codexAPIReview: FlexibleWindow? =
            fallbackCodeReview.usedPercent == nil ? await self.fetchCodexAPIReviewWindow(using: credentials) : nil
        let dashboardCodeReview: FlexibleWindow? =
            fallbackCodeReview.usedPercent == nil && codexAPIReview?.usedPercent == nil &&
            !cookieHeader.isEmpty ? await self.fetchDashboardCodeReviewWindow(using: credentials) : nil
        let primaryUsed = decoded.rateLimit?.primaryWindow?.usedPercent
        let secondaryUsed = decoded.rateLimit?.secondaryWindow?.usedPercent
        let tertiaryUsed = decoded.rateLimit?.tertiaryWindow?.usedPercent
            ?? decoded.rateLimit?.codeReviewWindow?.usedPercent
            ?? decoded.codeReviewUsedPercent
            ?? fallbackCodeReview.usedPercent
            ?? codexAPIReview?.usedPercent
            ?? dashboardCodeReview?.usedPercent
        let tertiaryResetAt = decoded.rateLimit?.tertiaryWindow?.resetAt
            ?? decoded.rateLimit?.codeReviewWindow?.resetAt
            ?? decoded.codeReviewResetAt
            ?? fallbackCodeReview.resetAt
            ?? codexAPIReview?.resetAt
            ?? dashboardCodeReview?.resetAt

        return ProviderUsageSnapshot(
            provider: .codex,
            usedPercent: clamp(primaryUsed),
            secondaryUsedPercent: clamp(secondaryUsed),
            tertiaryUsedPercent: clamp(tertiaryUsed),
            sessionRemainingPercent: remaining(fromUsed: primaryUsed),
            weeklyRemainingPercent: remaining(fromUsed: secondaryUsed),
            tertiaryRemainingPercent: remaining(fromUsed: tertiaryUsed),
            sessionResetsAt: dateFromUnixSeconds(decoded.rateLimit?.primaryWindow?.resetAt),
            weeklyResetsAt: dateFromUnixSeconds(decoded.rateLimit?.secondaryWindow?.resetAt),
            tertiaryResetsAt: dateFromUnixSeconds(tertiaryResetAt),
            statusText: decoded.planType?.displayLabel ?? "Subscription usage",
            updatedAt: Date()
        )
    }

    /// Secondary Codex endpoint that sometimes exposes tertiary/review usage.
    private func fetchCodexAPIReviewWindow(using credentials: ProviderCredentials) async -> FlexibleWindow? {
        guard let url = URL(string: "https://chatgpt.com/api/codex/usage") else { return nil }

        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader = credentials.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")

        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let accountID = credentials.accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return Self.extractCodeReviewWindow(from: data)
        } catch {
            return nil
        }
    }

    /// Last-resort dashboard fetch to recover review usage when API payloads omit it.
    private func fetchDashboardCodeReviewWindow(using credentials: ProviderCredentials) async -> FlexibleWindow? {
        guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return nil }

        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader = credentials.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")

        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let accountID = credentials.accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            guard let body = String(data: data, encoding: .utf8), !body.isEmpty else { return nil }
            return Self.parseDashboardCodeReviewWindow(from: body)
        } catch {
            return nil
        }
    }

    private struct FlexibleWindow {
        let usedPercent: Double?
        let resetAt: Double?
    }

    /// Reads review usage from arbitrary JSON without assuming exact server keys.
    private static func extractCodeReviewWindow(from data: Data) -> FlexibleWindow {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FlexibleWindow(usedPercent: nil, resetAt: nil)
        }
        return self.extractCodeReviewWindow(from: raw)
    }

    private static func extractCodeReviewWindow(from json: [String: Any]) -> FlexibleWindow {
        var usedPercent = self.number(from: json["code_review_used_percent"])
        if usedPercent == nil, let remaining = self.number(from: json["code_review_remaining_percent"]) {
            usedPercent = 100 - remaining
        }
        var resetAt = self.number(from: json["code_review_reset_at"])

        let rateLimit = json["rate_limit"] as? [String: Any]
        let candidateKeys = [
            "code_review_window",
            "code_review",
            "review_window",
            "github_code_review_window",
            "tertiary_window",
            "tertiary",
        ]

        for key in candidateKeys {
            guard let rateLimit else { break }
            guard let windowJSON = rateLimit[key] as? [String: Any] else { continue }
            let parsed = self.parseWindow(from: windowJSON)
            usedPercent = usedPercent ?? parsed.usedPercent
            resetAt = resetAt ?? parsed.resetAt
            if usedPercent != nil, resetAt != nil {
                break
            }
        }

        if let rateLimit {
            for (key, value) in rateLimit where key.localizedCaseInsensitiveContains("review") ||
                key.localizedCaseInsensitiveContains("tertiary")
            {
                guard let windowJSON = value as? [String: Any] else { continue }
                let parsed = self.parseWindow(from: windowJSON)
                usedPercent = usedPercent ?? parsed.usedPercent
                resetAt = resetAt ?? parsed.resetAt
                if usedPercent != nil, resetAt != nil {
                    break
                }
            }
        }

        return FlexibleWindow(usedPercent: usedPercent, resetAt: resetAt)
    }

    private static func parseWindow(from json: [String: Any]) -> FlexibleWindow {
        let usedKeys = ["used_percent", "usedPercent", "usage_percent", "utilization", "percent_used"]
        let remainingKeys = ["remaining_percent", "remainingPercent", "percent_remaining"]
        let resetKeys = ["reset_at", "resetAt", "resets_at", "resetsAt", "reset_time", "resetTime"]

        var usedPercent = usedKeys.lazy.compactMap { self.number(from: json[$0]) }.first
        if usedPercent == nil, let remaining = remainingKeys.lazy.compactMap({ self.number(from: json[$0]) }).first {
            usedPercent = 100 - remaining
        }
        let resetAt = resetKeys.lazy.compactMap { self.number(from: json[$0]) }.first
        return FlexibleWindow(usedPercent: usedPercent, resetAt: resetAt)
    }

    private static func parseDashboardCodeReviewWindow(from body: String) -> FlexibleWindow? {
        let cleaned = body.replacingOccurrences(of: "\r", with: "\n")

        let keyPatterns: [(pattern: String, isRemaining: Bool)] = [
            (#""codeReviewRemainingPercent"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, true),
            (#""code_review_remaining_percent"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, true),
            (#""codeReviewUsedPercent"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, false),
            (#""code_review_used_percent"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, false),
        ]

        for item in keyPatterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let capture = Range(match.range(at: 1), in: cleaned),
                  let value = Double(cleaned[capture])
            else {
                continue
            }
            let used = item.isRemaining ? 100 - value : value
            return FlexibleWindow(usedPercent: min(max(used, 0), 100), resetAt: nil)
        }

        let textPatterns: [(pattern: String, isRemaining: Bool)] = [
            (#"(?:GitHub\s*)?Code\s*review[^0-9%]*([0-9]{1,3})%\s*(?:remaining|left)"#, true),
            (#"Core\s*review[^0-9%]*([0-9]{1,3})%\s*(?:remaining|left)"#, true),
            (#"(?:GitHub\s*)?Code\s*review[^0-9%]*([0-9]{1,3})%\s*used"#, false),
        ]

        for item in textPatterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let capture = Range(match.range(at: 1), in: cleaned),
                  let value = Double(cleaned[capture])
            else {
                continue
            }
            let used = item.isRemaining ? 100 - value : value
            return FlexibleWindow(usedPercent: min(max(used, 0), 100), resetAt: nil)
        }

        let broadFallbackPattern = #"(?:(?:GitHub\s*)?Code|Core)\s*review[^\n]*?([0-9]{1,3})%"#
        if let regex = try? NSRegularExpression(pattern: broadFallbackPattern, options: [.caseInsensitive]) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let capture = Range(match.range(at: 1), in: cleaned),
                  let remaining = Double(cleaned[capture])
            else {
                return nil
            }
            return FlexibleWindow(usedPercent: min(max(100 - remaining, 0), 100), resetAt: nil)
        }
        return nil
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private struct CodexUsageResponse: Decodable {
        let planType: String?
        let rateLimit: RateLimit?
        let codeReviewUsedPercent: Double?
        let codeReviewResetAt: Double?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case codeReviewUsedPercent = "code_review_used_percent"
            case codeReviewResetAt = "code_review_reset_at"
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
            let tertiaryWindow: Window?
            let codeReviewWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
                case tertiaryWindow = "tertiary_window"
                case codeReviewWindow = "code_review_window"
            }
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let resetAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
            }
        }
    }
}

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
                    message: "Gemini HTTP \(http.statusCode): \(snippet)"
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

struct GeminiAPIClient: ProviderAPIClient {
    private struct GeminiBucketUsage {
        let usedPercent: Double
        let resetAt: Date?
    }

    /// Fetches Gemini quota buckets and maps them into session/weekly bars.
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader = credentials.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let studioAuthorization = credentials.geminiAuthorizationHeader?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let studioAPIKey = credentials.geminiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasStudioHeaders = !cookieHeader.isEmpty && !studioAuthorization.isEmpty

        guard !accessToken.isEmpty || hasStudioHeaders else {
            throw ProviderFetchError.missingToken
        }

        let projectID = try await loadCodeAssistProjectID(
            accessToken: accessToken,
            hasStudioHeaders: hasStudioHeaders,
            studioAuthorization: studioAuthorization,
            cookieHeader: cookieHeader,
            studioAPIKey: studioAPIKey
        )
        let quotaRequestBody: Data
        if let projectID, !projectID.isEmpty {
            quotaRequestBody = try JSONSerialization.data(withJSONObject: ["project": projectID], options: [])
        } else {
            quotaRequestBody = Data("{}".utf8)
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw ProviderFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyGeminiAuthHeaders(
            to: &request,
            accessToken: accessToken,
            hasStudioHeaders: hasStudioHeaders,
            studioAuthorization: studioAuthorization,
            cookieHeader: cookieHeader,
            studioAPIKey: studioAPIKey
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = quotaRequestBody

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let buckets = decoded.buckets ?? []

        guard !buckets.isEmpty else {
            throw ProviderFetchError.notSupported(
                message: "Gemini returned no quota buckets. This endpoint is still experimental."
            )
        }

        let proUsage = maxUsedUsage(in: buckets, contains: "pro")
        let flashUsage = maxUsedUsage(in: buckets, contains: "flash")
        let fallbackUsage = maxUsedUsage(in: buckets, contains: nil)
        let resolvedPrimaryUsage = proUsage ?? fallbackUsage
        let resolvedSecondaryUsage = flashUsage ?? fallbackUsage

        return ProviderUsageSnapshot(
            provider: .gemini,
            usedPercent: clamp(resolvedPrimaryUsage?.usedPercent),
            secondaryUsedPercent: clamp(resolvedSecondaryUsage?.usedPercent),
            sessionRemainingPercent: remaining(fromUsed: resolvedPrimaryUsage?.usedPercent),
            weeklyRemainingPercent: remaining(fromUsed: resolvedSecondaryUsage?.usedPercent),
            sessionResetsAt: resolvedPrimaryUsage?.resetAt,
            weeklyResetsAt: resolvedSecondaryUsage?.resetAt,
            statusText: "Experimental API",
            updatedAt: Date()
        )
    }

    private func loadCodeAssistProjectID(
        accessToken: String,
        hasStudioHeaders: Bool,
        studioAuthorization: String,
        cookieHeader: String,
        studioAPIKey: String
    ) async throws -> String? {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
            throw ProviderFetchError.invalidResponse
        }

        let payload: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyGeminiAuthHeaders(
            to: &request,
            accessToken: accessToken,
            hasStudioHeaders: hasStudioHeaders,
            studioAuthorization: studioAuthorization,
            cookieHeader: cookieHeader,
            studioAPIKey: studioAPIKey
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let direct = json["cloudaicompanionProject"] as? String, !direct.isEmpty {
            return direct
        }

        if
            let response = json["response"] as? [String: Any],
            let project = response["cloudaicompanionProject"] as? [String: Any],
            let id = project["id"] as? String,
            !id.isEmpty
        {
            return id
        }

        return nil
    }

    private func applyGeminiAuthHeaders(
        to request: inout URLRequest,
        accessToken: String,
        hasStudioHeaders: Bool,
        studioAuthorization: String,
        cookieHeader: String,
        studioAPIKey: String
    ) {
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return
        }

        if hasStudioHeaders {
            request.setValue(studioAuthorization, forHTTPHeaderField: "Authorization")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            if !studioAPIKey.isEmpty {
                request.setValue(studioAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
            }
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("https://aistudio.google.com", forHTTPHeaderField: "Origin")
            request.setValue("https://aistudio.google.com/", forHTTPHeaderField: "Referer")
            request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")
        }
    }

    private func maxUsedUsage(in buckets: [GeminiQuotaResponse.Bucket], contains needle: String?) -> GeminiBucketUsage? {
        let filtered: [GeminiQuotaResponse.Bucket]
        if let needle {
            filtered = buckets.filter { ($0.modelID ?? "").localizedCaseInsensitiveContains(needle) }
        } else {
            filtered = buckets
        }

        let values = filtered.compactMap { bucket -> GeminiBucketUsage? in
            guard let remaining = bucket.remainingFraction else { return nil }
            guard let used = usedPercent(fromRawRemaining: remaining) else { return nil }
            return GeminiBucketUsage(
                usedPercent: used,
                resetAt: parseISO8601Date(bucket.resetTime)
            )
        }

        // Some accounts expose multiple quota buckets for the same model family.
        // If at least one bucket still has capacity, prefer a non-exhausted bucket
        // so an exhausted side bucket doesn't pin the UI at 100%.
        let nonExhausted = values.filter { $0.usedPercent < 100 }
        if let best = nonExhausted.max(by: { $0.usedPercent < $1.usedPercent }) {
            return best
        }
        return values.max(by: { $0.usedPercent < $1.usedPercent })
    }

    private func usedPercent(fromRawRemaining raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0 else { return nil }

        var remainingPercent = raw

        // Observed variants:
        // - 0...1 fraction
        // - 0...100 percent
        // - scaled percent (e.g. 6300 => 63.00)
        if remainingPercent <= 1 {
            remainingPercent *= 100
        } else if remainingPercent > 100 {
            while remainingPercent > 100, remainingPercent <= 1_000_000 {
                remainingPercent /= 100
            }
        }

        guard remainingPercent >= 0, remainingPercent <= 100 else { return nil }
        return 100 - remainingPercent
    }

    private struct GeminiQuotaResponse: Decodable {
        let buckets: [Bucket]?

        struct Bucket: Decodable {
            let remainingFraction: Double?
            let modelID: String?
            let resetTime: String?

            enum CodingKeys: String, CodingKey {
                case remainingFraction
                case modelID = "modelId"
                case resetTime
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                if let numeric = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                    remainingFraction = numeric
                } else if let text = try container.decodeIfPresent(String.self, forKey: .remainingFraction),
                          let numeric = Double(text)
                {
                    remainingFraction = numeric
                } else {
                    remainingFraction = nil
                }

                modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
                resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
            }
        }
    }
}

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

enum CodexTokenRefreshError: LocalizedError {
    case missingRefreshToken
    case expired
    case revoked
    case reused
    case invalidResponse(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Missing Codex refresh token."
        case .expired:
            return "Codex refresh token expired. Run `codex login` again."
        case .revoked:
            return "Codex refresh token was revoked. Run `codex login` again."
        case .reused:
            return "Codex refresh token was already used. Run `codex login` again."
        case let .invalidResponse(message):
            return "Invalid Codex token refresh response: \(message)"
        case let .networkError(error):
            return "Codex token refresh failed: \(error.localizedDescription)"
        }
    }
}

enum GeminiTokenRefreshError: LocalizedError {
    case missingRefreshToken
    case revoked
    case invalidResponse(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Missing Gemini refresh token."
        case .revoked:
            return "Gemini refresh token was revoked. Run your OAuth script again."
        case let .invalidResponse(message):
            return "Invalid Gemini token refresh response: \(message)"
        case let .networkError(error):
            return "Gemini token refresh failed: \(error.localizedDescription)"
        }
    }
}

struct GeminiTokenRefresher: Sendable {
    private var config: Config? { getConfig() }
    private var gc: String? { config?.gc }
    private var gcs: String? { config?.gcs }
    private let refreshEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Refreshes Gemini OAuth access token using the persisted refresh token.
    func refresh(_ credentials: ProviderCredentials) async throws -> ProviderCredentials {
        let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !refreshToken.isEmpty else {
            throw GeminiTokenRefreshError.missingRefreshToken
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: gc ?? ""),
            URLQueryItem(name: "client_secret", value: gcs ?? ""),
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try requireHTTP(response)

            if http.statusCode == 400 || http.statusCode == 401 {
                let code = extractRefreshErrorCode(from: data).lowercased()
                if code == "invalid_grant" {
                    throw GeminiTokenRefreshError.revoked
                }
                let description = extractRefreshErrorDescription(from: data)
                if !code.isEmpty || !description.isEmpty {
                    let detail = [code, description]
                        .filter { !$0.isEmpty }
                        .joined(separator: ": ")
                    throw GeminiTokenRefreshError.invalidResponse(detail)
                }
            }

            guard http.statusCode == 200 else {
                throw GeminiTokenRefreshError.invalidResponse("HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GeminiTokenRefreshError.invalidResponse("Invalid JSON")
            }

            let accessToken = (json["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !accessToken.isEmpty else {
                throw GeminiTokenRefreshError.invalidResponse("Missing access_token")
            }

            let updatedRefreshToken = (json["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return ProviderCredentials(
                accessToken: accessToken,
                refreshToken: (updatedRefreshToken?.isEmpty == false)
                    ? updatedRefreshToken
                    : credentials.refreshToken,
                accountID: credentials.accountID
            )
        } catch let error as GeminiTokenRefreshError {
            throw error
        } catch {
            throw GeminiTokenRefreshError.networkError(error)
        }
    }

}

struct CodexTokenRefresher: Sendable {
    private let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private var config: Config? { getConfig() }
    private var cx: String? { config?.cx }

    /// Refreshes Codex access token using the persisted refresh token.
    func refresh(_ credentials: ProviderCredentials) async throws -> ProviderCredentials {
        let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !refreshToken.isEmpty else {
            throw CodexTokenRefreshError.missingRefreshToken
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": cx ?? "",
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try requireHTTP(response)

            if http.statusCode == 401 {
                let code = extractRefreshErrorCode(from: data).lowercased()
                switch code {
                case "refresh_token_expired":
                    throw CodexTokenRefreshError.expired
                case "refresh_token_reused":
                    throw CodexTokenRefreshError.reused
                case "refresh_token_invalidated":
                    throw CodexTokenRefreshError.revoked
                default:
                    throw CodexTokenRefreshError.expired
                }
            }

            guard http.statusCode == 200 else {
                throw CodexTokenRefreshError.invalidResponse("HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexTokenRefreshError.invalidResponse("Invalid JSON")
            }

            let accessToken = (json["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !accessToken.isEmpty else {
                throw CodexTokenRefreshError.invalidResponse("Missing access_token")
            }

            let updatedRefreshToken = (json["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let accountID = (json["account_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let idToken = (json["id_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let accountIDFromIDToken = parseChatGPTAccountID(fromIDToken: idToken)

            return ProviderCredentials(
                accessToken: accessToken,
                refreshToken: (updatedRefreshToken?.isEmpty == false)
                    ? updatedRefreshToken
                    : credentials.refreshToken,
                accountID: (accountID?.isEmpty == false)
                    ? accountID
                    : (accountIDFromIDToken ?? credentials.accountID)
            )
        } catch let error as CodexTokenRefreshError {
            throw error
        } catch {
            throw CodexTokenRefreshError.networkError(error)
        }
    }

}

private func requireHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        throw ProviderFetchError.invalidResponse
    }
    return http
}

private func clamp(_ value: Double?) -> Double? {
    guard let value else { return nil }
    return min(max(value, 0), 100)
}

private func clampFlexible(_ value: Double) -> Double {
    min(max(value, -200), 200)
}

private func remaining(fromUsed used: Double?) -> Double? {
    guard let used else { return nil }
    return 100 - used
}

private func dateFromUnixSeconds(_ value: Double?) -> Date? {
    guard let value else { return nil }
    return Date(timeIntervalSince1970: value)
}

private func parseISO8601Date(_ value: String?) -> Date? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: value)
}

private func extractRefreshErrorCode(from data: Data) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
    if let nested = json["error"] as? [String: Any], let code = nested["code"] as? String {
        return code
    }
    if let error = json["error"] as? String {
        return error
    }
    return (json["code"] as? String) ?? ""
}

private func extractRefreshErrorDescription(from data: Data) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
    if let nested = json["error"] as? [String: Any],
       let message = nested["message"] as? String
    {
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let description = json["error_description"] as? String {
        return description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let message = json["message"] as? String {
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

private extension String {
    var displayLabel: String {
        let replaced = self.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replaced.isEmpty else { return "Subscription usage" }
        return replaced.split(separator: " ").map { $0.capitalized }.joined(separator: " ") + " plan"
    }
}
