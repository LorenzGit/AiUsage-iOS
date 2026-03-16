import Foundation

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


private extension String {
    var displayLabel: String {
        let replaced = self.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replaced.isEmpty else { return "Subscription usage" }
        return replaced.split(separator: " ").map { $0.capitalized }.joined(separator: " ") + " plan"
    }
}
