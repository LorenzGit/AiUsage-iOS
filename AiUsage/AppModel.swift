import Foundation
import Combine

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var useMockData = false
    @Published var debugShowDisconnectedProviderUI = false
    @Published var providerOrder: [ProviderID] = ProviderID.allCases
    @Published var widgetVisibility: [ProviderID: Bool] = [:]
    @Published var tokenDrafts: [ProviderID: String] = [:]
    @Published private(set) var savedTokens: [ProviderID: String] = [:]
    @Published var snapshots: [ProviderID: ProviderUsageSnapshot] = [:]
    @Published var errors: [ProviderID: String] = [:]
    @Published var loadingProviders: Set<ProviderID> = []
    @Published var codexLoginState: CodexLoginState?
    @Published var geminiLoginState: GeminiLoginState?

    private let credentialsStore = CredentialsStore()
    private let codexAuthService = CodexDeviceAuthService()
    private let geminiAuthService = GeminiDeviceAuthService()
    private let codexTokenRefresher = CodexTokenRefresher()
    private let geminiTokenRefresher = GeminiTokenRefresher()
    private let mockModeDefaultsKey = "aiusage.mock_mode_enabled"
    private let debugDisconnectedUIDefaultsKey = "aiusage.debug_show_disconnected_provider_ui"
    private var codexManualAuthSession: CodexManualAuthSession?
    private var geminiManualAuthSession: GeminiManualAuthSession?
    private var geminiLastRefreshAt: Date?
    private var geminiLastRefreshedAccessToken: String?

    private var clients: [ProviderID: any ProviderAPIClient] = {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderAPIClientFactory.client(for: $0)) })
    }()

    /// Loads persisted credentials and fetches provider usage when mock mode is off.
    func load() async {
        useMockData = UserDefaults.standard.bool(forKey: mockModeDefaultsKey)
        debugShowDisconnectedProviderUI = UserDefaults.standard.bool(forKey: debugDisconnectedUIDefaultsKey)
        providerOrder = ProviderOrderStore.load()
        widgetVisibility = ProviderWidgetVisibilityStore.load()

        for provider in ProviderID.allCases {
            let credentials = credentialsStore.load(for: provider)
            let token = credentials.map { displayToken(for: provider, credentials: $0) } ?? ""
            tokenDrafts[provider] = token
            savedTokens[provider] = token
        }

        if useMockData {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        await refreshAll()
    }

    func setDebugShowDisconnectedProviderUI(_ isEnabled: Bool) {
        debugShowDisconnectedProviderUI = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: debugDisconnectedUIDefaultsKey)
    }

    /// Persists the token draft for a provider and refreshes its usage data.
    func saveToken(for provider: ProviderID) async {
        let trimmed = normalizedToken(tokenDrafts[provider])

        if provider == .codex,
           looksLikeCodexAuthorizationCodeInput(trimmed),
           (try? CodexAuthJSONSupport.parseIfRawAuthJSON(trimmed)) == nil
        {
            if codexManualAuthSession != nil {
                errors[.codex] = "That looks like an auth code/callback URL. Paste it, then press return to exchange."
            } else {
                errors[.codex] = "That looks like a callback URL, but the sign-in session has expired. Tap Sign in again."
            }
            return
        }
        if provider == .gemini,
           looksLikeCodexAuthorizationCodeInput(trimmed),
           (try? GeminiAuthJSONSupport.parseIfRawAuthJSON(trimmed)) == nil
        {
            if geminiManualAuthSession != nil {
                errors[.gemini] = "That looks like an auth code/callback URL. Paste it, then press return to exchange."
            } else {
                errors[.gemini] = "That looks like a callback URL, but the sign-in session has expired. Tap Sign in again."
            }
            return
        }

        do {
            if trimmed.isEmpty {
                try credentialsStore.delete(for: provider)
                snapshots.removeValue(forKey: provider)
                errors[provider] = nil
                savedTokens[provider] = ""
            } else {
                let credentials = try parseCredentialsInput(for: provider, input: trimmed)
                try credentialsStore.save(credentials, for: provider)
                let displayToken = displayToken(for: provider, credentials: credentials)
                tokenDrafts[provider] = displayToken
                savedTokens[provider] = displayToken
                await refresh(provider)
            }
        } catch {
            errors[provider] = error.localizedDescription
        }

        persistWidgetSnapshot()
    }

    /// Refreshes all authenticated providers in parallel.
    func refreshAll() async {
        if useMockData {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        let providersToRefresh = providerOrder.filter { hasToken(for: $0) }
        guard !providersToRefresh.isEmpty else {
            snapshots = [:]
            errors = [:]
            persistWidgetSnapshot()
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for provider in providersToRefresh {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.refresh(provider)
                }
            }
        }

        persistWidgetSnapshot()
    }

    /// Refreshes one provider and updates loading/error state.
    func refresh(_ provider: ProviderID) async {
        if useMockData {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        guard hasToken(for: provider) else {
            snapshots.removeValue(forKey: provider)
            errors[provider] = nil
            persistWidgetSnapshot()
            return
        }

        loadingProviders.insert(provider)
        defer { loadingProviders.remove(provider) }

        do {
            let credentials = try await resolveCredentials(for: provider)
            let snapshot = try await fetchUsage(for: provider, credentials: credentials)
            snapshots[provider] = snapshot
            errors[provider] = nil
        } catch {
            // Avoid showing stale usage when a refresh/fetch fails.
            snapshots.removeValue(forKey: provider)
            errors[provider] = error.localizedDescription
        }
    }

    /// Starts manual Codex login by generating a PKCE authorization URL.
    func prepareCodexLoginLink() async {
        codexLoginState = CodexLoginState(
            isWorking: true,
            message: "Generating browser auth URL..."
        )

        do {
            let session = try codexAuthService.makeManualAuthSession()
            codexManualAuthSession = session
            codexLoginState = CodexLoginState(
                isWorking: false,
                message: "Open link in browser, finish login, then copy the final redirected URL (it may be a localhost page), paste it here, and press return.",
                userCode: nil,
                verificationURI: session.authorizationURL.absoluteString
            )
            errors[.codex] = nil
        } catch {
            codexManualAuthSession = nil
            codexLoginState = CodexLoginState(
                isWorking: false,
                message: "Could not generate login link: \(error.localizedDescription)",
                userCode: nil,
                verificationURI: nil
            )
            errors[.codex] = error.localizedDescription
        }
    }

    /// Exchanges a pasted callback URL or code for Codex access/refresh tokens.
    func exchangeCodexAuthorizationCodeFromDraft() async {
        let rawInput = normalizedToken(tokenDrafts[.codex])
        guard !rawInput.isEmpty else {
            errors[.codex] = "Paste the returned authorization code or callback URL first."
            return
        }
        if rawInput.lowercased().hasPrefix("<!doctype") || rawInput.lowercased().hasPrefix("<html") {
            errors[.codex] = "You pasted HTML. Paste the browser callback URL (or code), not page source."
            return
        }
        guard let session = codexManualAuthSession else {
            errors[.codex] = "Generate login URL first."
            return
        }

        if let returnedState = extractAuthorizationState(from: rawInput),
           !returnedState.isEmpty,
           returnedState != session.state
        {
            errors[.codex] = "Auth state mismatch. Generate a new login link and try again."
            return
        }

        let code = extractAuthorizationCode(from: rawInput)
        guard !code.isEmpty else {
            errors[.codex] = "Could not find an authorization code. Paste the full callback URL or raw code."
            return
        }

        codexLoginState = CodexLoginState(
            isWorking: true,
            message: "Exchanging code for token..."
        )

        do {
            let tokens = try await codexAuthService.exchangeManualAuthorizationCode(
                code: code,
                codeVerifier: session.codeVerifier,
                redirectURI: session.redirectURI
            )

            let existing = credentialsStore.load(for: .codex)
            let merged = ProviderCredentials(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                accountID: tokens.accountID,
                cookieHeader: existing?.cookieHeader
            )

            try credentialsStore.save(merged, for: .codex)
            tokenDrafts[.codex] = merged.accessToken
            savedTokens[.codex] = merged.accessToken
            codexManualAuthSession = nil
            errors[.codex] = nil
            codexLoginState = CodexLoginState(
                isWorking: false,
                message: "Signed in."
            )

            await refresh(.codex)
            persistWidgetSnapshot()
        } catch {
            errors[.codex] = error.localizedDescription
            codexLoginState = CodexLoginState(
                isWorking: false,
                message: "Code exchange failed: \(error.localizedDescription)",
                userCode: nil,
                verificationURI: session.authorizationURL.absoluteString
            )
        }
    }

    func hasPendingCodexAuthURL() -> Bool {
        codexManualAuthSession != nil
    }

    /// Starts manual Gemini login by generating a PKCE authorization URL.
    func prepareGeminiLoginLink() async {
        geminiLoginState = GeminiLoginState(
            isWorking: true,
            message: "Generating browser auth URL..."
        )

        do {
            let session = try geminiAuthService.makeManualAuthSession()
            geminiManualAuthSession = session
            geminiLoginState = GeminiLoginState(
                isWorking: false,
                message: "Open link in browser, finish login, then copy the final redirected URL (it may be a localhost page), paste it here, and press return.",
                verificationURI: session.authorizationURL.absoluteString
            )
            errors[.gemini] = nil
        } catch {
            geminiManualAuthSession = nil
            geminiLoginState = GeminiLoginState(
                isWorking: false,
                message: "Could not generate login link: \(error.localizedDescription)",
                verificationURI: nil
            )
            errors[.gemini] = error.localizedDescription
        }
    }

    /// Exchanges a pasted callback URL or code for Gemini access/refresh tokens.
    func exchangeGeminiAuthorizationCodeFromDraft() async {
        let rawInput = normalizedToken(tokenDrafts[.gemini])
        guard !rawInput.isEmpty else {
            errors[.gemini] = "Paste the returned authorization code or callback URL first."
            return
        }
        if rawInput.lowercased().hasPrefix("<!doctype") || rawInput.lowercased().hasPrefix("<html") {
            errors[.gemini] = "You pasted HTML. Paste the browser callback URL (or code), not page source."
            return
        }
        guard let session = geminiManualAuthSession else {
            errors[.gemini] = "Generate login URL first."
            return
        }

        if let returnedState = extractAuthorizationState(from: rawInput),
           !returnedState.isEmpty,
           returnedState != session.state
        {
            errors[.gemini] = "Auth state mismatch. Generate a new login link and try again."
            return
        }

        let code = extractAuthorizationCode(from: rawInput)
        guard !code.isEmpty else {
            errors[.gemini] = "Could not find an authorization code. Paste the full callback URL or raw code."
            return
        }

        geminiLoginState = GeminiLoginState(
            isWorking: true,
            message: "Exchanging code for token..."
        )

        do {
            let tokens = try await geminiAuthService.exchangeManualAuthorizationCode(
                code: code,
                codeVerifier: session.codeVerifier,
                redirectURI: session.redirectURI
            )

            let existing = credentialsStore.load(for: .gemini)
            let resolvedRefreshToken = normalizedToken(tokens.refreshToken ?? existing?.refreshToken)
            guard !resolvedRefreshToken.isEmpty else {
                throw GeminiOAuthSignInError.missingRefreshToken
            }
            let merged = ProviderCredentials(
                accessToken: tokens.accessToken,
                refreshToken: resolvedRefreshToken,
                accountID: existing?.accountID,
                cookieHeader: existing?.cookieHeader,
                geminiAuthorizationHeader: existing?.geminiAuthorizationHeader,
                geminiAPIKey: existing?.geminiAPIKey
            )

            try credentialsStore.save(merged, for: .gemini)
            tokenDrafts[.gemini] = merged.accessToken
            savedTokens[.gemini] = merged.accessToken
            geminiLastRefreshAt = Date()
            geminiLastRefreshedAccessToken = merged.accessToken
            geminiManualAuthSession = nil
            errors[.gemini] = nil
            geminiLoginState = GeminiLoginState(
                isWorking: false,
                message: "Signed in."
            )

            await refresh(.gemini)
            persistWidgetSnapshot()
        } catch {
            errors[.gemini] = error.localizedDescription
            geminiLoginState = GeminiLoginState(
                isWorking: false,
                message: "Code exchange failed: \(error.localizedDescription)",
                verificationURI: session.authorizationURL.absoluteString
            )
        }
    }

    func hasPendingGeminiAuthURL() -> Bool {
        geminiManualAuthSession != nil
    }

    /// Clears local Codex credentials and usage state.
    func disconnectCodex() async {
        codexManualAuthSession = nil
        codexLoginState = nil

        do {
            try credentialsStore.delete(for: .codex)
            tokenDrafts[.codex] = ""
            savedTokens[.codex] = ""
            snapshots.removeValue(forKey: .codex)
            errors[.codex] = nil
            persistWidgetSnapshot()
        } catch {
            errors[.codex] = error.localizedDescription
        }
    }

    /// Clears local Gemini credentials and usage state.
    func disconnectGemini() async {
        geminiManualAuthSession = nil
        geminiLoginState = nil
        geminiLastRefreshAt = nil
        geminiLastRefreshedAccessToken = nil

        do {
            try credentialsStore.delete(for: .gemini)
            tokenDrafts[.gemini] = ""
            savedTokens[.gemini] = ""
            snapshots.removeValue(forKey: .gemini)
            errors[.gemini] = nil
            persistWidgetSnapshot()
        } catch {
            errors[.gemini] = error.localizedDescription
        }
    }

    /// Toggles mock mode and refreshes snapshots accordingly.
    func setMockDataEnabled(_ isEnabled: Bool) async {
        useMockData = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: mockModeDefaultsKey)

        if isEnabled {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        snapshots = [:]
        errors = [:]
        await refreshAll()
    }

    /// Refreshes data when app returns to foreground.
    func refreshAllIfNeeded() async {
        guard useMockData || hasAnyToken() else { return }
        await refreshAll()
    }

    func hasToken(for provider: ProviderID) -> Bool {
        guard let stored = credentialsStore.load(for: provider) else { return false }
        if provider == .codex || provider == .claude {
            return !normalizedToken(stored.accessToken).isEmpty || !normalizedToken(stored.cookieHeader).isEmpty
        }
        if provider == .gemini {
            let hasBearerToken = !normalizedToken(stored.accessToken).isEmpty
            let hasStudioHeaders = !normalizedToken(stored.cookieHeader).isEmpty &&
                !normalizedToken(stored.geminiAuthorizationHeader).isEmpty
            return hasBearerToken || hasStudioHeaders
        }
        return !normalizedToken(stored.accessToken).isEmpty
    }

    func hasAnyToken() -> Bool {
        ProviderID.allCases.contains { hasToken(for: $0) }
    }

    func isTokenModified(for provider: ProviderID) -> Bool {
        normalizedToken(tokenDrafts[provider]) != normalizedToken(savedTokens[provider])
    }

    func moveProviders(fromOffsets: IndexSet, toOffset: Int) {
        let sourceIndices = fromOffsets.sorted()
        guard !sourceIndices.isEmpty else { return }

        let movingProviders = sourceIndices.map { providerOrder[$0] }
        for index in sourceIndices.reversed() {
            providerOrder.remove(at: index)
        }

        let adjustedDestination = sourceIndices.reduce(toOffset) { current, index in
            index < toOffset ? current - 1 : current
        }
        let insertionIndex = max(0, min(adjustedDestination, providerOrder.count))
        providerOrder.insert(contentsOf: movingProviders, at: insertionIndex)
        providerOrder = ProviderOrderStore.normalized(providerOrder)
        ProviderOrderStore.save(providerOrder)
        persistWidgetSnapshot()
    }

    func isProviderVisibleInWidget(_ provider: ProviderID) -> Bool {
        widgetVisibility[provider] ?? true
    }

    func setProviderVisibleInWidget(_ provider: ProviderID, isVisible: Bool) {
        widgetVisibility[provider] = isVisible
        ProviderWidgetVisibilityStore.save(widgetVisibility)
        persistWidgetSnapshot()
    }

    private func resolveCredentials(for provider: ProviderID) async throws -> ProviderCredentials {
        let draft = normalizedToken(tokenDrafts[provider])

        if !draft.isEmpty {
            let parsed = try parseCredentialsInput(for: provider, input: draft)
            if provider == .codex,
               let enriched = loadCodexCredentialsMatchingAccessToken(parsed.accessToken)
            {
                return enriched
            }
            if provider == .gemini,
               let enriched = loadGeminiCredentialsMatchingAccessToken(parsed.accessToken)
            {
                return enriched
            }
            return parsed
        }

        if let stored = credentialsStore.load(for: provider) {
            return stored
        }

        throw ProviderFetchError.missingToken
    }

    private func fetchUsage(for provider: ProviderID, credentials: ProviderCredentials) async throws
        -> ProviderUsageSnapshot
    {
        guard let client = clients[provider] else {
            throw ProviderFetchError.notSupported(message: "No API client for \(provider.displayName).")
        }

        let effectiveCredentials: ProviderCredentials
        if provider == .gemini {
            effectiveCredentials = try await refreshGeminiCredentialsProactivelyIfPossible(from: credentials)
        } else {
            effectiveCredentials = credentials
        }

        do {
            return try await client.fetchUsage(using: effectiveCredentials)
        } catch {
            guard isUnauthorized(error),
                  let refreshed = try await refreshCredentialsIfPossible(for: provider, from: effectiveCredentials)
            else {
                throw error
            }

            return try await client.fetchUsage(using: refreshed)
        }
    }

    private func refreshCredentialsIfPossible(
        for provider: ProviderID,
        from credentials: ProviderCredentials
    ) async throws -> ProviderCredentials? {
        switch provider {
        case .codex:
            return try await refreshCodexCredentialsIfPossible(from: credentials)
        case .gemini:
            return try await refreshGeminiCredentialsIfPossible(from: credentials)
        case .claude, .copilot, .kimi:
            return nil
        }
    }

    /// Refreshes Gemini access token before requests to avoid user-visible 401 churn.
    private func refreshGeminiCredentialsProactivelyIfPossible(from credentials: ProviderCredentials) async throws
        -> ProviderCredentials
    {
        let refreshToken = normalizedToken(credentials.refreshToken)
        let accessToken = normalizedToken(credentials.accessToken)
        guard !refreshToken.isEmpty, !accessToken.isEmpty else {
            return credentials
        }

        let shouldRefresh: Bool = {
            guard let lastRefresh = geminiLastRefreshAt else { return true }
            guard geminiLastRefreshedAccessToken == accessToken else { return true }
            return Date().timeIntervalSince(lastRefresh) >= (50 * 60)
        }()
        guard shouldRefresh else {
            return credentials
        }

        do {
            guard let refreshed = try await refreshGeminiCredentialsIfPossible(from: credentials) else {
                return credentials
            }
            geminiLastRefreshAt = Date()
            geminiLastRefreshedAccessToken = normalizedToken(refreshed.accessToken)
            return refreshed
        } catch GeminiTokenRefreshError.revoked {
            // If refresh is revoked, surface the error so UI can prompt re-auth.
            throw GeminiTokenRefreshError.revoked
        } catch {
            // Best effort: if proactive refresh fails, continue with current token and let normal retry logic handle it.
            return credentials
        }
    }

    /// Refreshes Codex tokens when the access token is unauthorized.
    private func refreshCodexCredentialsIfPossible(from credentials: ProviderCredentials) async throws
        -> ProviderCredentials?
    {
        let refreshToken = normalizedToken(credentials.refreshToken)
        guard !refreshToken.isEmpty else { return nil }

        let refreshed = try await codexTokenRefresher.refresh(credentials)
        let merged = ProviderCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            accountID: refreshed.accountID,
            cookieHeader: credentials.cookieHeader
        )

        try credentialsStore.save(merged, for: .codex)
        tokenDrafts[.codex] = merged.accessToken
        savedTokens[.codex] = merged.accessToken
        return merged
    }

    /// Refreshes Gemini OAuth tokens when the access token is unauthorized.
    private func refreshGeminiCredentialsIfPossible(from credentials: ProviderCredentials) async throws
        -> ProviderCredentials?
    {
        let refreshToken = normalizedToken(credentials.refreshToken)
        guard !refreshToken.isEmpty else { return nil }

        let refreshed = try await geminiTokenRefresher.refresh(credentials)
        let merged = ProviderCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            accountID: refreshed.accountID,
            cookieHeader: credentials.cookieHeader,
            geminiAuthorizationHeader: credentials.geminiAuthorizationHeader,
            geminiAPIKey: credentials.geminiAPIKey
        )

        try credentialsStore.save(merged, for: .gemini)
        let displayToken = displayToken(for: .gemini, credentials: merged)
        tokenDrafts[.gemini] = displayToken
        savedTokens[.gemini] = displayToken
        geminiLastRefreshAt = Date()
        geminiLastRefreshedAccessToken = normalizedToken(merged.accessToken)
        return merged
    }

    private func loadCodexCredentialsMatchingAccessToken(_ accessToken: String) -> ProviderCredentials? {
        let normalizedAccessToken = normalizedToken(accessToken)
        guard !normalizedAccessToken.isEmpty else { return nil }

        if let stored = credentialsStore.load(for: .codex),
           normalizedToken(stored.accessToken) == normalizedAccessToken
        {
            return stored
        }

        return nil
    }

    private func loadGeminiCredentialsMatchingAccessToken(_ accessToken: String) -> ProviderCredentials? {
        let normalizedAccessToken = normalizedToken(accessToken)
        guard !normalizedAccessToken.isEmpty else { return nil }

        guard let stored = credentialsStore.load(for: .gemini) else { return nil }
        guard normalizedToken(stored.accessToken) == normalizedAccessToken else { return nil }

        // Keep persisted refresh token and optional Studio headers when the draft
        // only contains the visible access token value.
        return stored
    }

    private func parseCredentialsInput(for provider: ProviderID, input: String) throws -> ProviderCredentials {
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

    private func displayToken(for provider: ProviderID, credentials: ProviderCredentials) -> String {
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

    /// Writes snapshots for the widget extension and triggers a timeline reload.
    private func persistWidgetSnapshot() {
        let items = providerOrder.compactMap { snapshots[$0] }
        let snapshot = WidgetSnapshot(generatedAt: Date(), isMockData: useMockData, providers: items)
        WidgetSnapshotStore.save(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func applyMockSnapshots() {
        let snapshot = MockSnapshotCycle.next()
        snapshots = Dictionary(uniqueKeysWithValues: snapshot.providers.map { provider in
            (provider.provider, provider)
        })
        errors = [:]
    }

    private func normalizedToken(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderFetchError else { return false }
        if case .unauthorized = providerError {
            return true
        }
        return false
    }

    private func extractAuthorizationCode(from raw: String) -> String {
        if let url = URL(string: raw),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty
        {
            return code
        }

        if let queryRange = raw.range(of: "code=") {
            let suffix = raw[queryRange.upperBound...]
            let code = suffix.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: true).first
            if let code, !code.isEmpty {
                let rawCode = String(code)
                return rawCode.removingPercentEncoding ?? rawCode
            }
        }

        return raw
    }

    private func extractAuthorizationState(from raw: String) -> String? {
        if let url = URL(string: raw),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
           !state.isEmpty
        {
            return state
        }

        if let queryRange = raw.range(of: "state=") {
            let suffix = raw[queryRange.upperBound...]
            let state = suffix.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: true).first
            if let state, !state.isEmpty {
                let rawState = String(state)
                return rawState.removingPercentEncoding ?? rawState
            }
        }

        return nil
    }

    private func looksLikeCodexAuthorizationCodeInput(_ raw: String) -> Bool {
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
}

struct CodexLoginState {
    var isWorking: Bool
    var message: String
    var userCode: String? = nil
    var verificationURI: String? = nil
}

struct GeminiLoginState {
    var isWorking: Bool
    var message: String
    var verificationURI: String? = nil
}

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

/// Supports pasting raw auth JSON exported by CLI or scripts.
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

/// Supports pasting raw Gemini OAuth JSON from scripts.
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

private enum GeminiOAuthSignInError: LocalizedError {
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Google sign-in returned no refresh token. Revoke this app in your Google account, then sign in again."
        }
    }
}
