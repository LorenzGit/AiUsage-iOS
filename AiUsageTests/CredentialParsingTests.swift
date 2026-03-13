import Testing
@testable import AiUsage

@Suite("Credential Parsing")
struct CredentialParsingTests {

    // MARK: - normalizedToken

    @Test func normalizedToken_trimsWhitespace() {
        #expect(normalizedToken("  abc  ") == "abc")
        #expect(normalizedToken("\n\ttoken\n") == "token")
        #expect(normalizedToken(nil) == "")
        #expect(normalizedToken("") == "")
    }

    // MARK: - Codex

    @Test func codex_plainToken() throws {
        let creds = try parseCredentialsInput(for: .codex, input: "eyJhbGciOiJSUzI1NiI")
        #expect(creds.accessToken == "eyJhbGciOiJSUzI1NiI")
    }

    @Test func codex_jsonWithTokens() throws {
        let json = """
        {"access_token":"at123","refresh_token":"rt456","account_id":"acc789"}
        """
        let creds = try parseCredentialsInput(for: .codex, input: json)
        #expect(creds.accessToken == "at123")
        #expect(creds.refreshToken == "rt456")
        #expect(creds.accountID == "acc789")
    }

    @Test func codex_jsonNestedTokens() throws {
        let json = """
        {"tokens":{"accessToken":"at123","refreshToken":"rt456"}}
        """
        let creds = try parseCredentialsInput(for: .codex, input: json)
        #expect(creds.accessToken == "at123")
        #expect(creds.refreshToken == "rt456")
    }

    // MARK: - Claude

    @Test func claude_oauthToken() throws {
        let creds = try parseCredentialsInput(for: .claude, input: "sk-ant-oat01-abc123")
        #expect(creds.accessToken == "sk-ant-oat01-abc123")
        #expect(creds.cookieHeader == nil)
    }

    @Test func claude_oauthTokenWithBearerPrefix() throws {
        let creds = try parseCredentialsInput(for: .claude, input: "Bearer sk-ant-oat01-abc123")
        #expect(creds.accessToken == "sk-ant-oat01-abc123")
    }

    @Test func claude_sessionKeyCookie() throws {
        let creds = try parseCredentialsInput(for: .claude, input: "sessionKey=sk-ant-sid01-xyz")
        #expect(creds.accessToken == "")
        #expect(creds.cookieHeader == "sessionKey=sk-ant-sid01-xyz")
    }

    @Test func claude_bareSessionKey() throws {
        let creds = try parseCredentialsInput(for: .claude, input: "sk-ant-sid01-xyz")
        #expect(creds.accessToken == "")
        #expect(creds.cookieHeader == "sessionKey=sk-ant-sid01-xyz")
    }

    @Test func claude_apiKeyRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .claude, input: "sk-ant-api01-abc")
        }
    }

    @Test func claude_emptyRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .claude, input: "")
        }
    }

    // MARK: - Copilot

    @Test func copilot_ghpToken() throws {
        let creds = try parseCredentialsInput(for: .copilot, input: "ghp_abcdef1234567890abcd")
        #expect(creds.accessToken == "ghp_abcdef1234567890abcd")
    }

    @Test func copilot_githubPatToken() throws {
        let creds = try parseCredentialsInput(for: .copilot, input: "github_pat_abcdef1234567890abcd")
        #expect(creds.accessToken == "github_pat_abcdef1234567890abcd")
    }

    @Test func copilot_tokenPrefix() throws {
        let creds = try parseCredentialsInput(for: .copilot, input: "token ghp_abc123def456789012")
        #expect(creds.accessToken == "ghp_abc123def456789012")
    }

    @Test func copilot_shortTokenRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .copilot, input: "short")
        }
    }

    @Test func copilot_cookieRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .copilot, input: "session=abc;token=xyz")
        }
    }

    // MARK: - Kimi

    @Test func kimi_plainToken() throws {
        let creds = try parseCredentialsInput(for: .kimi, input: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        #expect(creds.accessToken == "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
    }

    @Test func kimi_cookieHeader() throws {
        let creds = try parseCredentialsInput(for: .kimi, input: "kimi-auth=eyJhbGciOiJIUzI1NiJ9")
        #expect(creds.accessToken == "eyJhbGciOiJIUzI1NiJ9")
    }

    @Test func kimi_bearerPrefix() throws {
        let creds = try parseCredentialsInput(for: .kimi, input: "Bearer eyJhbGciOiJIUzI1NiJ9")
        #expect(creds.accessToken == "eyJhbGciOiJIUzI1NiJ9")
    }

    @Test func kimi_emptyRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .kimi, input: "")
        }
    }

    // MARK: - Gemini

    @Test func gemini_bearerToken() throws {
        let creds = try parseCredentialsInput(for: .gemini, input: "ya29.a0AfH6SMBabcdef")
        #expect(creds.accessToken == "ya29.a0AfH6SMBabcdef")
    }

    @Test func gemini_bearerPrefix() throws {
        let creds = try parseCredentialsInput(for: .gemini, input: "Bearer ya29.a0AfH6SMBabcdef")
        #expect(creds.accessToken == "ya29.a0AfH6SMBabcdef")
    }

    @Test func gemini_apiKeyRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .gemini, input: "AIzaSyD-something")
        }
    }

    @Test func gemini_cookieOnlyRejected() {
        #expect(throws: (any Error).self) {
            try parseCredentialsInput(for: .gemini, input: "g.a000abc123")
        }
    }

    @Test func gemini_studioHeaders() throws {
        let input = """
        Cookie: __Secure-1PSID=abc123; other=val
        Authorization: SAPISIDHASH 1234567890_abcdef
        X-Goog-Api-Key: AIzaSyD-test
        """
        let creds = try parseCredentialsInput(for: .gemini, input: input)
        #expect(creds.accessToken == "")
        #expect(creds.cookieHeader?.contains("__Secure-1PSID") == true)
        #expect(creds.geminiAuthorizationHeader?.hasPrefix("SAPISIDHASH") == true)
        #expect(creds.geminiAPIKey == "AIzaSyD-test")
    }

    @Test func gemini_studioJSON() throws {
        let input = """
        {"cookie":"__Secure-1PSID=abc","authorization":"SAPISIDHASH 12345","x-goog-api-key":"AIzaSyD-test"}
        """
        let creds = try parseCredentialsInput(for: .gemini, input: input)
        #expect(creds.accessToken == "")
        #expect(creds.geminiAuthorizationHeader?.hasPrefix("SAPISIDHASH") == true)
    }

    @Test func gemini_jsonAuthTokens() throws {
        let json = """
        {"access_token":"ya29.test","refresh_token":"1//refresh"}
        """
        let creds = try parseCredentialsInput(for: .gemini, input: json)
        #expect(creds.accessToken == "ya29.test")
        #expect(creds.refreshToken == "1//refresh")
    }

    // MARK: - displayToken

    @Test func displayToken_prefersAccessToken() {
        let creds = ProviderCredentials(accessToken: "tok123", cookieHeader: "cookie=val")
        #expect(displayToken(for: .codex, credentials: creds) == "tok123")
    }

    @Test func displayToken_fallsThroughToCookie() {
        let creds = ProviderCredentials(accessToken: "", cookieHeader: "sessionKey=sk-ant-123")
        #expect(displayToken(for: .claude, credentials: creds) == "sessionKey=sk-ant-123")
    }

    @Test func displayToken_geminiStudioHeaders() {
        let creds = ProviderCredentials(
            accessToken: "",
            cookieHeader: "__Secure-1PSID=abc",
            geminiAuthorizationHeader: "SAPISIDHASH 123",
            geminiAPIKey: "AIzaSyD-test"
        )
        let result = displayToken(for: .gemini, credentials: creds)
        #expect(result.contains("Cookie:"))
        #expect(result.contains("Authorization:"))
        #expect(result.contains("X-Goog-Api-Key:"))
    }

    // MARK: - looksLikeAuthorizationCodeNotJSON

    @Test func authCodeDetection_callbackURL() {
        #expect(looksLikeAuthorizationCodeNotJSON("http://localhost:1455/auth/callback?code=abc&state=xyz", for: .codex))
    }

    @Test func authCodeDetection_plainJSON() {
        let json = """
        {"access_token":"tok","refresh_token":"ref"}
        """
        #expect(!looksLikeAuthorizationCodeNotJSON(json, for: .codex))
    }

    @Test func authCodeDetection_plainToken() {
        #expect(!looksLikeAuthorizationCodeNotJSON("eyJhbGciOiJSUzI1NiI", for: .codex))
    }
}
