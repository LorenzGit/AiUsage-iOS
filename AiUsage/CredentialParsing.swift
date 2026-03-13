import Foundation

// MARK: - Public interface

func normalizedToken(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func parseCredentialsInput(for provider: ProviderID, input: String) throws -> ProviderCredentials {
    if provider == .codex,
       let parsed = try CodexAuthJSONSupport.parseIfRawAuthJSON(input)
    {
        return parsed
    }
    if provider == .gemini,
       let parsed = try GeminiAuthJSONSupport.parseIfRawAuthJSON(input)
    {
        return parsed
    }

    switch provider {
    case .codex:
        return ProviderCredentials(accessToken: input)
    case .claude:
        return try parseClaudeCredentialsInput(input)
    case .gemini:
        return try parseGeminiCredentialsInput(input)
    case .copilot:
        return ProviderCredentials(accessToken: try parseCopilotAccessToken(input))
    case .kimi:
        return try parseKimiCredentialsInput(input)
    }
}

func displayToken(for provider: ProviderID, credentials: ProviderCredentials) -> String {
    let accessToken = normalizedToken(credentials.accessToken)
    if !accessToken.isEmpty {
        return accessToken
    }
    if provider == .gemini {
        let cookieHeader = normalizedToken(credentials.cookieHeader)
        let authorization = normalizedToken(credentials.geminiAuthorizationHeader)
        let apiKey = normalizedToken(credentials.geminiAPIKey)

        var lines: [String] = []
        if !cookieHeader.isEmpty {
            lines.append("Cookie: \(cookieHeader)")
        }
        if !authorization.isEmpty {
            lines.append("Authorization: \(authorization)")
        }
        if !apiKey.isEmpty {
            lines.append("X-Goog-Api-Key: \(apiKey)")
        }
        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
    }
    if provider == .claude || provider == .codex {
        return normalizedToken(credentials.cookieHeader)
    }
    return ""
}

/// Returns true if the input looks like an authorization code/callback URL
/// but is NOT valid provider auth JSON (which should be parsed normally).
func looksLikeAuthorizationCodeNotJSON(_ raw: String, for provider: ProviderID) -> Bool {
    if provider == .codex, (try? CodexAuthJSONSupport.parseIfRawAuthJSON(raw)) != nil {
        return false
    }
    if provider == .gemini, (try? GeminiAuthJSONSupport.parseIfRawAuthJSON(raw)) != nil {
        return false
    }
    return looksLikeAuthorizationCodeInput(raw)
}

private func looksLikeAuthorizationCodeInput(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    if lower.contains("code=") { return true }
    if lower.contains("state=") { return true }
    if lower.contains("oauth/callback") { return true }
    if lower.contains("deviceauth/callback") { return true }
    if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("aiusage://") {
        return true
    }
    return false
}

// MARK: - Provider-specific parsers

private func parseClaudeCredentialsInput(_ raw: String) throws -> ProviderCredentials {
    let token = stripAuthorizationPrefix(from: raw)

    guard !token.isEmpty else {
        throw ClaudeTokenInputError.empty
    }

    let tokenLower = token.lowercased()
    if tokenLower.hasPrefix("sk-ant-oat") {
        return ProviderCredentials(accessToken: token)
    }

    if tokenLower.hasPrefix("sk-ant-api") {
        throw ClaudeTokenInputError.wrongTokenType
    }

    if let sessionKey = parseClaudeSessionKey(from: token) {
        return ProviderCredentials(accessToken: "", cookieHeader: "sessionKey=\(sessionKey)")
    }

    throw ClaudeTokenInputError.invalidFormat
}

private func parseGeminiCredentialsInput(_ raw: String) throws -> ProviderCredentials {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw GeminiTokenInputError.empty
    }

    if let studioHeaders = try parseGeminiStudioHeaders(from: trimmed) {
        return ProviderCredentials(
            accessToken: "",
            cookieHeader: studioHeaders.cookieHeader,
            geminiAuthorizationHeader: studioHeaders.authorization,
            geminiAPIKey: studioHeaders.apiKey
        )
    }

    return ProviderCredentials(accessToken: try parseGeminiAccessToken(trimmed))
}

private func parseGeminiAccessToken(_ raw: String) throws -> String {
    let token = stripAuthorizationPrefix(from: raw)
    guard !token.isEmpty else {
        throw GeminiTokenInputError.empty
    }

    if token.lowercased().hasPrefix("g.a000") {
        throw GeminiTokenInputError.cookieOnlyUnsupported
    }

    if token.hasPrefix("AIza") {
        throw GeminiTokenInputError.apiKeyUnsupported
    }

    if token.contains("=") || token.lowercased().contains("cookie:") {
        throw GeminiTokenInputError.invalidFormat
    }

    return token
}

private func parseCopilotAccessToken(_ raw: String) throws -> String {
    let token = stripAuthorizationPrefix(from: raw, allowTokenPrefix: true)
    guard !token.isEmpty else {
        throw CopilotTokenInputError.empty
    }

    let lower = token.lowercased()
    let knownPrefixes = ["ghp_", "ghu_", "gho_", "ghs_", "github_pat_"]
    if knownPrefixes.contains(where: { lower.hasPrefix($0) }) {
        return token
    }

    if token.contains("=") || token.contains(";") {
        throw CopilotTokenInputError.invalidFormat
    }

    if token.count >= 20, !token.contains(" ") {
        return token
    }

    throw CopilotTokenInputError.invalidFormat
}

private func parseKimiCredentialsInput(_ raw: String) throws -> ProviderCredentials {
    var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
        throw KimiTokenInputError.empty
    }

    if let cookieToken = parseCookieValue(named: "kimi-auth", from: token) {
        token = cookieToken
    } else {
        token = stripAuthorizationPrefix(from: token)
    }

    guard !token.isEmpty else {
        throw KimiTokenInputError.empty
    }

    if token.contains("=") || token.contains(";") {
        throw KimiTokenInputError.invalidFormat
    }

    return ProviderCredentials(accessToken: token)
}

// MARK: - Gemini Studio headers

private struct GeminiStudioHeaders {
    let cookieHeader: String
    let authorization: String
    let apiKey: String
}

private func parseGeminiStudioHeaders(from raw: String) throws -> GeminiStudioHeaders? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let lowered = trimmed.lowercased()
    let hasStudioSignal = lowered.contains("x-goog-api-key") ||
        lowered.contains("sapisidhash") ||
        lowered.contains("__secure-1psid") ||
        lowered.contains("cookie:")

    var cookieValue: String?
    var authorizationValue: String?
    var apiKeyValue: String?

    if trimmed.hasPrefix("{"),
       trimmed.hasSuffix("}"),
       let data = trimmed.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        cookieValue = firstNonEmptyString(
            in: json,
            keys: ["cookie", "cookieHeader", "Cookie"]
        )
        authorizationValue = firstNonEmptyString(
            in: json,
            keys: ["authorization", "Authorization", "authHeader", "auth"]
        )
        apiKeyValue = firstNonEmptyString(
            in: json,
            keys: ["x-goog-api-key", "xGoogApiKey", "apiKey", "api_key"]
        )
    }

    for rawLine in trimmed.split(whereSeparator: \.isNewline) {
        var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("-") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if line.hasPrefix("•") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let separator = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { continue }

        if key.hasPrefix("cookie") {
            cookieValue = value
        } else if key.hasPrefix("authorization") {
            authorizationValue = value
        } else if key.contains("x-goog-api-key") || key.contains("api key") || key.contains("api-key") {
            apiKeyValue = value
        }
    }

    if cookieValue == nil {
        cookieValue = extractGeminiHeaderValue(named: "cookie", from: trimmed)
    }
    if authorizationValue == nil {
        authorizationValue = extractGeminiHeaderValue(named: "authorization", from: trimmed)
    }
    if apiKeyValue == nil {
        apiKeyValue = extractGeminiHeaderValue(named: "x-goog-api-key", from: trimmed)
    }
    if authorizationValue == nil {
        authorizationValue = parseGeminiAuthorization(from: trimmed)
    }

    let studioAuthorizationPresent = authorizationValue?.lowercased().hasPrefix("sapisidhash ") == true
    if !hasStudioSignal && cookieValue == nil && apiKeyValue == nil && !studioAuthorizationPresent {
        return nil
    }

    let cookieHeader = normalizeGeminiCookieHeader(cookieValue)
    let authorization = authorizationValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiKey = apiKeyValue?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let cookieHeader, let authorization else {
        var missing: [String] = []
        if cookieHeader == nil { missing.append("Cookie") }
        if authorization == nil { missing.append("Authorization") }
        throw GeminiTokenInputError.missingStudioHeaders(missing: missing)
    }
    guard authorization.lowercased().hasPrefix("sapisidhash ") else {
        throw GeminiTokenInputError.invalidStudioAuthorization
    }

    return GeminiStudioHeaders(
        cookieHeader: cookieHeader,
        authorization: authorization,
        apiKey: apiKey ?? ""
    )
}

// MARK: - Generic helpers

private func stripAuthorizationPrefix(from raw: String, allowTokenPrefix: Bool = false) -> String {
    var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.lowercased().hasPrefix("authorization:") {
        token = String(token.dropFirst("authorization:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let lower = token.lowercased()
    if lower.hasPrefix("bearer ") {
        token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if allowTokenPrefix, lower.hasPrefix("token ") {
        token = String(token.dropFirst("token ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return token
}

private func parseCookieValue(named cookieName: String, from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let withoutPrefix: String = {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("cookie:") {
            return String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }()

    let expectedName = cookieName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !expectedName.isEmpty else { return nil }

    for pair in withoutPrefix.split(separator: ";") {
        let chunk = String(pair).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty, let separator = chunk.firstIndex(of: "=") else { continue }
        let name = String(chunk[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = chunk.index(after: separator)
        let value = String(chunk[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name == expectedName, !value.isEmpty {
            return value
        }
    }

    return nil
}

private func parseClaudeSessionKey(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if !trimmed.contains("="),
       trimmed.lowercased().hasPrefix("sk-ant-")
    {
        return trimmed
    }

    return parseCookieValue(named: "sessionKey", from: trimmed)
}

private func normalizeGeminiCookieHeader(_ rawValue: String?) -> String? {
    guard var cookie = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !cookie.isEmpty else {
        return nil
    }
    cookie = stripWrappingQuotes(from: cookie)

    if cookie.lowercased().hasPrefix("cookie:") {
        cookie = String(cookie.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if cookie.lowercased().hasPrefix("g.a000") {
        return "__Secure-1PSID=\(cookie)"
    }

    return cookie.contains("=") ? cookie : nil
}

private func parseGeminiAuthorization(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.lowercased().hasPrefix("sapisidhash ") {
        return trimmed
    }

    if let components = URLComponents(string: trimmed),
       let authValue = components.queryItems?.first(where: { $0.name.lowercased() == "auth" })?.value,
       let authorization = normalizeGeminiAuthQueryValue(authValue)
    {
        return authorization
    }

    if let authRange = trimmed.range(of: "auth=", options: [.caseInsensitive]) {
        let suffix = trimmed[authRange.upperBound...]
        let rawValue = String(suffix.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        if let authorization = normalizeGeminiAuthQueryValue(rawValue) {
            return authorization
        }
    }

    return nil
}

private func normalizeGeminiAuthQueryValue(_ value: String) -> String? {
    let plusExpanded = value.replacingOccurrences(of: "+", with: " ")
    let decoded = plusExpanded.removingPercentEncoding ?? plusExpanded
    let tokens = decoded
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    guard !tokens.isEmpty else { return nil }

    if let sapisidIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("SAPISIDHASH") == .orderedSame }),
       sapisidIndex + 1 < tokens.count
    {
        return "SAPISIDHASH \(tokens[sapisidIndex + 1])"
    }

    if decoded.lowercased().hasPrefix("sapisidhash ") {
        return decoded
    }

    return nil
}

private func extractGeminiHeaderValue(named headerName: String, from raw: String) -> String? {
    let escapedHeader = NSRegularExpression.escapedPattern(for: headerName)
    let pattern = "(?is)\\b\(escapedHeader)\\s*:\\s*(.+?)(?=(?:\\bcookie\\s*:|\\bauthorization\\s*:|\\bx-goog-api-key\\s*:|\\r?\\n|$))"
    guard let value = firstRegexCapture(pattern: pattern, in: raw) else {
        return nil
    }
    return stripWrappingQuotes(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func firstRegexCapture(pattern: String, in raw: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return nil
    }
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    guard let match = regex.firstMatch(in: raw, options: [], range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: raw)
    else {
        return nil
    }
    return String(raw[captureRange])
}

private func firstNonEmptyString(in json: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = json[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }
    return nil
}

private func stripWrappingQuotes(from raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
        return String(trimmed.dropFirst().dropLast())
    }
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
        return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
}

// MARK: - Raw JSON import support

private enum CodexAuthJSONSupport {
    static func parseIfRawAuthJSON(_ raw: String) throws -> ProviderCredentials? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return nil
        }
        return try parseRawAuthJSON(data: Data(trimmed.utf8))
    }

    private static func parseRawAuthJSON(data: Data) throws -> ProviderCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthJSONError.invalidJSON
        }

        let payload = (json["tokens"] as? [String: Any]) ?? json

        guard let accessToken = firstString(
            in: payload,
            keys: ["access_token", "accessToken", "token"]
        ) else {
            throw CodexAuthJSONError.missingAccessToken
        }

        let trimmedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccessToken.isEmpty else {
            throw CodexAuthJSONError.missingAccessToken
        }

        let refreshToken = firstString(
            in: payload,
            keys: ["refresh_token", "refreshToken"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = firstString(
            in: payload,
            keys: ["account_id", "accountId", "chatgpt_account_id"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ProviderCredentials(
            accessToken: trimmedAccessToken,
            refreshToken: (refreshToken?.isEmpty == false) ? refreshToken : nil,
            accountID: (accountID?.isEmpty == false) ? accountID : nil
        )
    }

    private static func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private enum GeminiAuthJSONSupport {
    static func parseIfRawAuthJSON(_ raw: String) throws -> ProviderCredentials? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return nil
        }
        return try parseRawAuthJSON(data: Data(trimmed.utf8))
    }

    private static func parseRawAuthJSON(data: Data) throws -> ProviderCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiAuthJSONError.invalidJSON
        }

        let payload = (json["tokens"] as? [String: Any]) ?? json
        guard let accessToken = firstString(
            in: payload,
            keys: ["access_token", "accessToken", "token"]
        ) else {
            throw GeminiAuthJSONError.missingAccessToken
        }

        let trimmedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccessToken.isEmpty else {
            throw GeminiAuthJSONError.missingAccessToken
        }

        let refreshToken = firstString(
            in: payload,
            keys: ["refresh_token", "refreshToken"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ProviderCredentials(
            accessToken: trimmedAccessToken,
            refreshToken: (refreshToken?.isEmpty == false) ? refreshToken : nil
        )
    }

    private static func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - Error types

private enum CodexAuthJSONError: LocalizedError {
    case invalidJSON
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Codex token JSON is not valid JSON."
        case .missingAccessToken:
            return "Codex JSON does not include an access token."
        }
    }
}

private enum GeminiAuthJSONError: LocalizedError {
    case invalidJSON
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Gemini token JSON is not valid JSON."
        case .missingAccessToken:
            return "Gemini JSON does not include an access token."
        }
    }
}

private enum ClaudeTokenInputError: LocalizedError {
    case empty
    case wrongTokenType
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Missing Claude token."
        case .wrongTokenType:
            return "Claude needs a Claude Code OAuth token (`sk-ant-oat...`), not an Anthropic API key."
        case .invalidFormat:
            return "Invalid Claude token format. Paste a Claude OAuth token (`sk-ant-oat...`) or `sessionKey` cookie."
        }
    }
}

private enum GeminiTokenInputError: LocalizedError {
    case empty
    case apiKeyUnsupported
    case cookieOnlyUnsupported
    case missingStudioHeaders(missing: [String])
    case invalidStudioAuthorization
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Missing Gemini token."
        case .apiKeyUnsupported:
            return "Gemini usage needs an OAuth access token, not an API key."
        case .cookieOnlyUnsupported:
            return "Detected a `__Secure-1PSID` value. Paste Cookie + Authorization (`SAPISIDHASH ...`) together."
        case let .missingStudioHeaders(missing):
            return "Missing Gemini Studio headers: \(missing.joined(separator: ", "))."
        case .invalidStudioAuthorization:
            return "Gemini Studio Authorization must start with `SAPISIDHASH`."
        case .invalidFormat:
            return "Invalid Gemini token format. Paste a bearer token (`ya29...`) or Cookie/Authorization/X-Goog-Api-Key headers."
        }
    }
}

private enum CopilotTokenInputError: LocalizedError {
    case empty
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Missing Copilot token."
        case .invalidFormat:
            return "Invalid Copilot token format. Paste a GitHub token."
        }
    }
}

private enum KimiTokenInputError: LocalizedError {
    case empty
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Missing Kimi token."
        case .invalidFormat:
            return "Invalid Kimi token format. Paste the `kimi-auth` value or cookie header."
        }
    }
}
