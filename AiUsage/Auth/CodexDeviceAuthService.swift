import Foundation
#if canImport(CryptoKit)
import CryptoKit
import CommonCrypto
#endif

struct CodexDeviceAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String?
    let accountID: String?
}

struct CodexManualAuthSession: Sendable {
    let authorizationURL: URL
    let codeVerifier: String
    let redirectURI: String
    let state: String
}

enum CodexDeviceAuthError: LocalizedError {
    case invalidResponse
    case unsupported(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Codex login."
        case let .unsupported(reason):
            return reason
        case let .server(message):
            return message
        }
    }
}

struct Config: Codable {
    let gc: String
    let gcs: String
    let cx: String
}

func getConfig() -> Config? {
    guard let configData = Bundle.main.object(forInfoDictionaryKey: "ConfigData") as? String,
          let data = Data(base64Encoded: configData),
          let decrypted = decryptAES256(data: data, seed: "AI_Usage-iOS26*"),
          let config = try? JSONDecoder().decode(Config.self, from: decrypted) else {
        return nil
    }
    return config
}

func decryptAES256(data: Data, seed: String) -> Data? {
    var keyIV = Data(count: 48) // 32 key + 16 IV
    let status = keyIV.withUnsafeMutableBytes { keyIVBytes in
        seed.data(using: .utf8)!.withUnsafeBytes { pwBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                seed.count,
                nil, 0,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                10000,
                keyIVBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                48
            )
        }
    }
    
    guard status == kCCSuccess else { return nil }
    
    let bufferSize = data.count + kCCBlockSizeAES128
    var buffer = Data(count: bufferSize)
    var numBytesDecrypted = 0
    
    let cryptStatus = keyIV.withUnsafeBytes { keyIVBytes in
        data.withUnsafeBytes { dataBytes in
            buffer.withUnsafeMutableBytes { bufferBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyIVBytes.baseAddress,
                    32,
                    keyIVBytes.baseAddress?.advanced(by: 32),
                    dataBytes.baseAddress,
                    data.count,
                    bufferBytes.baseAddress,
                    bufferSize,
                    &numBytesDecrypted
                )
            }
        }
    }
    
    guard cryptStatus == kCCSuccess else { return nil }
    return buffer.prefix(numBytesDecrypted)
}

/// Handles Codex OAuth PKCE flows used by Settings > Sign in.
struct CodexDeviceAuthService: Sendable {
    private let issuerBaseURL = URL(string: "https://auth.openai.com")!
    private var config: Config? { getConfig() }
    private var cx: String? { config?.cx }
    private var gc: String? { config?.gc }
    private var gcs: String? { config?.gcs }
    private let scope = "openid profile email offline_access"
    // Browser can fail to open localhost on iOS; user still pastes the final redirect URL.
    private let manualRedirectURI = "http://localhost:1455/auth/callback"

    /// Builds the browser URL for manual authorization with state + PKCE challenge.
    func makeManualAuthSession() throws -> CodexManualAuthSession {
        #if canImport(CryptoKit)
        let state = randomBase64URLString(length: 32)
        let codeVerifier = randomBase64URLString(length: 64)
        let codeChallenge = sha256Base64URL(codeVerifier)

        let authorizationEndpoint = issuerBaseURL.appendingPathComponent("oauth/authorize")
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: gc),
            URLQueryItem(name: "redirect_uri", value: manualRedirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authorizationURL = components?.url else {
            throw CodexDeviceAuthError.invalidResponse
        }

        return CodexManualAuthSession(
            authorizationURL: authorizationURL,
            codeVerifier: codeVerifier,
            redirectURI: manualRedirectURI,
            state: state
        )
        #else
        throw CodexDeviceAuthError.unsupported("CryptoKit is required for Codex OAuth sign-in.")
        #endif
    }

    /// Exchanges the OAuth authorization code for access/refresh tokens.
    func exchangeManualAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> CodexDeviceAuthTokens {
        let tokenEndpoint = issuerBaseURL.appendingPathComponent("oauth/token")
        let params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": gcs ?? "",
            "code_verifier": codeVerifier,
        ]

        let (data, response) = try await sendWithFallback(
            url: tokenEndpoint,
            postForm: params,
            postJSON: params,
            fallbackMessage: "Token exchange failed."
        )
        guard (200...299).contains(response.statusCode) else {
            throw decodeOAuthError(from: data, fallback: "Token exchange failed (HTTP \(response.statusCode)).")
        }

        let token = try parseOAuthTokenResponse(from: data)
        return CodexDeviceAuthTokens(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            accountID: parseChatGPTAccountID(fromIDToken: token.idToken)
        )
    }

    private func sendWithFallback(
        url: URL,
        postForm: [String: String],
        postJSON: [String: String],
        fallbackMessage: String
    ) async throws -> (Data, HTTPURLResponse) {
        let attempts = try buildRequests(url: url, postForm: postForm, postJSON: postJSON)
        var lastError: CodexDeviceAuthError?

        for request in attempts {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try requireHTTP(response)

            // Some auth stacks only accept one body format.
            if http.statusCode == 405 || http.statusCode == 415 {
                lastError = decodeOAuthError(
                    from: data,
                    fallback: "\(fallbackMessage) (HTTP \(http.statusCode))."
                )
                continue
            }

            return (data, http)
        }

        throw lastError ?? CodexDeviceAuthError.server(fallbackMessage)
    }

    private func buildRequests(
        url: URL,
        postForm: [String: String],
        postJSON: [String: String]
    ) throws -> [URLRequest] {
        var requests: [URLRequest] = []

        var formRequest = URLRequest(url: url)
        formRequest.httpMethod = "POST"
        formRequest.timeoutInterval = 30
        formRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        formRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        formRequest.httpBody = formEncode(postForm).data(using: .utf8)
        requests.append(formRequest)

        var jsonRequest = URLRequest(url: url)
        jsonRequest.httpMethod = "POST"
        jsonRequest.timeoutInterval = 30
        jsonRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        jsonRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        jsonRequest.httpBody = try JSONSerialization.data(withJSONObject: postJSON)
        requests.append(jsonRequest)

        return requests
    }

    private func parseOAuthTokenResponse(from data: Data) throws -> OAuthTokenResponse {
        if let decoded = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data) {
            return decoded
        }

        if let form = parseFormURLEncoded(data),
           let accessToken = form["access_token"]
        {
            return OAuthTokenResponse(
                accessToken: accessToken,
                refreshToken: form["refresh_token"],
                idToken: form["id_token"]
            )
        }

        throw decodeOAuthError(from: data, fallback: "Could not parse token response.")
    }

    private func decodeOAuthError(from data: Data, fallback: String) -> CodexDeviceAuthError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = json["error_description"] as? String, !description.isEmpty {
                return .server(description)
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return .server(message)
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return .server(error)
            }
        }

        if let form = parseFormURLEncoded(data),
           let description = form["error_description"] ?? form["error"]
        {
            return .server(description)
        }

        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            return .server(String(text.prefix(180)))
        }

        return .server(fallback)
    }

    private func parseFormURLEncoded(_ data: Data) -> [String: String]? {
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.contains("=")
        else {
            return nil
        }

        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let keyPart = parts.first else { continue }
            let key = decodeFormComponent(String(keyPart))
            let value = parts.count > 1 ? decodeFormComponent(String(parts[1])) : ""
            result[key] = value
        }

        return result.isEmpty ? nil : result
    }

    private func decodeFormComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }

    #if canImport(CryptoKit)
    private func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    #endif

    private func randomBase64URLString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

}

/// Extracts the ChatGPT account ID from the ``chatgpt_account_id`` claim in a JWT id_token.
func parseChatGPTAccountID(fromIDToken idToken: String?) -> String? {
    guard let idToken else { return nil }
    let parts = idToken.split(separator: ".")
    guard parts.count >= 2 else { return nil }

    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder > 0 {
        payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accountID = json["chatgpt_account_id"] as? String,
          !accountID.isEmpty
    else {
        return nil
    }

    return accountID
}

struct GeminiDeviceAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String?
}

struct GeminiManualAuthSession: Sendable {
    let authorizationURL: URL
    let codeVerifier: String
    let redirectURI: String
    let state: String
}

enum GeminiDeviceAuthError: LocalizedError {
    case invalidResponse
    case unsupported(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gemini login."
        case let .unsupported(reason):
            return reason
        case let .server(message):
            return message
        }
    }
}

/// Handles Gemini OAuth PKCE flow used by Settings > Sign in.
struct GeminiDeviceAuthService: Sendable {
    private let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private var config: Config? { getConfig() }
    private var gc: String? { config?.gc }
    private var gcs: String? { config?.gcs }
    private let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]
    private let manualRedirectURI = "http://localhost:8085/oauth2callback"

    /// Builds the browser URL for manual authorization with state + PKCE challenge.
    func makeManualAuthSession() throws -> GeminiManualAuthSession {
        #if canImport(CryptoKit)
        let state = randomHexString(length: 32)
        let codeVerifier = randomPKCEVerifier(length: 96)
        let codeChallenge = sha256Base64URL(codeVerifier)

        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: gc),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: manualRedirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let resolvedAuthorizationURL = components?.url else {
            throw GeminiDeviceAuthError.invalidResponse
        }

        return GeminiManualAuthSession(
            authorizationURL: resolvedAuthorizationURL,
            codeVerifier: codeVerifier,
            redirectURI: manualRedirectURI,
            state: state
        )
        #else
        throw GeminiDeviceAuthError.unsupported("CryptoKit is required for Gemini OAuth sign-in.")
        #endif
    }

    /// Exchanges the OAuth authorization code for access/refresh tokens.
    func exchangeManualAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> GeminiDeviceAuthTokens {
        let params = [
            "client_id": gc ?? "",
            "client_secret": gcs ?? "",
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ]

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(params).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireGeminiHTTP(response)

        guard (200...299).contains(http.statusCode) else {
            throw decodeOAuthError(from: data, fallback: "Token exchange failed (HTTP \(http.statusCode)).")
        }

        guard let decoded = try? JSONDecoder().decode(GeminiOAuthTokenResponse.self, from: data),
              !decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw decodeOAuthError(from: data, fallback: "Could not parse token response.")
        }

        return GeminiDeviceAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken
        )
    }

    private func decodeOAuthError(from data: Data, fallback: String) -> GeminiDeviceAuthError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = json["error_description"] as? String, !description.isEmpty {
                return .server(description)
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return .server(message)
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return .server(error)
            }
            if let nested = json["error"] as? [String: Any],
               let message = nested["message"] as? String,
               !message.isEmpty
            {
                return .server(message)
            }
        }

        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            return .server(String(text.prefix(180)))
        }

        return .server(fallback)
    }

    private func randomHexString(length: Int) -> String {
        let targetLength = max(length, 1)
        var bytes = [UInt8](repeating: 0, count: (targetLength + 1) / 2)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(targetLength))
    }

    private func randomPKCEVerifier(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let targetLength = min(max(length, 43), 128)
        var output = ""
        output.reserveCapacity(targetLength)
        for _ in 0..<targetLength {
            output.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return output
    }

    #if canImport(CryptoKit)
    private func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    #endif
}

private struct GeminiOAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private func requireGeminiHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        throw GeminiDeviceAuthError.invalidResponse
    }
    return http
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

private func requireHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        throw CodexDeviceAuthError.invalidResponse
    }
    return http
}

private func formEncode(_ params: [String: String]) -> String {
    params
        .sorted(by: { $0.key < $1.key })
        .map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }
        .joined(separator: "&")
}

private func percentEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=?/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}
