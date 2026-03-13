import Foundation

extension AppModel {

    func resolveCredentials(for provider: ProviderID) async throws -> ProviderCredentials {
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

    func fetchUsage(for provider: ProviderID, credentials: ProviderCredentials) async throws
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

    // MARK: - Token refresh

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
            throw GeminiTokenRefreshError.revoked
        } catch {
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
        let display = displayToken(for: .gemini, credentials: merged)
        tokenDrafts[.gemini] = display
        savedTokens[.gemini] = display
        geminiLastRefreshAt = Date()
        geminiLastRefreshedAccessToken = normalizedToken(merged.accessToken)
        return merged
    }

    // MARK: - Credential lookup

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

        return stored
    }

    // MARK: - Helpers

    private func isUnauthorized(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderFetchError else { return false }
        if case .unauthorized = providerError {
            return true
        }
        return false
    }
}
