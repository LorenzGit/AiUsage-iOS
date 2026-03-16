import Foundation

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

enum GeminiOAuthSignInError: LocalizedError {
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Google sign-in returned no refresh token. Revoke this app in your Google account, then sign in again."
        }
    }
}

extension AppModel {

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
}

// MARK: - Authorization code helpers

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
