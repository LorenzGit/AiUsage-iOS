import Foundation

struct GrokDeviceAuthorization: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: URL
    let verificationUriComplete: URL?
    let expiresIn: Int
    let interval: Int?

    var verificationURL: URL {
        verificationUriComplete ?? verificationUri
    }
}

enum GrokSignInState {
    case starting
    case waiting(GrokDeviceAuthorization)
}

struct GrokDeviceAuthService {
    private let session: URLSession

    // The public Grok Build OAuth client supports device authorization without a secret.
    private let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private let deviceURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    private let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func begin() async throws -> GrokDeviceAuthorization {
        let data = try await requestDeviceCode()
        let authorization = try decode(GrokDeviceAuthorization.self, from: data)
        let allowedHosts = ["accounts.x.ai", "auth.x.ai"]
        let verificationURL = authorization.verificationURL
        guard verificationURL.scheme == "https", let host = verificationURL.host,
              allowedHosts.contains(host), (1...3600).contains(authorization.expiresIn) else {
            throw ProviderFetchError.invalidResponse
        }
        return authorization
    }

    @MainActor
    func finish(
        _ authorization: GrokDeviceAuthorization,
        canPoll: @MainActor () -> Bool
    ) async throws -> ProviderCredentials {
        let clock = ContinuousClock()
        var interval = Duration.seconds(max(5, min(60, authorization.interval ?? 5)))
        var delay = interval
        let expiresAt = clock.now + .seconds(authorization.expiresIn)
        var nextPoll = clock.now + delay

        while clock.now < expiresAt {
            try await clock.sleep(until: min(nextPoll, expiresAt))
            while !canPoll(), clock.now < expiresAt {
                try await clock.sleep(until: min(clock.now + .seconds(1), expiresAt))
            }
            guard clock.now < expiresAt else { break }
            try Task.checkCancellation()
            do {
                return try await exchange([
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": authorization.deviceCode
                ])
            } catch GrokAuthError.response("authorization_pending") {
                delay = interval
            } catch GrokAuthError.response("slow_down") {
                interval += .seconds(5)
                delay = interval
            } catch ProviderFetchError.server(statusCode: 429) {
                interval += .seconds(5)
                delay = interval
            } catch GrokAuthError.response("invalid_grant") {
                throw GrokAuthError.response("expired_token")
            } catch where isRetryable(error) {
                delay = max(interval, min(delay * 2, .seconds(60)))
            }
            nextPoll = clock.now + delay
        }
        throw GrokAuthError.response("expired_token")
    }

    private func requestDeviceCode() async throws -> Data {
        let fields = ["scope": "offline_access grok-cli:access"]
        for delay in [Duration.seconds(1), .seconds(2)] {
            do {
                return try await post(to: deviceURL, fields: fields)
            } catch where isRetryable(error) {
                try await Task.sleep(for: delay)
            }
        }
        do {
            return try await post(to: deviceURL, fields: fields)
        } catch where isRetryable(error) {
            throw GrokAuthError.connectionUnavailable
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.networkConnectionLost, .notConnectedToInternet, .timedOut,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        if case ProviderFetchError.server(let status) = error {
            return (500...599).contains(status)
        }
        if case GrokAuthError.response("temporarily_unavailable") = error {
            return true
        }
        return false
    }

    func refresh(using refreshToken: String) async throws -> ProviderCredentials {
        let credentials = try await exchange(["grant_type": "refresh_token", "refresh_token": refreshToken])
        return ProviderCredentials(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken ?? refreshToken
        )
    }

    private func exchange(_ fields: [String: String]) async throws -> ProviderCredentials {
        let data = try await post(to: tokenURL, fields: fields)
        let token = try decode(TokenResponse.self, from: data)
        guard !token.accessToken.isEmpty else { throw ProviderFetchError.invalidResponse }
        return ProviderCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken)
    }

    private func post(to url: URL, fields: [String: String]) async throws -> Data {
        let form = fields.merging(["client_id": clientID]) { current, _ in current }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFetchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if (500...599).contains(http.statusCode) {
                throw ProviderFetchError.server(statusCode: http.statusCode)
            }
            if let error = try? decode(ErrorResponse.self, from: data) {
                throw GrokAuthError.response(error.error)
            }
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }
}

private enum GrokAuthError: LocalizedError {
    case response(String)
    case connectionUnavailable

    var errorDescription: String? {
        switch self {
        case .response("access_denied"): return "Grok sign-in was declined."
        case .response("expired_token"): return "The Grok sign-in code expired. Start again for a new code."
        case .response("invalid_grant"): return "Your Grok session expired. Disconnect and sign in again."
        case .connectionUnavailable: return "Couldn’t reach xAI. Tap Sign in with Grok to try again."
        default: return "Grok could not complete sign-in. Try again."
        }
    }
}
