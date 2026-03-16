import Foundation

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
