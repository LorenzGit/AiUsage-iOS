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

// MARK: - Shared helpers used by API clients and token refreshers

func requireHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        throw ProviderFetchError.invalidResponse
    }
    return http
}

func clamp(_ value: Double?) -> Double? {
    guard let value else { return nil }
    return min(max(value, 0), 100)
}

func clampFlexible(_ value: Double) -> Double {
    min(max(value, -200), 200)
}

func remaining(fromUsed used: Double?) -> Double? {
    guard let used else { return nil }
    return 100 - used
}

func dateFromUnixSeconds(_ value: Double?) -> Date? {
    guard let value else { return nil }
    return Date(timeIntervalSince1970: value)
}

func parseISO8601Date(_ value: String?) -> Date? {
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

func extractRefreshErrorCode(from data: Data) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
    if let nested = json["error"] as? [String: Any], let code = nested["code"] as? String {
        return code
    }
    if let error = json["error"] as? String {
        return error
    }
    return (json["code"] as? String) ?? ""
}

func extractRefreshErrorDescription(from data: Data) -> String {
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
