import Foundation

struct GeminiAPIClient: ProviderAPIClient {
    private struct GeminiBucketUsage {
        let usedPercent: Double
        let resetAt: Date?
    }

    /// Fetches Gemini quota buckets and maps them into session/weekly bars.
    func fetchUsage(using credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader = credentials.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let studioAuthorization = credentials.geminiAuthorizationHeader?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let studioAPIKey = credentials.geminiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasStudioHeaders = !cookieHeader.isEmpty && !studioAuthorization.isEmpty

        guard !accessToken.isEmpty || hasStudioHeaders else {
            throw ProviderFetchError.missingToken
        }

        let projectID = try await loadCodeAssistProjectID(
            accessToken: accessToken,
            hasStudioHeaders: hasStudioHeaders,
            studioAuthorization: studioAuthorization,
            cookieHeader: cookieHeader,
            studioAPIKey: studioAPIKey
        )
        let quotaRequestBody: Data
        if let projectID, !projectID.isEmpty {
            quotaRequestBody = try JSONSerialization.data(withJSONObject: ["project": projectID], options: [])
        } else {
            quotaRequestBody = Data("{}".utf8)
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw ProviderFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyGeminiAuthHeaders(
            to: &request,
            accessToken: accessToken,
            hasStudioHeaders: hasStudioHeaders,
            studioAuthorization: studioAuthorization,
            cookieHeader: cookieHeader,
            studioAPIKey: studioAPIKey
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = quotaRequestBody

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let buckets = decoded.buckets ?? []

        guard !buckets.isEmpty else {
            throw ProviderFetchError.notSupported(
                message: "Gemini returned no quota buckets. This endpoint is still experimental."
            )
        }

        let proUsage = maxUsedUsage(in: buckets, contains: "pro")
        let flashUsage = maxUsedUsage(in: buckets, contains: "flash")
        let fallbackUsage = maxUsedUsage(in: buckets, contains: nil)
        let resolvedPrimaryUsage = proUsage ?? fallbackUsage
        let resolvedSecondaryUsage = flashUsage ?? fallbackUsage

        return ProviderUsageSnapshot(
            provider: .gemini,
            usedPercent: clamp(resolvedPrimaryUsage?.usedPercent),
            secondaryUsedPercent: clamp(resolvedSecondaryUsage?.usedPercent),
            sessionRemainingPercent: remaining(fromUsed: resolvedPrimaryUsage?.usedPercent),
            weeklyRemainingPercent: remaining(fromUsed: resolvedSecondaryUsage?.usedPercent),
            sessionResetsAt: resolvedPrimaryUsage?.resetAt,
            weeklyResetsAt: resolvedSecondaryUsage?.resetAt,
            statusText: "Experimental API",
            updatedAt: Date()
        )
    }

    private func loadCodeAssistProjectID(
        accessToken: String,
        hasStudioHeaders: Bool,
        studioAuthorization: String,
        cookieHeader: String,
        studioAPIKey: String
    ) async throws -> String? {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
            throw ProviderFetchError.invalidResponse
        }

        let payload: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyGeminiAuthHeaders(
            to: &request,
            accessToken: accessToken,
            hasStudioHeaders: hasStudioHeaders,
            studioAuthorization: studioAuthorization,
            cookieHeader: cookieHeader,
            studioAPIKey: studioAPIKey
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try requireHTTP(response)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderFetchError.server(statusCode: http.statusCode)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let direct = json["cloudaicompanionProject"] as? String, !direct.isEmpty {
            return direct
        }

        if
            let response = json["response"] as? [String: Any],
            let project = response["cloudaicompanionProject"] as? [String: Any],
            let id = project["id"] as? String,
            !id.isEmpty
        {
            return id
        }

        return nil
    }

    private func applyGeminiAuthHeaders(
        to request: inout URLRequest,
        accessToken: String,
        hasStudioHeaders: Bool,
        studioAuthorization: String,
        cookieHeader: String,
        studioAPIKey: String
    ) {
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return
        }

        if hasStudioHeaders {
            request.setValue(studioAuthorization, forHTTPHeaderField: "Authorization")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            if !studioAPIKey.isEmpty {
                request.setValue(studioAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
            }
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("https://aistudio.google.com", forHTTPHeaderField: "Origin")
            request.setValue("https://aistudio.google.com/", forHTTPHeaderField: "Referer")
            request.setValue("AiUsage", forHTTPHeaderField: "User-Agent")
        }
    }

    private func maxUsedUsage(in buckets: [GeminiQuotaResponse.Bucket], contains needle: String?) -> GeminiBucketUsage? {
        let filtered: [GeminiQuotaResponse.Bucket]
        if let needle {
            filtered = buckets.filter { ($0.modelID ?? "").localizedCaseInsensitiveContains(needle) }
        } else {
            filtered = buckets
        }

        let values = filtered.compactMap { bucket -> GeminiBucketUsage? in
            guard let remaining = bucket.remainingFraction else { return nil }
            guard let used = usedPercent(fromRawRemaining: remaining) else { return nil }
            return GeminiBucketUsage(
                usedPercent: used,
                resetAt: parseISO8601Date(bucket.resetTime)
            )
        }

        // Some accounts expose multiple quota buckets for the same model family.
        // If at least one bucket still has capacity, prefer a non-exhausted bucket
        // so an exhausted side bucket doesn't pin the UI at 100%.
        let nonExhausted = values.filter { $0.usedPercent < 100 }
        if let best = nonExhausted.max(by: { $0.usedPercent < $1.usedPercent }) {
            return best
        }
        return values.max(by: { $0.usedPercent < $1.usedPercent })
    }

    private func usedPercent(fromRawRemaining raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0 else { return nil }

        var remainingPercent = raw

        // Observed variants:
        // - 0...1 fraction
        // - 0...100 percent
        // - scaled percent (e.g. 6300 => 63.00)
        if remainingPercent <= 1 {
            remainingPercent *= 100
        } else if remainingPercent > 100 {
            while remainingPercent > 100, remainingPercent <= 1_000_000 {
                remainingPercent /= 100
            }
        }

        guard remainingPercent >= 0, remainingPercent <= 100 else { return nil }
        return 100 - remainingPercent
    }

    private struct GeminiQuotaResponse: Decodable {
        let buckets: [Bucket]?

        struct Bucket: Decodable {
            let remainingFraction: Double?
            let modelID: String?
            let resetTime: String?

            enum CodingKeys: String, CodingKey {
                case remainingFraction
                case modelID = "modelId"
                case resetTime
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                if let numeric = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                    remainingFraction = numeric
                } else if let text = try container.decodeIfPresent(String.self, forKey: .remainingFraction),
                          let numeric = Double(text)
                {
                    remainingFraction = numeric
                } else {
                    remainingFraction = nil
                }

                modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
                resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
            }
        }
    }
}

